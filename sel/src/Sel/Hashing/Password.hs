{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE TypeApplications #-}

-- |
--
-- Module: Sel.Hashing.Password
-- Description: Password hashing with the Argon2id algorithm
-- Copyright: (C) Hécate Moonlight 2022
-- License: BSD-3-Clause
-- Maintainer: The Haskell Cryptography Group
-- Portability: GHC only
module Sel.Hashing.Password
  ( -- * Introduction
    -- $introduction
    PasswordHash

    -- ** Password Hashing and Verifying
  , hashByteString
  , hashText
  , verifyByteString
  , verifyText
  , hashByteStringWithParams

    -- *** Conversion
  , passwordHashToBinary
  , passwordHashToHexText
  , passwordHashToHexByteString

    -- ** Salt
  , Salt
  , genSalt

    -- ** Conversion
  , saltToBinary
  , saltToHexText
  , saltToHexByteString
  , binaryToSalt
  , hexTextToSalt
  , hexByteStringToSalt

    -- * Argon2 Parameters
  , Argon2Params (Argon2Params)
  , defaultArgon2Params
  )
where

import Control.Monad (void)
import Data.ByteString (StrictByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Internal as BS
import qualified Data.ByteString.Unsafe as BS
import Data.Text (Text)
import Data.Text.Display
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy.Builder as Builder
import Foreign hiding (void)
import Foreign.C
import System.IO.Unsafe (unsafeDupablePerformIO)

import Sel.Internal

import LibSodium.Bindings.PasswordHashing
import LibSodium.Bindings.Random

-- $introduction
--
-- This API provides functions for password hashing, backed by the [Argon2id](https://en.wikipedia.org/wiki/Argon2) algorithm.
--
-- If you need to deviate from the defaults enforced by this module,
-- please use the underlying bindings at "LibSodium.Bindings.PasswordHashing".

-- | A hashed password from the Argon2id algorithm.
--
-- @since 0.0.1.0
newtype PasswordHash = PasswordHash (ForeignPtr CChar)

instance Eq PasswordHash where
  (PasswordHash ph1) == (PasswordHash ph2) =
    unsafeDupablePerformIO $
      foreignPtrEq ph1 ph2 cryptoPWHashStrBytes

instance Ord PasswordHash where
  (PasswordHash ph1) `compare` (PasswordHash ph2) =
    unsafeDupablePerformIO $
      foreignPtrOrd ph1 ph2 cryptoPWHashStrBytes

instance Show PasswordHash where
  show (PasswordHash fptr) = foreignPtrShow fptr cryptoPWHashStrBytes

-- | @since 0.0.1.0
instance Display PasswordHash where
  displayBuilder = Builder.fromText . passwordHashToHexText

-- | Hash the password with the Argon2id algorithm and
-- a set of pre-defined parameters.
--
-- @since 0.0.1.0
hashByteString :: StrictByteString -> IO PasswordHash
hashByteString bytestring =
  BS.unsafeUseAsCStringLen bytestring $ \(cString, cStringLen) -> do
    hashForeignPtr <- Foreign.mallocForeignPtrBytes (fromIntegral cryptoPWHashStrBytes)
    Foreign.withForeignPtr hashForeignPtr $ \passwordHashPtr ->
      void $
        cryptoPWHashStr
          passwordHashPtr
          cString
          (fromIntegral @Int @CULLong cStringLen)
          cryptoPWHashOpsLimitModerate
          cryptoPWHashMemLimitModerate
    pure $ PasswordHash hashForeignPtr

-- | Hash a UTF8-encoded password with the Argon2id algorithm and
-- a set of pre-defined parameters.
--
-- @since 0.0.1.0
hashText :: Text -> IO PasswordHash
hashText text = hashByteString (Text.encodeUtf8 text)

-- | Hash the password with the Argon2id algorithm.
--
-- The hash is __not__ encoded in human-readable format.
--
-- @since 0.0.1.0
hashByteStringWithParams :: Argon2Params -> Salt -> StrictByteString -> IO PasswordHash
hashByteStringWithParams Argon2Params{opsLimit, memLimit} (Salt argonSalt) bytestring =
  BS.unsafeUseAsCStringLen bytestring $ \(cString, cStringLen) -> do
    BS.unsafeUseAsCStringLen argonSalt $ \(saltString, _) -> do
      hashForeignPtr <- mallocForeignPtrBytes (fromIntegral cryptoPWHashStrBytes)
      withForeignPtr hashForeignPtr $ \passwordHashPtr ->
        void $
          cryptoPWHash
            passwordHashPtr
            (fromIntegral @CSize @CLLong cryptoPWHashStrBytes)
            cString
            (fromIntegral @Int @CULLong cStringLen)
            (castPtr saltString)
            opsLimit
            memLimit
            cryptoPWHashAlgDefault
      pure $ PasswordHash (castForeignPtr @CUChar @CChar hashForeignPtr)

-- | Verify the password hash against a clear 'Text' password
--
-- This function purposefully takes some time to complete, in order to alleviate bruteforce attacks.
--
-- @since 0.0.1.0
verifyText :: PasswordHash -> Text -> Bool
verifyText passwordHash clearTextPassword = verifyByteString passwordHash (Text.encodeUtf8 clearTextPassword)

-- | Verify the password hash against a clear 'StrictByteString' password
--
-- This function purposefully takes some time to complete, in order to alleviate bruteforce attacks.
--
-- @since 0.0.1.0
verifyByteString :: PasswordHash -> StrictByteString -> Bool
verifyByteString (PasswordHash fPtr) clearTextPassword = unsafeDupablePerformIO $ do
  BS.unsafeUseAsCStringLen clearTextPassword $ \(cString, cStringLen) -> do
    Foreign.withForeignPtr fPtr $ \hashPtr -> do
      result <-
        cryptoPWHashStrVerify
          hashPtr
          cString
          (fromIntegral @Int @CULLong cStringLen)
      pure $ result == 0

-- | Convert a 'PasswordHash' to a binary 'StrictByteString'.
--
-- @since 0.0.1.0
passwordHashToBinary :: PasswordHash -> StrictByteString
passwordHashToBinary (PasswordHash fPtr) =
  BS.fromForeignPtr (Foreign.castForeignPtr fPtr) 0 (fromIntegral @CSize @Int cryptoPWHashStrBytes)

-- | Convert a 'PasswordHash' to a hexadecimal-encoded 'StrictByteString'.
--
-- @since 0.0.1.0
passwordHashToHexByteString :: PasswordHash -> StrictByteString
passwordHashToHexByteString = Base16.encodeBase16' . passwordHashToBinary

-- | Convert a 'PasswordHash' to a strict hexadecimal-encoded 'Text'.
--
-- @since 0.0.1.0
passwordHashToHexText :: PasswordHash -> Text
passwordHashToHexText = Base16.encodeBase16 . passwordHashToBinary

-- | The 'Salt' is used in conjunction with 'hashByteStringWithParams'
-- when you want to manually provide the piece of data that will
-- differentiate two fingerprints of the same password.
--
-- It is automatically taken care of for you when you use
-- 'hashByteString' or 'hashText'.
--
-- Use 'genSalt' to create a 'Salt' of size
-- equal to the constant 'cryptoPWHashSaltBytes'.
--
-- @since 0.0.1.0
newtype Salt = Salt StrictByteString
  deriving (Eq, Ord, Show)

-- | Convert 'Salt to underlying 'StrictByteString' binary.
--
-- @since 0.0.2.0
saltToBinary :: Salt -> StrictByteString
saltToBinary (Salt bs) = bs

-- | Convert 'Salt to a strict hexadecimal-encoded 'Text'.
--
-- @since 0.0.2.0
saltToHexText :: Salt -> Text
saltToHexText = Base16.encodeBase16 . saltToBinary

-- | Convert 'Salt to a hexadecimal-encoded 'StrictByteString'.
--
-- @since 0.0.2.0
saltToHexByteString :: Salt -> StrictByteString
saltToHexByteString = Base16.encodeBase16' . saltToBinary

-- | Convert 'StrictByteString' to 'Salt'.
--
-- The input salt must be of length 'cryptoPWHashSaltBytes'.
--
-- @since 0.0.2.0
binaryToSalt :: StrictByteString -> Maybe Salt
binaryToSalt bs =
  if BS.length bs /= fromIntegral cryptoPWHashSaltBytes
    then Nothing
    else Just (Salt bs)

-- | Convert a strict hexadecimal-encoded 'Text' to a 'Salt'.
--
-- The input salt, once decoded from base16, must be of length 'cryptoPWHashSaltBytes'.
--
-- @since 0.0.1.0
hexTextToSalt :: Text -> Maybe Salt
hexTextToSalt hexText =
  case Base16.decodeBase16' hexText of
    Right binary -> binaryToSalt binary
    Left _ -> Nothing

-- | Convert a hexadecimal-encoded 'StrictByteString' to a 'Salt'.
--
-- The input salt, once decoded from base16, must be of length 'cryptoPWHashSaltBytes'.
--
-- @since 0.0.1.0
hexByteStringToSalt :: StrictByteString -> Maybe Salt
hexByteStringToSalt hexByteString =
  case Base16.decodeBase16 hexByteString of
    Right binary -> binaryToSalt binary
    Left _ -> Nothing

-- |
--
-- @since 0.0.1.0
data Argon2Params = Argon2Params
  { opsLimit :: CULLong
  , memLimit :: CSize
  }

-- | These are the default parameters with which 'hashByteStringWithParams' can be invoked:
--
-- * /opsLimit/ = 'cryptoPWHashOpsLimitModerate'
-- * /memLimit/ = 'cryptoPWHashMemLimitModerate'
--
-- @since 0.0.1.0
defaultArgon2Params :: Argon2Params
defaultArgon2Params =
  Argon2Params
    { opsLimit = cryptoPWHashOpsLimitModerate
    , memLimit = cryptoPWHashMemLimitModerate
    }

-- | Generate a random 'Salt' for password hashing
--
-- @since 0.0.1.0
genSalt :: IO Salt
genSalt =
  Salt
    <$> BS.create
      (fromIntegral cryptoPWHashSaltBytes)
      (`randombytesBuf` cryptoPWHashSaltBytes)
