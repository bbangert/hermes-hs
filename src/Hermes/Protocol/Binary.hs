{-# LANGUAGE OverloadedStrings #-}

module Hermes.Protocol.Binary
  (

  ) where

import           Control.Applicative   ((<$>), (<*>))
import           Control.Monad         (liftM2)
import           Data.Binary           (Binary (..))
import           Data.Binary.Get       (Get, getByteString, getWord16be,
                                        getWord32be)
import           Data.Binary.Put       (Put, putByteString)
import           Data.ByteString       (ByteString)
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as BC
import           Data.UUID             (UUID, fromASCIIBytes, toASCIIBytes)
import           Data.Word             (Word16, Word32)

type Body = ByteString
type DeviceId = ByteString
type Version = Int
type OldDeviceId = ByteString
type MessageId = ByteString
type ServiceName = ByteString
type MaxMessages = Int
type Response = Int

data RelayClientPacket = ICHelo Version
                       | ICDeliver MessageId DeviceId ServiceName Body
                       | ICDeviceChange MessageId DeviceId OldDeviceId ServiceName
     deriving (Show)

data RelayServerPacket = ISHelo Version MaxMessages
                       | ISDeliver MessageId Response
                       | ISDeviceChange MessageId Response
     deriving (Show)

instance Binary RelayClientPacket where
  put (ICHelo ver) = do put (1 :: Word16)
                        put (fromIntegral ver :: Word16)
  put (ICDeliver mid did sn body) = do put (2 :: Word16)
                                       putMessageId mid
                                       putDeviceId did
                                       putBytestring sn
                                       putBytestring body
  put (ICDeviceChange mid did odid sn) = do put (3 :: Word16)
                                            putMessageId mid
                                            putDeviceId did
                                            put odid
                                            putBytestring sn

  get = do header <- getWord16be
           case header of
              1 -> ICHelo <$> getWordInt
              2 -> ICDeliver <$> (toASCIIBytes <$> get)
                             <*> getDeviceId
                             <*> getByteString'
                             <*> getByteString'
              3 -> ICDeviceChange <$> (toASCIIBytes <$> get)
                                  <*> getDeviceId
                                  <*> getDeviceId
                                  <*> getByteString'

instance Binary RelayServerPacket where
  put (ISHelo ver batch) = do put (1 :: Word16)
                              put (fromIntegral ver :: Word16)
                              put (fromIntegral batch :: Word16)
  put (ISDeliver mid res) = do put (2 :: Word16)
                               putMessageId mid
                               put (fromIntegral res :: Word16)
  put (ISDeviceChange mid res) = do put (3 :: Word16)
                                    putMessageId mid
                                    put (fromIntegral res :: Word16)

  get = do header <- getWord16be
           case header of
            1 -> liftM2 ISHelo getWordInt getWordInt
            2 -> liftM2 ISDeliver getUuidAsBytes getWordInt
            3 -> liftM2 ISDeviceChange getUuidAsBytes getWordInt

-- I define my own bytestring put as the default one writes the length as a signed
-- Int64 which is silly.
putBytestring :: ByteString -> Put
putBytestring b = do put (fromIntegral $ B.length b :: Word32)
                     putByteString b

-- And for the other direction
getByteString' :: Get ByteString
getByteString' = (fromIntegral <$> getWord32be) >>= getByteString

putMessageId :: ByteString -> Put
putMessageId mid =
  case fromASCIIBytes mid of Nothing -> fail "Unable to parse message ID to UUID"
                             Just uuid -> put uuid

putDeviceId :: ByteString -> Put
putDeviceId did =
  case deviceIdToUuid did of
    Nothing -> fail "Unable to parse deviceId to Cluster/UUID"
    Just (cid, uuid) -> put cid >> put uuid

getWordInt :: Get Int
getWordInt = fromIntegral <$> getWord16be

getUuidAsBytes :: Get ByteString
getUuidAsBytes = toASCIIBytes <$> get

getDeviceId :: Get ByteString
getDeviceId = do
  cid <- BC.pack . show <$> getWord16be
  uuid <- get
  return $ B.concat [cid, "-", toASCIIBytes uuid]

-- A device ID is cluster ID int with '-' joining to a hex uuid
-- This split it at the cluster ID, and returns the cluster ID as an int with
-- the UUID
deviceIdToUuid :: ByteString -> Maybe (Word16, UUID)
deviceIdToUuid devid =
  case uuid of Nothing  -> Nothing
               Just uid -> Just (cid, uid)
  where (front, rest) = BC.span (/= '-') devid
        uuid = fromASCIIBytes $ B.drop 1 rest
        cid = read (BC.unpack front) :: Word16
