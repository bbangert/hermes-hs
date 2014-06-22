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

import           Control.Applicative              ((*>), (<|>))
import           Crypto.Hash                      (SHA256,
                                                   digestToHexByteString)
import           Crypto.MAC                       (HMAC (hmacGetDigest), hmac)
import           Data.Attoparsec.ByteString       (Parser)
import qualified Data.Attoparsec.ByteString       as AB
import qualified Data.Attoparsec.ByteString.Char8 as AC
import           Data.Attoparsec.ByteString.Char8 (decimal)
import           Data.Byteable                    (constEqBytes)
import           Data.ByteString                  (ByteString)
import           Data.UUID                        (toASCIIBytes)
import           Data.UUID.V4                     (nextRandom)

type Version = Int
type PingInterval = Int
type DeviceID = ByteString
type OldDeviceID = ByteString
type MessageID = ByteString
type DeviceIDHMAC = ByteString
type ServiceName = ByteString
type Body = ByteString

data ClientPacket = Helo Version PingInterval
                  | NewAuth
                  | ExistingAuth DeviceID DeviceIDHMAC
                  | Ping
                  | DeviceChange ServiceName OldDeviceID DeviceIDHMAC DeviceID
                  | Outgoing ServiceName MessageID Body
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
  version <- "HELO:v" *> decimal
  ping <- ":" *> decimal
  return $ Helo version ping

authParser :: Parser ClientPacket
authParser = do
  _ <- "AUTH:"
  existingAuthParser <|> return NewAuth

existingAuthParser :: Parser ClientPacket
existingAuthParser = do
  uuid <- takeNonColon
  signed <- ":" *> AB.takeByteString
  return $ ExistingAuth uuid signed

pingParser :: Parser ClientPacket
pingParser = "PING" >> return Ping

takeNonColon :: Parser ByteString
takeNonColon = AC.takeWhile (/= ':')

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
  body <- ":" *> AB.takeByteString
  return $ Outgoing serviceName messageID body

computeHmac :: ByteString -> ByteString -> ByteString
computeHmac secret uuid = digestToHexByteString . hmacGetDigest $ (hmac secret uuid :: HMAC SHA256)

compareHmac :: ByteString -> ByteString -> ByteString -> Bool
compareHmac secret hash uuid = constEqBytes hash $ computeHmac secret uuid

verifyAuth :: ByteString -> ClientPacket -> Bool
verifyAuth secret (ExistingAuth deviceId key) = compareHmac secret key deviceId
verifyAuth secret (DeviceChange _ deviceId key _) = compareHmac secret key deviceId
verifyAuth _ _ = False

newDeviceID :: IO DeviceID
newDeviceID = nextRandom >>= return . toASCIIBytes

signDeviceID :: DeviceID -> ByteString -> ByteString
signDeviceID uuid secret =
  digestToHexByteString . hmacGetDigest $ (hmac secret uuid :: HMAC SHA256)
