{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}

module Main
  (
    main
  ) where

import           Control.Applicative            ((<$>), (<*), (<*>))
import           Control.Concurrent             (ThreadId, forkIO, myThreadId,
                                                 threadDelay, throwTo)
import           Control.Concurrent.STM.TBQueue (TBQueue, writeTBQueue)
import           Control.Concurrent.STM.TVar    (TVar, modifyTVar', newTVar,
                                                 readTVar)
import           Control.Exception              (Exception, finally, throw)
import           Control.Monad                  (forM_, forever, join)
import           Control.Monad.STM              (STM, atomically)
import qualified Data.Attoparsec.Text           as A
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as M
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Typeable                  (Typeable)
import qualified Network.WebSockets             as WS
import           System.Timeout                 (timeout)

import           Hermes.Protocol.Websocket      as W
import           Hermes.Protocol.Websocket      (ClientPacket (..), DeviceID,
                                                 PingInterval)

data CNException = DuplicateClient
                 | BadDataRead
                 deriving (Show, Typeable)

instance Exception CNException

type ClientData = (PingInterval, ThreadId, WS.Connection)
type ClientMap = Map DeviceID ClientData
type DeviceMessage = (DeviceID, ClientPacket)
type OutboundRouter = (ThreadId)

data InboundRelay = InboundRelay {
    tid    :: ThreadId
  , inChan :: TBQueue DeviceMessage
  }

data ServerState = ServerState {
    clientMap :: TVar ClientMap
  , relays    :: TVar [InboundRelay]
  , routers   :: TVar [OutboundRouter]
  }

nackDeviceMessage :: DeviceMessage -> ServerState -> IO ()
nackDeviceMessage (deviceId, (Outgoing s mid _)) state = do
  cdata <- atomically $ getClient deviceId state
  case cdata of
    Just (_, _, conn) -> WS.sendTextData conn $
      T.concat ["OUT:", s, ":", mid, ":NACK"]
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

newServerState :: STM ServerState
newServerState = ServerState <$> newTVar M.empty
                             <*> newTVar []
                             <*> newTVar []

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

-- Read a message and enforce a timeout. The response will be in a Maybe
-- indicating whether it timed out or not. If it didn't time out, then the
-- Either will be an indication if the packet it found parsed or not.
readData :: WS.Connection -> Int -> IO (Maybe (Either String ClientPacket))
readData conn after = timeout after $ parseMessage <$> WS.receiveData conn

main :: IO ()
main = do
  state <- atomically newServerState
  _ <- forkIO $ echoStats state
  putStrLn "All started, launching socket server..."
  WS.runServer "0.0.0.0" 8080 $ application state

parseMessage :: Text -> Either String W.ClientPacket
parseMessage = A.parseOnly (W.clientPacketParser <* A.endOfInput) . T.strip

-- We start our interaction with a new websocket here, to do the basic HELO
-- exchange
application :: ServerState -> WS.ServerApp
application state pending = do
  conn <- WS.acceptRequest pending
  putStrLn "Accepted connection."
  msg <- parseMessage <$> WS.receiveData conn
  putStrLn (show msg)
  case msg of
    Right (Helo ver ping) ->
      if ver == 1
        then WS.sendTextData conn ("HELO:v1" :: Text) >>
          checkAuth state conn (ping*1000000)
        else return ()
    _ -> return ()

-- Second state of a new websocket exchange, HELO worked, now its on to doing
-- the AUTH before we transition to message sending/receiving mode
checkAuth :: ServerState -> WS.Connection -> PingInterval -> IO ()
checkAuth state conn ping = do
  myId <- myThreadId
  msg <- readData conn (25*1000000)
  case msg of
    Just m -> process m (ping, myId, conn)
    Nothing -> putStrLn "Time-out waiting for auth." >> return ()

  where
    process (Right NewAuth) cdata = do
      deviceID <- W.newDeviceID
      atomically $ addClient deviceID cdata state
      safeCleanup deviceID $ do
        WS.sendTextData conn $ T.concat ["AUTH:NEW:", deviceID, ":",
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
          WS.sendTextData conn ("AUTH:SUCCESS" :: Text)
          messagingApplication state deviceID cdata
      | otherwise = print auth >> WS.sendTextData conn ("AUTH:INVALID" :: Text)

    process _ _ = WS.sendTextData conn ("AUTH:INVALID" :: Text)

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
  pmsg <- readData conn ping

  -- We have a nested case here of an Either inside a Maybe. The Maybe
  -- indicates whether or not we timed out attempting to read data. The Either
  -- indicates if the message parsed or not. We only accept Outgoing/Ping
  -- messages here, all else results in dropping the connection.
  case pmsg of
    Just (Right packet@(Outgoing s mid _)) -> do
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
    Just (Right Ping) -> WS.sendTextData conn ("PONG" :: Text)

    -- Drop the rest
    Just (Right x) -> putStrLn ("Unexpected packet, dropping connection: "
                        ++ show x) >> throw BadDataRead
    Just (Left err) -> putStrLn ("Unable to parse message: "++err) >>
                         throw BadDataRead
    _ -> throw BadDataRead
