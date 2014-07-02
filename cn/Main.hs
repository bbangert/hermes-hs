{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main
  (
    main
  ) where

import           Control.Applicative              ((<$>), (<*))
import           Control.Concurrent               (ThreadId, forkIO, myThreadId,
                                                   threadDelay, throwTo)
import qualified Control.Concurrent.STM.TBChan    as T
import           Control.Concurrent.STM.TVar      (TVar, modifyTVar', newTVar,
                                                   readTVar)
import           Control.Exception                (Exception, Handler (..),
                                                   bracket_, catches, finally)
import           Control.Monad                    (forever, join, unless, void,
                                                   when)
import           Control.Monad.Loops              (anyM)
import           Control.Monad.STM                (STM, atomically)
import qualified Data.Attoparsec.ByteString       as A
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as BC
import           Data.Char                        (isSpace)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Text.Encoding               (encodeUtf8)
import           Data.Typeable                    (Typeable)
import           Network.HTTP.Types.Status        (status200, status404)
import qualified Network.Wai                      as NW
import qualified Network.Wai.Handler.Warp         as Warp
import qualified Network.Wai.Handler.Warp.Timeout as WT
import qualified Network.Wai.Handler.WebSockets   as WaiWS
import qualified Network.WebSockets               as WS
import           System.IO.Streams.Attoparsec     (ParseException)

import           Hermes.Protocol.Websocket        (ClientPacket (..), DeviceID,
                                                   PingInterval)
import qualified Hermes.Protocol.Websocket        as W

data CNException = DuplicateClient
                 | BadDataRead
                 deriving (Show, Typeable)

instance Exception CNException

type ClientData = (PingInterval, ThreadId, WS.Connection)
type ClientMap = Map DeviceID ClientData
type DeviceMessage = (DeviceID, ClientPacket)
type OutboundRouter = (ThreadId)

data InboundRelay = InboundRelay {
    inThreadId :: ThreadId
  , inChan     :: T.TBChan DeviceMessage
  }

data ServerState = ServerState {
    clientMap :: TVar ClientMap
  , relays    :: TVar [InboundRelay]
  , routers   :: TVar [OutboundRouter]
  , toManager :: WT.Manager
  }

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

echoStats :: ServerState -> IO ()
echoStats state = forever $ do
  threadDelay $ 5 * 1000000
  count <- atomically $ numClients state
  putStrLn $ "Client count: " ++ show count

{- STM Convenience functions
   These functions assist in accessing portions of the ServerState.

-}

-- Create the new server state, we make a timeout manager that runs every half
-- second for timeout operations
newServerState :: WT.Manager -> STM ServerState
newServerState manager = do
  cm <- newTVar M.empty
  inbrs <- newTVar []
  ors <- newTVar []
  return $ ServerState cm inbrs ors manager

readClientMap :: ServerState -> STM ClientMap
readClientMap = readTVar . clientMap

numClients :: ServerState -> STM Int
numClients state = M.size <$> readClientMap state

clientExists :: DeviceID -> ServerState -> STM Bool
clientExists d state = M.member d <$> readClientMap state

addClient :: DeviceID -> ClientData -> ServerState -> STM ()
addClient deviceId c state = modifyTVar' (clientMap state) $ M.insert deviceId c

removeClient :: DeviceID -> ServerState -> STM ()
removeClient deviceId state = modifyTVar' (clientMap state) $ M.delete deviceId

getClient :: DeviceID -> ServerState -> STM (Maybe ClientData)
getClient deviceId state = M.lookup deviceId <$> readClientMap state

main :: IO ()
main = do
  manager <- WT.initialize 1000000
  state <- atomically $ newServerState manager
  _ <- forkIO $ echoStats state
  putStrLn "All started, launching socket server..."
  Warp.runSettings Warp.defaultSettings
    { Warp.settingsPort = 8080
    } $ WaiWS.websocketsOr WS.defaultConnectionOptions (application state) $ inputCommands state

-- Our HTTP command handler for testing
-- This accepts:
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
        case c of Nothing           -> return $ return "No such device id"
                  Just (_, _, conn) -> return $ do
                    body <- NW.requestBody req
                    WS.sendTextData conn $ B.concat
                      ["INC:", encodeUtf8 service, ":", body]
                    return "Sent data"
      respond $ NW.responseLBS status200 [] msg
    _ -> respond $ NW.responseLBS status404 [] ""

parseMessage :: ByteString -> Either String W.ClientPacket
parseMessage = A.parseOnly (W.clientPacketParser <* A.endOfInput) . dropTrailingNewline
  where dropTrailingNewline b = if isSpace (BC.last b) then B.init b else b

-- Swallow up our own errors
badReadHandler :: Handler ()
badReadHandler = Handler $ \(_ :: CNException) -> return ()

-- Don't care about parse errors
parseHandler :: Handler ()
parseHandler = Handler $ \(_ :: ParseException) -> return ()

-- Ignore timeout errors
timeoutHandler :: Handler ()
timeoutHandler = Handler $ \(_ :: WT.TimeoutThread) -> return ()

-- Our set of basic errors we prefer to suppress, as they occur naturally with
-- connections coming and going
defaultErrors :: [Handler ()]
defaultErrors = [badReadHandler, parseHandler, timeoutHandler]

-- Run an IO computation with a Timeout Handle active, then pause it after
withBTimeout :: WT.Handle -> IO a -> IO a
withBTimeout h = bracket_ (WT.resume h) (WT.pause h)

-- We start our interaction with a new websocket here, to do the basic HELO
-- exchange
application :: ServerState -> WS.ServerApp
application state pending = do
  h <- WT.registerKillThread (toManager state)
  WT.pause h
  flip catches defaultErrors $ do
    conn <- withBTimeout h $ WS.acceptRequest pending
    checkHelo state h conn

-- First state of a new connection, ensure our HELO statements match and
-- remember the desired max ping interval
checkHelo :: ServerState -> WT.Handle -> WS.Connection -> IO ()
checkHelo state h conn = do
  msg <- withBTimeout h $ parseMessage <$> WS.receiveData conn
  case msg of
    Right (Helo ver ping) -> when (ver == 1) $
      WS.sendTextData conn ("HELO:v1" :: ByteString) >> checkAuth state h conn ping
    _ -> return ()

-- Second state of a new websocket exchange, HELO worked, now its on to doing
-- the AUTH before we transition to message sending/receiving mode
checkAuth :: ServerState -> WT.Handle -> WS.Connection -> PingInterval -> IO ()
checkAuth state h conn ping = do
  myId <- myThreadId
  msg <- withBTimeout h $ parseMessage <$> WS.receiveData conn

  -- Don't need this handle anymore
  WT.cancel h

  process msg (ping, myId, conn)

  where
    process (Right NewAuth) cdata = do
      deviceID <- W.newDeviceID
      atomically $ addClient deviceID cdata state
      safeCleanup deviceID $ do
        WS.sendTextData conn $ B.concat ["AUTH:NEW:", deviceID, ":",
                                         W.signDeviceID deviceID "secret"]
        messagingApplication state deviceID cdata

    process (Right auth@(ExistingAuth deviceID _)) cdata
      | W.verifyAuth "secret" auth = do

        -- Atomically determine if this DeviceID already exists in the server
        -- states client map. If it does, return an IO op that will kill the
        -- dupe client. Either way we update the client map so that the
        -- DeviceID now points to our current client data.

        -- We return an IO op to run, since the STM can't run IO ops, ergo the
        -- 'join'.
        join . atomically $ do
          client <- getClient deviceID state
          addClient deviceID cdata state
          return $ case client of
            Just (_, cid, _) -> throwTo cid DuplicateClient
            _ -> return ()
        safeCleanup deviceID $ do
          WS.sendTextData conn ("AUTH:SUCCESS" :: ByteString)
          messagingApplication state deviceID cdata
      | otherwise = print auth >> WS.sendTextData conn ("AUTH:INVALID" :: ByteString)

    process _ _ = WS.sendTextData conn ("AUTH:INVALID" :: ByteString)

    -- Define a safe clean-up that ensures if the rest of this clients
    -- interaction goes bad, we will ALWAYS remove this client from the client
    -- mapping. Note that we have to check to ensure we don't delete this
    -- deviceId if the threadId doesn't match our own threadId (ie, maybe we've
    -- been killed).
    safeCleanup deviceId = flip finally $ do
      myId <- myThreadId
      atomically $ do
        client <- getClient deviceId state
        case client of
          Nothing -> return ()
          Just (_, cid, _) -> when (myId == cid) $ removeClient deviceId state

