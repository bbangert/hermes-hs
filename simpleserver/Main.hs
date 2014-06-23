{-# LANGUAGE TemplateHaskell    #-}

module Main
  (
    main
  ) where

import           Control.Monad                    (forever)
import           Data.ByteString                  (ByteString)
import           Data.FileEmbed                   (embedDir)
import qualified Network.Wai
import qualified Network.Wai.Application.Static   as Static
import qualified Network.Wai.Handler.Warp         as Warp
import qualified Network.Wai.Handler.WebSockets   as WaiWS
import qualified Network.WebSockets               as WS

main :: IO ()
main = do
  putStrLn "All started, launching socket server..."
  Warp.runSettings Warp.defaultSettings
    { Warp.settingsPort = 8080
    } $ WaiWS.websocketsOr WS.defaultConnectionOptions application staticApp

staticApp :: Network.Wai.Application
staticApp = Static.staticApp $ Static.embeddedSettings $(embedDir "static")

application :: WS.ServerApp
application pending = do
  conn <- WS.acceptRequest pending
  forever $ do
      m <- WS.receiveData conn
      WS.sendTextData conn (m :: ByteString)
