{-# LANGUAGE OverloadedStrings #-}

module Hermes.Protocol.Websocket
  (
  -- * Parsing
  -- $parsing
    clientPacketParser

  ) where

import           Control.Applicative        ((<$>), (<*>), (<|>))
import           Crypto.Hash                (SHA256, digestToHexByteString)
import           Crypto.MAC                 (HMAC, hmac)
import           Data.Attoparsec.ByteString (Parser)
import qualified Data.Attoparsec.ByteString as AB
import           Data.Byteable              (constEqBytes)
import           Data.ByteString            (ByteString)
import           Data.Maybe                 (fromJust)
import           Data.UUID                  (UUID, fromString, toASCIIBytes)

type Version = Int
type PingInterval = Int
type DeviceID = UUID
type OldDeviceID = UUID
type MessageID = UUID
type SignedAuth = ByteString
type ServiceName = String

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
  AB.char ':'
  ping <- fromIntegral <$> AB.anyWord8
  return $ Helo version ping

newAuthParser :: Parser ClientPacket
newAuthParser = AB.string "AUTH:" >> return NewAuth

existingAuthParser :: Parser ClientPacket
existingAuthParser = do
  AB.string "AUTH:"
  uuid <- parseUUID
  AB.char ':'
  signed <- AB.takeByteString
  return $ ExistingAuth uuid signed

parseUUID :: Parser UUID
parseUUID = return $ fromJust . fromString <$> AB.take 36

pingParser :: Parser ClientPacket
pingParser = AB.string "PING" >> return Ping

deviceChangeParser :: Parser ClientPacket
deviceChangeParser = do
  AB.string "DEVICECHANGE:"
  serviceName <- AB.takeWhile (/= ':')
  AB.char ':'
  oldDevice <- parseUUID
  AB.char ':'
  oldKey <- AB.takeWhile (/= ':')
  AB.char ':'
  uuid <- parseUUID
  return $ DeviceChange serviceName oldDevice oldKey uuid

outgoingParser :: Parser ClientPacket
outgoingParser = do
  AB.string "OUT:"
  serviceName <- AB.takeWhile (/= ':')
  AB.char ':'
  messageID <- parseUUID
  AB.char ':'
  body <- AB.takeByteString
  return $ Outgoing serviceName messageID body

verifyAuth :: ByteString -> ClientPacket -> Bool
verifyAuth secret (ExistingAuth deviceId key) = constEqBytes computedHMAC key
  where computedHMAC = digestToHexByteString (hmac secret (toASCIIBytes deviceId) :: HMAC SHA256)
