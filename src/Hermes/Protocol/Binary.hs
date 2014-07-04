{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hermes.Protocol.Binary
    (
      -- * Binary Packets
      RelayClientPacket (..)
    , RelayServerPacket (..)

      -- * Parsers
    , relayClientParser
    , relayServerParser

    ) where

import           Control.Applicative        ((<$>), (<*>))
import           Control.Monad              (liftM2)
import qualified Data.Attoparsec.Binary     as AB
import qualified Data.Attoparsec.ByteString as A
import           Data.Binary                (Binary (..))
import           Data.Binary.Put            (Put, putByteString)
import           Data.ByteString            (ByteString)
import qualified Data.ByteString            as B
import qualified Data.ByteString.Char8      as BC
import qualified Data.ByteString.Lazy       as BL
import           Data.UUID                  (UUID, fromASCIIBytes,
                                             fromByteString, toASCIIBytes)
import           Data.Word                  (Word16, Word32)

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
    put (ICHelo ver) = do
        put (1 :: Word16)
        put (fromIntegral ver :: Word16)
    put (ICDeliver mid did sn body) = do
        put (2 :: Word16)
        putMessageId mid
        putDeviceId did
        putBytestring sn
        putBytestring body
    put (ICDeviceChange mid did odid sn) = do
        put (3 :: Word16)
        putMessageId mid
        putDeviceId did
        put odid
        putBytestring sn
    get = fail "No binary parser"

instance Binary RelayServerPacket where
    put (ISHelo ver batch) = do
        put (1 :: Word16)
        put (fromIntegral ver :: Word16)
        put (fromIntegral batch :: Word16)
    put (ISDeliver mid res) = do
        put (2 :: Word16)
        putMessageId mid
        put (fromIntegral res :: Word16)
    put (ISDeviceChange mid res) = do
        put (3 :: Word16)
        putMessageId mid
        put (fromIntegral res :: Word16)
    get = fail "No binary parser"

relayClientParser :: A.Parser RelayClientPacket
relayClientParser = do
    header <- AB.anyWord16be
    case header of
        1 -> AB.anyWord16be >>= return . ICHelo . fromIntegral
        2 -> ICDeliver <$> parseUuid
                       <*> parseCsUuid
                       <*> parseByteString
                       <*> parseByteString
        3 -> ICDeviceChange <$> parseUuid
                            <*> parseCsUuid
                            <*> parseCsUuid
                            <*> parseByteString
        _ -> fail "Invalid header"

relayServerParser :: A.Parser RelayServerPacket
relayServerParser = do
    header <- AB.anyWord16be
    case header of
        1 -> liftM2 ISHelo parseNum parseNum
        2 -> liftM2 ISDeliver (A.take 16) parseNum
        3 -> liftM2 ISDeviceChange (A.take 16) parseNum
        _ -> fail "Unrecognized header"

parseNum :: Num a => A.Parser a
parseNum = fromIntegral <$> AB.anyWord16be

parseByteString :: A.Parser ByteString
parseByteString = AB.anyWord32be >>= A.take . fromIntegral

-- | Parse a UUID from its network bytes into hex bytes
parseUuid :: A.Parser ByteString
parseUuid = do
    uuid <- fromByteString . BL.pack . B.unpack  <$> A.take 16
    case uuid of
        Just x -> return $ toASCIIBytes x
        Nothing -> fail "Unable to read UUID bytes"

parseCsUuid :: A.Parser ByteString
parseCsUuid = do
    (cs :: Int) <- parseNum
    uuid <- parseUuid
    return $ B.concat [BC.pack (show cs), "-", uuid]

-- | Custom bytestring put as the default one writes the length as a signed
-- Int64 which is silly.
putBytestring :: ByteString -> Put
putBytestring b = do
    put (fromIntegral $ B.length b :: Word32)
    putByteString b

putMessageId :: ByteString -> Put
putMessageId mid =
    case fromASCIIBytes mid of
        Just uuid -> put uuid
        Nothing   -> fail "Unable to parse message ID to UUID"

putDeviceId :: ByteString -> Put
putDeviceId did =
    case deviceIdToUuid did of
        Just (cid, uuid) -> put cid >> put uuid
        Nothing          -> fail "Unable to parse deviceId to Cluster/UUID"

-- A device ID is cluster ID int with '-' joining to a hex uuid
-- This split it at the cluster ID, and returns the cluster ID as an int with
-- the UUID
deviceIdToUuid :: ByteString -> Maybe (Word16, UUID)
deviceIdToUuid devid = case uuid of
    Just uid -> Just (cid, uid)
    Nothing  -> Nothing
  where
    (front, rest) = BC.span (/= '-') devid
    uuid = fromASCIIBytes $ B.drop 1 rest
    cid = read (BC.unpack front) :: Word16
