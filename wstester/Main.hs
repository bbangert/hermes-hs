{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Control.Concurrent           (ThreadId, forkIO, threadDelay)
import           Control.Exception            (Handler (..), IOException,
                                               catches, finally)
import           Control.Monad                (void, forever, replicateM_)
import           Data.ByteString              (ByteString)
import qualified Data.ByteString.Char8        as BC
import           Data.IORef
import qualified Network.WebSockets           as WS
import           System.Environment           (getArgs)
import           System.IO.Streams.Attoparsec (ParseException)

-- Don't care about parse errors either
parseHandler :: Handler ()
parseHandler = Handler $ \(_ :: ParseException) -> return ()

closedHandler :: Handler ()
closedHandler = Handler $ \(_ :: WS.ConnectionException) -> return ()

resetHandler :: Handler ()
resetHandler = Handler $ \(_ :: IOException) -> return ()

watcher :: IORef Int -> IO ()
watcher i = forever $ do
  count <- readIORef i
  putStrLn $ "Clients Connected: " ++ (show count)
  threadDelay (5*1000000)

main :: IO ()
main = do
  [ip, port, spawnCount, pingFreq] <- getArgs
  count <- newIORef (0 :: Int)
  forkIO $ watcher count
  replicateM_ (read spawnCount) (startWs ip (read port) (read pingFreq) count)
  threadDelay (2000*1000000)
  return ()

startWs :: String -> Int -> Float -> IORef Int -> IO ThreadId
startWs host port pingFreq count =
  forkIO $ catches spawn [parseHandler, closedHandler, resetHandler]
  where spawn = WS.runClientWith host port "/" WS.defaultConnectionOptions
                  [("Origin", BC.concat [BC.pack host, ":", BC.pack $ show port])]
                  $ wstester pingFreq count

wstester :: Float -> IORef Int -> WS.ClientApp ()
wstester ping count conn = do
  WS.sendTextData conn ("HELO:v1:10" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  WS.sendTextData conn ("AUTH:" :: ByteString)
  (_ :: ByteString) <- WS.receiveData conn
  atomicModifyIORef' count (\x -> (x+1, ()))
  finally pingConnection $ void $ atomicModifyIORef' count (\x -> (x-1, ()))
  where
    pingConnection = forever $ do
      WS.sendTextData conn ("PING" :: ByteString)
      (_ :: ByteString) <- WS.receiveData conn
      threadDelay (round $ ping*1000000)
