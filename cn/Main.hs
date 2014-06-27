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
import           Control.Concurrent.STM.TBQueue   (TBQueue, writeTBQueue)
import           Control.Concurrent.STM.TVar      (TVar, modifyTVar', newTVar,
                                                   readTVar)
import           Control.Exception                (Exception, Handler (..),
                                                   catches, finally)
import           Control.Monad                    (forever, join, void)
import           Control.Monad.STM                (STM, atomically)
import qualified Data.Attoparsec.ByteString       as A
import           Data.ByteString                  (ByteString)
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Char8            as BC
import           Data.Char                        (isSpace)
import qualified Data.IORef                       as I
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Text.Encoding               (encodeUtf8)
import qualified Data.Time.Clock.POSIX            as P
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
  , inChan     :: TBQueue DeviceMessage
  }

data ServerState = ServerState {
    clientMap :: TVar ClientMap
  , relays    :: TVar [InboundRelay]
  , routers   :: TVar [OutboundRouter]
  , toManager :: WT.Manager
  }

nackDeviceMessage :: DeviceMessage -> ServerState -> IO ()
nackDeviceMessage (deviceId, (Outgoing s mid _)) state = do
  cdata <- atomically $ getClient deviceId state
  case cdata of
    Just (_, _, conn) -> WS.sendTextData conn $
      B.concat ["OUT:", s, ":", mid, ":NACK"]
    _ -> return ()
nackDeviceMessage _ _ = return ()

echoStats :: ServerState -> IO ()
echoStats state = forever $ do
  threadDelay $ 5 * 1000000
  count <- atomically $ numClients state
  putStrLn $ concat ["Client count: ", show count]

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
numClients state = readClientMap state >>= return . M.size

clientExists :: DeviceID -> ServerState -> STM Bool
clientExists d state = readClientMap state >>= return . (M.member d)

addClient :: DeviceID -> ClientData -> ServerState -> STM ()
addClient deviceId c state = modifyTVar' (clientMap state) $ M.insert deviceId c

removeClient :: DeviceID -> ServerState -> STM ()
removeClient deviceId state = modifyTVar' (clientMap state) $ M.delete deviceId

getClient :: DeviceID -> ServerState -> STM (Maybe ClientData)
getClient deviceId state = readClientMap state >>= return . (M.lookup deviceId)

-- Custom timer that uses our timeout thread to run an IO operation with a timer
-- of a certain interval in seconds
withTimeout :: ServerState -> Int -> IO a -> IO a
withTimeout state delta action = do
  myId <- myThreadId

  -- Our ioRef that indicates whether we should actually kill with the timeout
  reReg <- I.newIORef True

  startTime <- P.getPOSIXTime
  let end = startTime + (fromRational $ toRational delta)

  void $ WT.register manager $ timeOutAction startTime end reReg myId
  result <- action
  I.atomicWriteIORef reReg False
  return result
  where
    manager = toManager state
    -- The timeout function that re-registers itself until canceled by
    -- changing the reg IORef, or it eventually kills us
    timeOutAction cur end reg tId = do
      shouldRun <- I.readIORef reg
      case shouldRun of
        True -> do
          let cur' = cur + 0.5
          if cur' > end then
            throwTo tId WT.TimeoutThread
          else
            void $ WT.register manager $ timeOutAction cur' end reg tId
        False -> return ()

-- Read a message and enforce a timeout. The response will be in a Maybe
-- indicating whether it timed out or not. If it didn't time out, then the
-- Either will be an indication if the packet it found parsed or not.
readData :: WS.Connection -> ServerState -> Int -> IO (Either String ClientPacket)
readData conn state after = withTimeout state after $ parseMessage <$> WS.receiveData conn

main :: IO ()
main = do
  manager <- WT.initialize (500*1000)
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
inputCommands state req respond = do
  case NW.pathInfo req of
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

-- Swallow up bad reads
badReadHandler :: Handler ()
badReadHandler = Handler $ \(_ :: CNException) -> return ()

-- Don't care about parse errors either
parseHandler :: Handler ()
parseHandler = Handler $ \(_ :: ParseException) -> return ()

-- We start our interaction with a new websocket here, to do the basic HELO
-- exchange
application :: ServerState -> WS.ServerApp
application state pending = do
  conn <- WS.acceptRequest pending
  catches (checkHelo state conn) [badReadHandler, parseHandler]

checkHelo :: ServerState -> WS.Connection -> IO ()
checkHelo state conn = do
  msg <- parseMessage <$> WS.receiveData conn
  case msg of
    Right (Helo ver ping) ->
      if ver == 1
        then WS.sendTextData conn ("HELO:v1" :: ByteString) >>
          checkAuth state conn ping
        else return ()
    _ -> return ()

-- Second state of a new websocket exchange, HELO worked, now its on to doing
-- the AUTH before we transition to message sending/receiving mode
checkAuth :: ServerState -> WS.Connection -> PingInterval -> IO ()
checkAuth state conn ping = do
  myId <- myThreadId
  readData conn state 25 >>= flip process (ping, myId, conn)

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
          Just (_, cid, _) -> if myId == cid then removeClient deviceId state
            else return ()

-- Final transition to message send/receive mode. This runs until the client
-- does something bad which will cause the connection to drop.
messagingApplication :: ServerState -> DeviceID -> ClientData -> IO ()
messagingApplication state uuid (ping, _, conn) = forever $ do
  pmsg <- readData conn state ping

  -- We have a nested case here of an Either inside a Maybe. The Maybe
  -- indicates whether or not we timed out attempting to read data. The Either
  -- indicates if the message parsed or not. We only accept Outgoing/Ping
  -- messages here, all else results in dropping the connection.
  case pmsg of
    Right packet@(Outgoing _ _ _) -> do
      print packet

      -- Run an STM atomic operation that reads the list of available relays
      -- and attempts to put the message on a bounded queue (tbqueue) of the
      -- first relay available. If no relay is available, we NACK the message.
      -- If the relay's queue is full, this blocks until either the relay list
      -- is updated (relay is removed/added) or the queue has space.
      join . atomically $ do
        rs <- readTVar $ relays state
        if null rs then do
          return $ nackDeviceMessage (uuid, packet) state
        else do
          writeTBQueue (inChan $ head rs) (uuid, packet)
          -- Return a 'blank' IO op
          return $ return ()

    -- Handle the PING
    Right Ping -> WS.sendTextData conn ("PONG" :: ByteString)

    -- Drop the rest
    Right x -> putStrLn ("Unexpected packet, dropping connection: "
                        ++ show x) >> return ()
    Left err -> putStrLn ("Unable to parse message: "++err) >> return ()
