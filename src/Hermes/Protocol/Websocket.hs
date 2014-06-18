{-# LANGUAGE OverloadedStrings #-}

module Hermes.Protocol.Websocket
  (
  -- * Parsing
  -- $parsing
    clientPacketParser

  , verifyAuth

  ) where

import           Control.Applicative        ((<$>), (<|>))
import           Crypto.Hash                (SHA256, digestToHexByteString)
import           Crypto.MAC                 (HMAC (hmacGetDigest), hmac)
import           Data.Attoparsec.ByteString (Parser, notInClass)
import qualified Data.Attoparsec.ByteString as AB
import           Data.Byteable              (constEqBytes)
import           Data.ByteString            (ByteString)
import           Data.UUID                  (UUID, fromASCIIBytes, toASCIIBytes)

type Version = Int
type PingInterval = Int
type DeviceID = UUID
type OldDeviceID = UUID
type MessageID = UUID
type SignedAuth = ByteString
type ServiceName = ByteString

data ClientPacket = Helo Version PingInterval
                  | NewAuth
                  | ExistingAuth DeviceID SignedAuth
                  | Ping
                  | DeviceChange ServiceName OldDeviceID SignedAuth DeviceID
                  | Outgoing ServiceName MessageID ByteString
                  | BadPacket

{- $parsing
   Parsing functions for turning a ByteString into a ClientPacket.

-}
clientPacketParser :: Parser ClientPacket
clientPacketParser =
      heloParser
  <|> newAuthParser
  <|> existingAuthParser
  <|> pingParser
  <|> deviceChangeParser
  <|> outgoingParser
  <|> return BadPacket

heloParser :: Parser ClientPacket
heloParser = do
  AB.string "HELO:v"
  version <- fromIntegral <$> AB.anyWord8
  AB.string ":"
  ping <- fromIntegral <$> AB.anyWord8
  return $ Helo version ping

newAuthParser :: Parser ClientPacket
newAuthParser = AB.string "AUTH:" >> return NewAuth

existingAuthParser :: Parser ClientPacket
existingAuthParser = do
  AB.string "AUTH:"
  uuid <- parseUUID
  AB.string ":"
  signed <- AB.takeByteString
  return $ ExistingAuth uuid signed

parseUUID :: Parser UUID
parseUUID = do
  uuid <- fromASCIIBytes <$> AB.take 36
  case uuid of
    Just x -> return x
    Nothing -> fail "Unable to parse UUID"

pingParser :: Parser ClientPacket
pingParser = AB.string "PING" >> return Ping

takeNonColon :: Parser ByteString
takeNonColon = AB.takeWhile (notInClass ":")

deviceChangeParser :: Parser ClientPacket
deviceChangeParser = do
  AB.string "DEVICECHANGE:"
  serviceName <- takeNonColon
  AB.string ":"
  oldDevice <- parseUUID
  AB.string ":"
  oldKey <- takeNonColon
  AB.string ":"
  uuid <- parseUUID
  return $ DeviceChange serviceName oldDevice oldKey uuid

outgoingParser :: Parser ClientPacket
outgoingParser = do
  AB.string "OUT:"
  serviceName <- takeNonColon
  AB.string ":"
  messageID <- parseUUID
  AB.string ":"
  body <- AB.takeByteString
  return $ Outgoing serviceName messageID body

computeHmac :: ByteString -> UUID -> ByteString
computeHmac secret uuid = digestToHexByteString . hmacGetDigest $ (hmac secret (toASCIIBytes uuid) :: HMAC SHA256)

compareHmac :: ByteString -> ByteString -> UUID -> Bool
compareHmac secret hash uuid = constEqBytes hash $ computeHmac secret uuid

verifyAuth :: ByteString -> ClientPacket -> Bool
verifyAuth secret (ExistingAuth deviceId key) = compareHmac secret key deviceId
verifyAuth secret (DeviceChange _ deviceId key _) = compareHmac secret key deviceId
verifyAuth _ _ = False