-- Final transition to message send/receive mode. This runs until the client
-- does something bad which will cause the connection to drop.
messagingApplication :: ServerState -> DeviceID -> ClientData -> IO ()
messagingApplication state uuid (ping, _, conn) =
  WT.withManager (ping * 1000000) $ \tm -> do
    h <- WT.registerKillThread tm
    WT.pause h
    flip finally (WT.cancel h >> WT.stopManager tm) $ forever $ do
      pmsg <- withBTimeout h $ parseMessage <$> WS.receiveData conn

      -- We only accept Outgoing/Ping/DeviceChange messages here, all else results
      -- in dropping the connection.
      case pmsg of
        Right packet@(Outgoing{}) -> attemptMessageDelivery (uuid, packet)

        -- Handle DeviceChange
        Right packet@(DeviceChange sn _ _ _) ->
          if W.verifyAuth "secret" packet
            then attemptMessageDelivery (uuid, packet)
            else WS.sendTextData conn $ B.concat ["DEVICECHANGE", sn, ":INVALID"]

        -- Handle the PING
        Right Ping -> WS.sendTextData conn ("PONG" :: ByteString)

        -- Drop the rest
        Right x -> void $ putStrLn ("Unexpected packet, dropping connection: " ++ show x)
        Left err -> void $ putStrLn ("Unable to parse message: "++err)
  where
    attemptMessageDelivery msg =
      {- Run an STM atomic operation that:
           1. Reads the list of relays into rs
           2. Attempts to write the message into the first relay's input
           3. NACK's the message if no channel has space, otherwise accepts

         If the list of relays changes, this operation will restart.
      -}
      join . atomically $ do
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
