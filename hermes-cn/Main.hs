module Main
  (
    main
  ) where

import           Control.Concurrent                    (forkIO, threadDelay)
import           Control.Monad                         (forever)
import           Control.Monad.STM                     (atomically)
import qualified Network.Wai.Handler.Warp.Timeout      as WT

import           Hermes.ConnectionNode.Types           (ServerState,
                                                        newServerState,
                                                        numClients)
import           Hermes.ConnectionNode.WebSocketServer (webSocketServer)

echoStats :: ServerState -> IO ()
echoStats state = forever $ do
    threadDelay $ 5 * 1000000
    count <- atomically $ numClients state
    putStrLn $ "Client count: " ++ show count

main :: IO ()
main = do
    manager <- WT.initialize 1000000
    state <- atomically $ newServerState manager
    _ <- forkIO $ echoStats state
    webSocketServer 8080 state
