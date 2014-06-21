{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}

module Main
  (
    main
  ) where

import           Control.Applicative            ((<$>), (<*), (<*>))
import           Control.Concurrent             (ThreadId, myThreadId, throwTo)
import           Control.Concurrent.STM.TBQueue (TBQueue, writeTBQueue)
import           Control.Concurrent.STM.TVar    (TVar, modifyTVar', newTVar,
                                                 readTVar)
import           Control.Exception              (Exception, finally, throw)
import           Control.Monad                  (forM_, forever)
import           Control.Monad.STM              (STM, atomically)
import qualified Data.Attoparsec.Text           as A
import           Data.Map.Strict                (Map)
import qualified Data.Map.Strict                as M
import           Data.Maybe                     (fromJust)
import           Data.Text                      (Text)
import qualified Data.Text                      as T
import           Data.Typeable                  (Typeable)
import           Data.UUID                      (UUID, fromASCIIBytes,
                                                 toASCIIBytes)
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
type OutboundRouter = (ThreadId)
type ClientMap = Map DeviceID ClientData
type DeviceMessage = (DeviceID, ClientPacket)

data InboundRelay = InboundRelay {
    tid    :: ThreadId
  , inChan :: TBQueue DeviceMessage
  }

data ServerState = ServerState {
    clientMap :: TVar ClientMap
  , relays    :: TVar [InboundRelay]
  , routers   :: TVar [OutboundRouter]
  }

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

main :: IO ()
main = do
  state <- atomically newServerState
  putStrLn "All started, launching socket server..."
  WS.runServer "0.0.0.0" 8080 $ application state

parseMessage :: Text -> Either String W.ClientPacket
parseMessage = A.parseOnly (W.clientPacketParser <* A.endOfInput)

readData :: WS.Connection -> Int -> IO (Maybe (Either String ClientPacket))
readData conn after = timeout after $ parseMessage <$> WS.receiveData conn

application :: ServerState -> WS.ServerApp
application state pending = do
  conn <- WS.acceptRequest pending
  putStrLn "Accepted connection."
  msg <- parseMessage <$> WS.receiveData conn
  putStrLn (show msg)
  case msg of
    Right (Helo ver ping) ->
      if ver == 1 then
        WS.sendTextData conn ("HELO:v1" :: Text) >> checkAuth state conn (ping*1000000)
      else return ()
    _ -> return ()

checkAuth :: ServerState -> WS.Connection -> PingInterval -> IO ()
checkAuth state conn ping = do
  myId <- myThreadId
  let cdata = (ping, myId, conn)
  msg <- parseMessage <$> WS.receiveData conn
  process msg cdata

  where
    process (Right NewAuth) cdata = do
      deviceID <- W.newDeviceID
      atomically $ addClient deviceID cdata state
      safeCleanup deviceID $ do
        WS.sendTextData conn $ T.concat [
          "AUTH:NEW:", deviceID, ":",
           W.signDeviceID deviceID "secret"]
        messagingApplication state deviceID cdata

    process (Right auth@(ExistingAuth deviceID _)) cdata
      | W.verifyAuth "secret" auth = do
        action <- atomically $ do
          client <- getClient deviceID state
          addClient deviceID cdata state
          return $ case client of
            Just (_, cid, _) -> throwTo cid DuplicateClient
            _ -> return ()
        safeCleanup deviceID $ do
          action
          WS.sendTextData conn ("AUTH:SUCCESS" :: Text)
          messagingApplication state deviceID cdata
      | otherwise = WS.sendTextData conn ("AUTH:INVALID" :: Text)

    process _ _ = WS.sendTextData conn ("AUTH:INVALID" :: Text)
    safeCleanup deviceId = flip finally $ atomically $ removeClient deviceId state

messagingApplication :: ServerState -> DeviceID -> ClientData -> IO ()
messagingApplication state uuid (ping, _, conn) = forever $ do
  pmsg <- readData conn ping
  case pmsg of
    Just (Right packet@(Outgoing s mid _)) -> do
      print packet
      action <- atomically $ do
        rs <- readTVar $ relays state
        if length rs == 0 then do
          return $ WS.sendTextData conn $ T.concat [
            "OUT:", s, ":", mid, ":NACK"]
        else do
          let relay = head rs
          writeTBQueue (inChan relay) (uuid, packet)
          return $ return ()
      action
    Just (Right Ping) -> WS.sendTextData conn ("PONG" :: Text)
    Just (Right x) -> putStrLn ("Unexpected packet, dropping connection: "++show x)
      >> throw BadDataRead
    Just (Left err) -> putStrLn ("Unable to parse message: "++err) >> throw BadDataRead
    _ -> throw BadDataRead
