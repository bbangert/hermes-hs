{-# LANGUAGE OverloadedStrings #-}

module Hermes.Protocol.Websocket
  (
  -- * Types
    ClientPacket (..)
  , DeviceID
  , PingInterval

  -- * Parsing
  -- $parsing
  , clientPacketParser

  -- * Packet Functions

  , newDeviceID
  , deviceIdToText
  , signDeviceID
  , verifyAuth

  ) where

import           Control.Applicative  ((*>), (<$>), (<|>))
import           Crypto.Hash          (SHA256, digestToHexByteString)
import           Crypto.MAC           (HMAC (hmacGetDigest), hmac)
import           Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as A
import           Data.Byteable        (constEqBytes)
import           Data.ByteString      (ByteString)
import           Data.Text            (Text, pack)
import           Data.Text.Encoding   (decodeUtf8, encodeUtf8)
import           Data.UUID            (UUID, fromASCIIBytes, toASCIIBytes, toString)
import           Data.UUID.V4         (nextRandom)

type Version = Int
type PingInterval = Int
type DeviceID = UUID
type OldDeviceID = UUID
type MessageID = UUID
type DeviceIDHMAC = Text
type ServiceName = Text

data ClientPacket = Helo Version PingInterval
                  | NewAuth
                  | ExistingAuth DeviceID DeviceIDHMAC
                  | Ping
                  | DeviceChange ServiceName OldDeviceID DeviceIDHMAC DeviceID
                  | Outgoing ServiceName MessageID Text
                  deriving (Show, Eq)

{- $parsing
   Parsing functions for turning a Websocket Text into a ClientPacket.

-}
clientPacketParser :: Parser ClientPacket
clientPacketParser =
      heloParser
  <|> authParser
  <|> pingParser
  <|> deviceChangeParser
  <|> outgoingParser

heloParser :: Parser ClientPacket
heloParser = do
  version <- "HELO:v" *> A.decimal
  ping <- ":" *> A.decimal
  return $ Helo version ping

authParser :: Parser ClientPacket
authParser = do
  "AUTH:"
  existingAuthParser <|> return NewAuth

existingAuthParser :: Parser ClientPacket
existingAuthParser = do
  uuid <- parseUUID
  signed <- ":" *> A.takeText
  return $ ExistingAuth uuid signed

parseUUID :: Parser UUID
parseUUID = do
  uuid <- (fromASCIIBytes . encodeUtf8) <$> A.take 36
  case uuid of
    Just x -> return x
    Nothing -> fail "Unable to parse UUID"

pingParser :: Parser ClientPacket
pingParser = "PING" >> return Ping

takeNonColon :: Parser Text
takeNonColon = A.takeWhile (/= ':')

deviceChangeParser :: Parser ClientPacket
deviceChangeParser = do
  serviceName <- "DEVICECHANGE:" *> takeNonColon
  oldDevice <- ":" *> parseUUID
  oldKey <- ":" *> takeNonColon
  uuid <- ":" *> parseUUID
  return $ DeviceChange serviceName oldDevice oldKey uuid

outgoingParser :: Parser ClientPacket
outgoingParser = do
  serviceName <- "OUT:" *> takeNonColon
  messageID <- ":" *> parseUUID
  body <- ":" *> A.takeText
  return $ Outgoing serviceName messageID body

computeHmac :: ByteString -> UUID -> ByteString
computeHmac secret uuid = digestToHexByteString . hmacGetDigest $ (hmac secret (toASCIIBytes uuid) :: HMAC SHA256)

compareHmac :: ByteString -> ByteString -> UUID -> Bool
compareHmac secret hash uuid = constEqBytes hash $ computeHmac secret uuid

verifyAuth :: Text -> ClientPacket -> Bool
verifyAuth secret (ExistingAuth deviceId key) = compareHmac (encodeUtf8 secret) (encodeUtf8 key) deviceId
verifyAuth secret (DeviceChange _ deviceId key _) = compareHmac (encodeUtf8 secret) (encodeUtf8 key) deviceId
verifyAuth _ _ = False

newDeviceID :: IO DeviceID
newDeviceID = nextRandom

deviceIdToText :: DeviceID -> Text
deviceIdToText = pack . toString

signDeviceID :: DeviceID -> Text -> Text
signDeviceID uuid secret =
  decodeUtf8 $ digestToHexByteString . hmacGetDigest
             $ (hmac (encodeUtf8 secret) (toASCIIBytes uuid) :: HMAC SHA256)
