{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent       (ThreadId, threadDelay, forkIO)
import           Control.Concurrent.Async (Async, async, waitCatch)
import           Control.Monad            (forever, mapM, replicateM)
import           Data.ByteString          (ByteString)
import qualified Network.WebSockets       as WS

main :: IO ()
main = do
  results <- replicateM 5000 startWs
  threadDelay (20*1000000)
  print results
  return ()

startWs :: IO ThreadId
startWs = forkIO $ WS.runClientWith "localhost" 8080 "/" WS.defaultConnectionOptions
                                    [("Origin", "localhost:8080")] wstester

wstester :: WS.ClientApp ()
wstester conn = do
  WS.sendTextData conn ("HELO:v1:10" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  WS.sendTextData conn ("AUTH:" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  replicateM 5 $ do
    WS.sendTextData conn ("PING" :: ByteString)
    (_ :: ByteString) <- WS.receiveData conn
    threadDelay (2*1000000)
  print "Dropping connection"
  return ()
