{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hermes.ConnectionNode.WebSocketServer
    (
      -- * Websocket Server
      webSocketServer

    , nackDeviceMessage

    ) where

import           Control.Applicative              ((<$>), (<*))
import           Control.Concurrent               (myThreadId, throwTo)
import qualified Control.Concurrent.STM.TBChan    as T
import           Control.Concurrent.STM.TVar      (readTVar)
import           Control.Exception                (Handler (..), bracket,
                                                   bracket_, catches, finally)
import           Control.Monad                    (forever, join, unless, void,
                                                   when)
import           Control.Monad.Loops              (anyM)
import           Control.Monad.STM                (atomically)
import qualified Data.Attoparsec.ByteString       as A
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as BC
import           Data.Char                        (isSpace)
import           Data.Text.Encoding               (encodeUtf8)
import           Network.HTTP.Types.Status        (status200, status404)
import qualified Network.Wai                      as NW
import qualified Network.Wai.Handler.Warp         as Warp
import qualified Network.Wai.Handler.Warp.Timeout as WT
import qualified Network.Wai.Handler.WebSockets   as WaiWS
import qualified Network.WebSockets               as WS
import           System.IO.Streams.Attoparsec     (ParseException)

import           Hermes.ConnectionNode.Types
import           Hermes.Protocol.Websocket        (ClientPacket (..), DeviceID,
                                                   PingInterval)
import qualified Hermes.Protocol.Websocket        as W

-- | Run the websocket server for clients to connect to and handle HTTP
-- commands for manipulating client state.
webSocketServer :: Int -> ServerState -> IO ()
webSocketServer port state = do
    putStrLn $ "Launching websocket server on port: " ++ (show port)
    Warp.runSettings (Warp.setPort 8080 Warp.defaultSettings)
        $ WaiWS.websocketsOr WS.defaultConnectionOptions (application state)
        $ inputCommands state

-- | Generate the appropriate NACK for the given DeviceMessage and send it to
-- the client.
nackDeviceMessage :: DeviceMessage -> ServerState -> IO ()
nackDeviceMessage (deviceId, Outgoing s mid _) state = do
    cdata <- atomically $ getClient deviceId state
    case cdata of
        Just (_, _, conn) -> WS.sendTextData conn $
            B.concat ["OUT:", s, ":", mid, ":NACK"]
        _ -> return ()
nackDeviceMessage (deviceId, DeviceChange s _ _ _) state = do
    cdata <- atomically $ getClient deviceId state
    case cdata of
        Just (_, _, conn) -> WS.sendTextData conn $
            B.concat ["DEVICECHANGE", s, ":NACK"]
        _ -> return ()
nackDeviceMessage _ _ = return ()

-- | HTTP Command handler for testing
-- This accepts the following URL scheme:
--     /drop/DEVICEID
--     /send/DEVICEID/SERVICENAME
--             { some HTTP POST/PUT body }
inputCommands :: ServerState -> NW.Application
inputCommands state req respond = case NW.pathInfo req of
    ("drop":devid:[]) -> do
        let did = encodeUtf8 devid
        msg <- join . atomically $ do
            c <- getClient did state
            return $ case c of
                Just (_, tid, _) -> throwTo tid BadDataRead >> return "Kill sent"
                Nothing          -> return "No such device id"
        respond $ NW.responseLBS status200 [] msg
    ("send":devid:service:[]) -> do
        let did = encodeUtf8 devid
        msg <- join . atomically $ do
            c <- getClient did state
            return $ case c of
                Nothing           -> return "No such device id"
                Just (_, _, conn) -> do
                    body <- NW.requestBody req
                    WS.sendTextData conn $ B.concat
                        ["INC:", encodeUtf8 service, ":", body]
                    return "Sent data"
        respond $ NW.responseLBS status200 [] msg
    _ -> respond $ NW.responseLBS status404 [] ""

-- | Run the message parser over the given ByteString and return Either a
-- String indicating the failure message or a parsed ClientPacket.
parseMessage :: ByteString -> Either String W.ClientPacket
parseMessage =
    A.parseOnly (W.clientPacketParser <* A.endOfInput) . dropTrailingNewline
  where dropTrailingNewline b = if isSpace (BC.last b) then B.init b else b

{- | Exception Handler's

-}

-- | Swallow up our own errors
badReadHandler :: Handler ()
badReadHandler = Handler $ \(_ :: CNException) -> return ()

-- | Don't care about parse errors
parseHandler :: Handler ()
parseHandler = Handler $ \(_ :: ParseException) -> return ()

-- | Ignore timeout errors
timeoutHandler :: Handler ()
timeoutHandler = Handler $ \(_ :: WT.TimeoutThread) -> return ()

-- | Our set of basic errors we prefer to suppress, as they occur naturally
-- with connections coming and going
defaultErrors :: [Handler ()]
defaultErrors = [badReadHandler, parseHandler, timeoutHandler]

{- | Timeout manager helper functions

-}

-- | Run an IO computation with a timeout manager ticking for the supplied
-- amount of seconds, and stop the mananger afterwards.
withTimeout :: Int -> (WT.Manager -> IO a) -> IO a
withTimeout tick = bracket (WT.initialize $ tick * 1000000) WT.stopManager

-- Run an IO computation with a Timeout Handle active, then pause it after
withBTimeout :: WT.Handle -> IO a -> IO a
withBTimeout h = bracket_ (WT.resume h) (WT.pause h)

{- | Misc Cleanup functions

-}

-- | Safe cleanup of the DeviceID from the ServerState when the IO computation
-- passed in has completed. This will run even if the IO computation throws an
-- error to ensure that the ServerState is always accurate.
-- Note that we have to check to ensure we don't delete this deviceId if the
-- threadId doesn't match our own threadId (ie, maybe we've been killed, and
-- the client has already reconnected).
safeCleanup :: ServerState -> DeviceID -> IO a -> IO a
safeCleanup state deviceId = flip finally $ do
    myId <- myThreadId
    atomically $ do
        client <- getClient deviceId state
        case client of
            Nothing -> return ()
            Just (_, cid, _) -> when (myId == cid) $ removeClient deviceId state

