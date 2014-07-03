{-# OPTIONS_GHC -funbox-strict-fields #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Hermes.ConnectionNode.Types
    (
      -- * ServerState
      ServerState (..)
    , newServerState
    , readClientMap
    , numClients
    , clientExists
    , addClient
    , getClient
    , removeClient

      -- * InboundRelay
    , InboundRelay (..)

      -- * Client Types
    , ClientData
    , DeviceMessage

      -- * Exceptions
    , CNException (..)

    ) where

import           Control.Applicative              ((<$>))
import           Control.Concurrent               (ThreadId)

import qualified Control.Concurrent.STM.TBChan    as T
import           Control.Concurrent.STM.TVar      (TVar, modifyTVar', newTVar,
                                                   readTVar)
import           Control.Exception                (Exception)
import           Control.Monad.STM                (STM)
import           Data.Map.Strict                  (Map)
import qualified Data.Map.Strict                  as M
import           Data.Typeable                    (Typeable)
import qualified Network.Wai.Handler.Warp.Timeout as WT
import qualified Network.WebSockets               as WS

import           Hermes.Protocol.Websocket        (ClientPacket (..), DeviceID,
                                                   PingInterval)

type ClientData = (PingInterval, ThreadId, WS.Connection)
type ClientMap = Map DeviceID ClientData
type DeviceMessage = (DeviceID, ClientPacket)
type OutboundRouter = (ThreadId)

data InboundRelay = InboundRelay
    { inThreadId :: !ThreadId
    , inChan     :: !(T.TBChan DeviceMessage)
    }

data ServerState = ServerState
    { clientMap :: !(TVar ClientMap)
    , relays    :: !(TVar [InboundRelay])
    , routers   :: !(TVar [OutboundRouter])
    , toManager :: !WT.Manager
    }

data CNException = DuplicateClient
                 | BadDataRead
                 deriving (Show, Typeable)

instance Exception CNException


-- | Create a new ServerState. An existing timeout manager must be passed in.
newServerState :: WT.Manager        -- ^ Client read timeout manager
               -> STM ServerState   -- ^ Initialized ServerState
newServerState manager = do
    cm <- newTVar M.empty
    inbrs <- newTVar []
    ors <- newTVar []
    return $ ServerState cm inbrs ors manager

-- | Read the client map out of the ServerState.
readClientMap :: ServerState -> STM ClientMap
readClientMap = readTVar . clientMap

-- | Count all the clients currently being tracked.
numClients :: ServerState -> STM Int
numClients state = M.size <$> readClientMap state

-- | Indicate whether a client with this DeviceID is connected.
clientExists :: DeviceID -> ServerState -> STM Bool
clientExists d state = M.member d <$> readClientMap state

-- | Add ClientData for a DeviceID to the ServerState. This will overwrite
-- any existing ClientData if the DeviceID is already being tracked.
addClient :: DeviceID -> ClientData -> ServerState -> STM ()
addClient deviceId c state = modifyTVar' (clientMap state) $ M.insert deviceId c

-- | Remove a given DeviceID from the ServerState.
removeClient :: DeviceID -> ServerState -> STM ()
removeClient deviceId state = modifyTVar' (clientMap state) $ M.delete deviceId

-- | Get the ClientData for a given DeviceID from the ServerState.
getClient :: DeviceID -> ServerState -> STM (Maybe ClientData)
getClient deviceId state = M.lookup deviceId <$> readClientMap state
