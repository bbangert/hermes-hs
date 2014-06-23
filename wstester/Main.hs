{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent       (ThreadId, forkIO, threadDelay)
import           Control.Concurrent.Async (Async, async, waitCatch)
import           Control.Monad            (forever, mapM, replicateM)
import           Data.ByteString          (ByteString)
import           Data.ByteString.Char8    as BC
import qualified Network.WebSockets       as WS
import           System.Environment       (getArgs)

main :: IO ()
main = do
  [ip, port, spawnCount] <- getArgs
  results <- replicateM (read spawnCount) (startWs ip $ read port)
  threadDelay (2000*1000000)
  return ()

startWs :: String -> Int -> IO ThreadId
startWs host port = forkIO $ WS.runClientWith host port "/" WS.defaultConnectionOptions
                              [("Origin", BC.concat [BC.pack host, ":", BC.pack $ show port])] wstester

wstester :: WS.ClientApp ()
wstester conn = do
  WS.sendTextData conn ("HELO:v1:20" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  WS.sendTextData conn ("AUTH:" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  forever $ do
    WS.sendTextData conn ("PING" :: ByteString)
    (_ :: ByteString) <- WS.receiveData conn
    threadDelay (15*1000000)
  print "Dropping connection"
  return ()
