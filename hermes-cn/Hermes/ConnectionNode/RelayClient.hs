{-# LANGUAGE BangPatterns #-}

module Hermes.ConnectionNode.RelayClient
    (
      connectRelayClient
    ) where

import           Control.Applicative                   ((<$>))
import           Control.Concurrent                    (myThreadId)
import qualified Control.Concurrent.STM.TBChan         as T
import           Control.Concurrent.STM.TVar           (TVar, newTVarIO,
                                                        readTVar)
import           Control.Exception                     (bracket, bracket_,
                                                        catch)
import           Control.Monad                         (unless)
import           Control.Monad.IO.Class                (liftIO)
import           Control.Monad.STM                     (atomically)
import           Data.Attoparsec.ByteString            (parseOnly)
import           Data.Binary                           (encode)
import           Data.ByteString                       (ByteString)
import qualified Data.ByteString                       as B
import qualified Data.ByteString.Lazy                  as BL
import           Data.Conduit                          (Sink, awaitForever,
                                                        ($$), ($=))
import           Data.Conduit.Attoparsec               (ParseError,
                                                        PositionRange,
                                                        conduitParserEither)
import qualified Data.Conduit.Network                  as CN
import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as M
import           Network.Socket                        (AddrInfo (..),
                                                        Family (..), Socket,
                                                        SocketOption (..),
                                                        SocketType (..),
                                                        addrFamily, connect,
                                                        getAddrInfo, sClose,
                                                        setSocketOption, socket,
                                                        withSocketsDo)
import           Network.Socket.ByteString             (recv, sendAll)
import qualified Network.Wai.Handler.Warp.Timeout      as WT
import           System.IO                             (hClose, hSetBinaryMode)
import           System.Posix.Signals                  (Handler (Ignore),
                                                        installHandler, sigPIPE)

import           Hermes.ConnectionNode.Types           (DeviceMessage,
                                                        InboundRelay (..),
                                                        ServerState (..),
                                                        addRelay, removeRelay)
import           Hermes.ConnectionNode.WebSocketServer (nackDeviceMessage)
import           Hermes.Protocol.Binary                (RelayClientPacket (..),
                                                        RelayServerPacket (..),
                                                        relayServerParser)

type PendingMap = Map ByteString DeviceMessage

-- | Connect the relay client to a relay server.
connectRelayClient :: String        -- ^ Relay hostname
                   -> Int           -- ^ Relay port number
                   -> ServerState   -- ^ Server state
                   -> IO ()
connectRelayClient hostname port state = withSocketsDo $ do
    -- Writing to a dead socket gets a sigPIPE on linux, we'd prefer not to
    -- segfault when this happens
    _ <- installHandler sigPIPE Ignore Nothing

    bracket (socket AF_INET Stream 0)
            (\sock -> sClose sock)
            (\sock -> do
                setSocketOption sock ReuseAddr 1
                setSocketOption sock NoDelay 1
                (ainfo:_) <- getAddrInfo Nothing (Just hostname) (Just $ show port)
                let addr = addrAddress ainfo
                connect sock (addrAddress ainfo)
                go sock
                )

  where
    go sock = do
        sendAll sock (encode $ ICHelo 1)
        reply <- parseOnly relayServerParser <$> recv sock 6
        case reply of
            -- The right version match
            Right (ISHelo 1 mb) -> do
                myId    <- myThreadId
                ic      <- T.newTBChanIO 50
                pending <- newTVarIO M.empty
                let inbr = InboundRelay myId ic
                bracket_ (atomically $ addRelay inbr state)
                         (cleanUpRelay inbr pending state)
                         (processMessages inbr pending mb state sock)

            -- Anything else, not going to work
            _ -> return ()

-- | Ignore killthread
ignoreThreadKill :: WT.TimeoutThread -> IO ()
ignoreThreadKill _ = return ()

-- | Drains a TBChan of all the messages
drainChannel :: T.TBChan a -> IO [a]
drainChannel = go
  where
    go chan = do
        result <- atomically $ T.tryReadTBChan chan
        case result of
            Just !x  -> (x:) <$> go chan
            Nothing -> return []

-- | Remove the relay from the server state. If there are more relays remaining
-- then attempt to move the messages to the other relays, otherwise NACK all
-- the incoming messages. Pending messages are all dropped with no NACK's.
cleanUpRelay :: InboundRelay -> TVar PendingMap -> ServerState -> IO ()
cleanUpRelay inbr@(InboundRelay _ messageChan) _ state = do
    atomically $ removeRelay inbr state
    bracket (WT.initialize 500000) WT.stopManager $ \tm -> do

        -- Drain all the messages, newest is first
        messages <- drainChannel messageChan

        -- Attempt to redeliver them all, they either all get requeued, or fail
        -- in which case we nack them all
        redelivered <- atomically $ do
            rs <- readTVar $ relays state
            if null rs then
                return False
            else do
                let nextChan = inChan (head rs)
                mapM_ (T.unGetTBChan nextChan) messages
                return True

        unless redelivered $ do
            h <- WT.registerKillThread tm
            flip mapM_ messages $ \message -> do
                WT.pause h
                flip catch ignoreThreadKill $ do
                    WT.resume h
                    nackDeviceMessage message state
            WT.cancel h

processMessages :: InboundRelay     -- ^ This inbound relay
                -> TVar PendingMap  -- ^ Pending messages to ack
                -> Int              -- ^ Max pending messages
                -> ServerState      -- ^ Global serverstate
                -> Socket           -- ^ Input socket
                -> IO ()
processMessages (InboundRelay tid messageChan) pending maxBatch state sock = do

    return ()

receiveLoop sock handler = do
    result <- CN.sourceSocket sock $= conduitParserEither relayServerParser $$ sink
    return result
 where
    sink :: Sink (Either ParseError (PositionRange, RelayServerPacket)) IO ()
    sink = awaitForever $ \tc -> do
        case tc of
            Left err -> liftIO $ fail $ show err
            Right (_, tc) -> liftIO $ handler tc
