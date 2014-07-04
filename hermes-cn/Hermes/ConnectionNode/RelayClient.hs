module Hermes.ConnectionNode.RelayClient
    (
      connectRelayClient
    ) where

import           Control.Applicative           ((<$>))
import           Control.Concurrent            (myThreadId)
import qualified Control.Concurrent.STM.TBChan as T
import           Control.Concurrent.STM.TVar   (TVar, newTVarIO)
import           Control.Exception             (bracket_)
import           Control.Monad.STM             (atomically)
import           Data.Attoparsec.ByteString    (parseOnly)
import           Data.Binary                   (encode)
import           Data.ByteString               (ByteString)
import qualified Data.ByteString               as B
import qualified Data.ByteString.Lazy          as BL
import           Data.Map.Strict               (Map)
import qualified Data.Map.Strict               as M
import           Network                       (HostName, PortID (PortNumber),
                                                connectTo)
import           System.IO                     (hSetBinaryMode)
import           System.Posix.Signals          (Handler (Ignore),
                                                installHandler, sigPIPE)

import           Hermes.ConnectionNode.Types   (DeviceMessage,
                                                InboundRelay (..), ServerState,
                                                addRelay, removeRelay)
import           Hermes.Protocol.Binary        (RelayClientPacket (..),
                                                RelayServerPacket (..),
                                                relayServerParser)

type PendingMap = Map ByteString DeviceMessage

-- | Connect the relay client to a relay server.
connectRelayClient :: HostName      -- ^ Relay hostname
                   -> Int           -- ^ Relay port number
                   -> ServerState   -- ^ Server state
                   -> IO ()
connectRelayClient hostname port state = do
    -- Writing to a dead socket gets a sigPIPE on linux, we'd prefer not to
    -- segfault when this happens
    _ <- installHandler sigPIPE Ignore Nothing

    h <- connectTo hostname $ PortNumber (fromIntegral port)
    hSetBinaryMode h True
    BL.hPut h (encode $ ICHelo 1)
    reply <- parseOnly relayServerParser <$> B.hGet h 6
    case reply of
        -- The right version match
        Right (ISHelo 1 mb) -> do
            myId <- myThreadId
            ic <- T.newTBChanIO 50
            pending <- newTVarIO M.empty
            let inbr = InboundRelay myId ic
            bracket_ (atomically $ addRelay inbr state)
                     (cleanUpRelay inbr pending state)
                     (processMessages inbr pending mb state)

        -- Anything else, not going to work
        _ -> return ()

-- | Remove the relay from the server state. If there are more relays remaining
-- then attempt to move the messages to the other relays, otherwise NACK all
-- the incoming messages. Pending messages are all dropped with no NACK's.
cleanUpRelay :: InboundRelay -> TVar PendingMap -> ServerState -> IO ()
cleanUpRelay inbr@(InboundRelay _ messageChan) pending state = do
    atomically $ removeRelay inbr state

processMessages :: InboundRelay     -- ^ This inbound relay
                -> TVar PendingMap  -- ^ Pending messages to ack
                -> Int              -- ^ Max pending messages
                -> ServerState      -- ^ Global serverstate
                -> IO ()
processMessages (InboundRelay tid messageChan) pending maxBatch state = do
    return ()