{- | Websocket Application States

   Each function represents a further state transition, starting from the
   websocket accept, then checking the HELO, handling AUTH, and finally
   running in the normal messaging state.

-}

-- | Initial websocket acceptance. Sets up the initial timeout Handle for use
-- in the HELO/AUTH stages, and wraps all further communication in our basic
-- defaultErrors exception catching.
application :: ServerState -> WS.ServerApp
application state pending = do
    h <- WT.registerKillThread (toManager state)
    WT.pause h
    flip catches defaultErrors $ do
        conn <- withBTimeout h $ WS.acceptRequest pending
        checkHelo state h conn

-- | First state of a new connection, ensure our HELO statements match and
-- remember the desired max ping interval
checkHelo :: ServerState -> WT.Handle -> WS.Connection -> IO ()
checkHelo state h conn = do
    msg <- withBTimeout h $ parseMessage <$> WS.receiveData conn
    case msg of
        Right (Helo ver ping) -> when (ver == 1) $ do
            WS.sendTextData conn ("HELO:v1" :: ByteString)
            checkAuth state h ping conn
        _ -> return ()

-- | Second state of a new websocket exchange, HELO worked, now its on to doing
-- the AUTH before we transition to message sending/receiving mode
checkAuth :: ServerState -> WT.Handle -> PingInterval -> WS.Connection -> IO ()
checkAuth state h ping conn = do
    myId <- myThreadId
    msg <- withBTimeout h $ parseMessage <$> WS.receiveData conn

    -- Messaging uses the ping interval, cancel our initial timeout Handle
    WT.cancel h

    process msg (ping, myId, conn)

  where
    process (Right NewAuth) cdata = do
        deviceID <- W.newDeviceID (clusterId state)
        atomically $ addClient deviceID cdata state
        safeCleanup state deviceID $ do
            WS.sendTextData conn $ B.concat ["AUTH:NEW:", deviceID, ":",
                                         W.signDeviceID deviceID "secret"]
            messagingApplication state deviceID cdata

    process (Right auth@(ExistingAuth deviceID _)) cdata
        | W.verifyAuth "secret" auth = do
            {- Atomically determine if this DeviceID already exists in the
               server states client map. If it does, return an IO op that will
               kill the dupe client. Either way we update the client map so
               that the DeviceID now points to our current client data.

               We return an IO op to run, since the STM can't run IO ops, ergo
               the 'join'.
            -}
            join . atomically $ do
                client <- getClient deviceID state
                addClient deviceID cdata state
                return $ case client of
                    Just (_, cid, _) -> throwTo cid DuplicateClient
                    _ -> return ()
            safeCleanup state deviceID $ do
                WS.sendTextData conn ("AUTH:SUCCESS" :: ByteString)
                messagingApplication state deviceID cdata
        | otherwise = WS.sendTextData conn ("AUTH:INVALID" :: ByteString)

    process _ _ = WS.sendTextData conn ("AUTH:INVALID" :: ByteString)

-- | Final transition to message send/receive mode. This runs until the client
-- does something bad which will cause the connection to drop.
messagingApplication :: ServerState -> DeviceID -> ClientData -> IO ()
messagingApplication state uuid (ping, _, conn) = withTimeout ping $ \tm -> do
    h <- WT.registerKillThread tm
    WT.pause h
    forever $ do
        pmsg <- withBTimeout h $ parseMessage <$> WS.receiveData conn

        -- We only accept Outgoing/Ping/DeviceChange messages here, all else
        -- results in dropping the connection.
        case pmsg of
            Right packet@(Outgoing{}) -> attemptMessageDelivery (uuid, packet)

            -- Handle DeviceChange
            Right packet@(DeviceChange sn _ _ _)
                | W.verifyAuth "secret" packet ->
                    attemptMessageDelivery (uuid, packet)
                | otherwise ->
                    WS.sendTextData conn $ B.concat ["DEVICECHANGE", sn, ":INVALID"]

            -- Handle the PING
            Right Ping -> WS.sendTextData conn ("PONG" :: ByteString)

            -- Drop the rest
            Right x -> void $ putStrLn $
                "Unexpected packet, dropping connection: " ++ show x
            Left err -> void $ putStrLn $ "Unable to parse message: " ++ err
  where
    {- | Run an STM atomic operation that:
         1. Reads the list of relays into rs
         2. Attempts to write the message into the first relay's input
         3. NACK's the message if no channel has space, otherwise accepts

         If the list of relays changes, this operation will restart.
    -}
    attemptMessageDelivery msg = join . atomically $ do
        rs <- readTVar $ relays state
        if null rs then
            return $ nackDeviceMessage msg state
        else do
            let chanList = map inChan rs
                tryWrite = flip T.tryWriteTBChan msg

            -- Attempt to write the message to one of the channels in the list
            success <- anyM tryWrite chanList

            -- Unless we delivered it, nack the message
            return $ unless success $ nackDeviceMessage msg state
