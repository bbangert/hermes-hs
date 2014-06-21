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
  , signDeviceID
  , verifyAuth

  ) where

import           Control.Applicative  ((*>), (<|>))
import           Crypto.Hash          (SHA256, digestToHexByteString)
import           Crypto.MAC           (HMAC (hmacGetDigest), hmac)
import           Data.Attoparsec.Text (Parser)
import qualified Data.Attoparsec.Text as A
import           Data.Byteable        (constEqBytes)
import           Data.ByteString      (ByteString)
import           Data.Text            (Text)
import           Data.Text.Encoding   (decodeUtf8, encodeUtf8)
import           Data.UUID            (toASCIIBytes)
import           Data.UUID.V4         (nextRandom)

type Version = Int
type PingInterval = Int
type DeviceID = Text
type OldDeviceID = Text
type MessageID = Text
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
  _ <- "AUTH:"
  existingAuthParser <|> return NewAuth

existingAuthParser :: Parser ClientPacket
existingAuthParser = do
  uuid <- takeNonColon
  signed <- ":" *> A.takeText
  return $ ExistingAuth uuid signed

pingParser :: Parser ClientPacket
pingParser = "PING" >> return Ping

takeNonColon :: Parser Text
takeNonColon = A.takeWhile (/= ':')

deviceChangeParser :: Parser ClientPacket
deviceChangeParser = do
  serviceName <- "DEVICECHANGE:" *> takeNonColon
  oldDevice <- ":" *> takeNonColon
  oldKey <- ":" *> takeNonColon
  uuid <- ":" *> takeNonColon
  return $ DeviceChange serviceName oldDevice oldKey uuid

outgoingParser :: Parser ClientPacket
outgoingParser = do
  serviceName <- "OUT:" *> takeNonColon
  messageID <- ":" *> takeNonColon
  body <- ":" *> A.takeText
  return $ Outgoing serviceName messageID body

computeHmac :: ByteString -> ByteString -> ByteString
computeHmac secret uuid = digestToHexByteString . hmacGetDigest $ (hmac secret uuid :: HMAC SHA256)

compareHmac :: ByteString -> ByteString -> ByteString -> Bool
compareHmac secret hash uuid = constEqBytes hash $ computeHmac secret uuid

verifyAuth :: Text -> ClientPacket -> Bool
verifyAuth secret (ExistingAuth deviceId key) = compareHmac (encodeUtf8 secret) (encodeUtf8 key) (encodeUtf8 deviceId)
verifyAuth secret (DeviceChange _ deviceId key _) = compareHmac (encodeUtf8 secret) (encodeUtf8 key) (encodeUtf8 deviceId)
verifyAuth _ _ = False

newDeviceID :: IO DeviceID
newDeviceID = nextRandom >>= return . decodeUtf8 . toASCIIBytes

signDeviceID :: DeviceID -> Text -> Text
signDeviceID uuid secret =
  decodeUtf8 $ digestToHexByteString . hmacGetDigest
             $ (hmac (encodeUtf8 secret) (encodeUtf8 uuid) :: HMAC SHA256)
