{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}

module Main
  (
    main
  ) where

import           Conduit
import           Control.Exception (finally)
import           Control.Monad     (forever)
import           Yesod.Core
import           Yesod.WebSockets  (sinkWSBinary, sourceWS, webSockets)


data App = App

instance Yesod App

mkYesod "App" [parseRoutes|
/ HomeR GET
|]

getHomeR :: Handler Html
getHomeR = do
    webSockets $ forever $ sourceWS $$ sinkWSBinary
    return $ return ()

main :: IO ()
main = warp 8080 App
