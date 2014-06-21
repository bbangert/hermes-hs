{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings  #-}

module Main
  (
    main
  ) where

import           Control.Applicative       ((<$>), (<*))
import           Control.Concurrent        (MVar, ThreadId, forkFinally,
                                            modifyMVar, modifyMVar_, myThreadId,
                                            newMVar, readMVar, throwTo)
import           Control.Exception         (Exception, finally)
import           Control.Monad             (forM_, forever)
import           Control.Monad.IO.Class    (liftIO)
import qualified Data.Attoparsec.Text      as A
import           Data.Map.Strict           (Map)
import qualified Data.Map.Strict           as M
import           Data.Maybe                (fromJust)
import           Data.Text                 (Text)
import qualified Data.Text                 as T
import           Data.Typeable             (Typeable)
import           Data.UUID                 (UUID, fromASCIIBytes, toASCIIBytes)
import qualified Network.WebSockets        as WS
import           System.Timeout            (timeout)

import           Hermes.Protocol.Websocket as W
import           Hermes.Protocol.Websocket (ClientPacket (..), DeviceID,
                                            PingInterval)

data CNException = DuplicateClient deriving (Show, Typeable)

instance Exception CNException

type ClientData = (PingInterval, ThreadId, WS.Connection)
type ServerState = Map UUID ClientData

newServerState :: ServerState
newServerState = M.empty

numClients :: ServerState -> Int
numClients = M.size

clientExists :: UUID -> ServerState -> Bool
clientExists = M.member

addClient :: UUID -> ClientData -> ServerState -> ServerState
addClient = M.insert

removeClient :: UUID -> ServerState -> ServerState
removeClient = M.delete

getClient :: UUID -> ServerState -> Maybe ClientData
getClient = M.lookup

main :: IO ()
main = do
  state <- newMVar newServerState
  WS.runServer "0.0.0.0" 9160 $ application state

parseMessage :: Text -> Either String W.ClientPacket
parseMessage = A.parseOnly (W.clientPacketParser <* A.endOfInput)

readData :: WS.Connection -> Int -> IO (Maybe (Either String ClientPacket))
readData conn after = timeout after $ parseMessage <$> WS.receiveData conn

application :: MVar ServerState -> WS.ServerApp
application state pending = do
  conn <- WS.acceptRequest pending
  msg <- parseMessage <$> WS.receiveData conn
  case msg of
    Right (Helo ver ping) ->
      if ver == 1 then
        WS.sendTextData conn ("HELO:v1" :: Text) >> checkAuth state conn (ping*1000000)
      else return ()
    _ -> return ()

checkAuth :: MVar ServerState -> WS.Connection -> PingInterval -> IO ()
checkAuth state conn ping = do
  myId <- myThreadId
  let cdata = (ping, myId, conn)
  msg <- parseMessage <$> WS.receiveData conn
  process msg cdata

  where
    process (Right NewAuth) cdata = do
      deviceID <- W.newDeviceID
      liftIO $ modifyMVar_ state $ \s -> do
        let s' = addClient deviceID cdata s
        return s'
      WS.sendTextData conn $ T.concat [
        "AUTH:NEW:", W.deviceIdToText deviceID, ":",
         W.signDeviceID deviceID "secret"]
      messagingApplication state deviceID cdata

    process (Right auth@(ExistingAuth deviceID _)) cdata
      | W.verifyAuth "secret" auth = do
        liftIO $ modifyMVar_ state $ \s -> do
          case getClient deviceID s of
            Just (_, cid, _) -> throwTo cid DuplicateClient
            _                -> return ()
          return $ addClient deviceID cdata s
        WS.sendTextData conn ("AUTH:SUCCESS" :: Text)
        messagingApplication state deviceID cdata
      | otherwise = WS.sendTextData conn ("AUTH:INVALID" :: Text)

    process _ _ = WS.sendTextData conn ("AUTH:INVALID" :: Text)

messagingApplication :: MVar ServerState -> UUID -> ClientData -> IO ()
messagingApplication state uuid cd@(ping, tid, conn) = do
  pmsg <- readData conn ping
  case pmsg of
    Just (Right (Outgoing s m b)) -> do
      print s
      print m
      print b
      msgApp
    Just (Right Ping) -> WS.sendTextData conn ("PONG" :: Text) >> msgApp
    Just (Right x) -> putStrLn ("Unexpected packet, dropping connection: "++show x)
    Just (Left err) -> putStrLn ("Unable to parse message: "++err)
    _ -> return ()
  where msgApp = messagingApplication state uuid cd
