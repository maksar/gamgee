{-# OPTIONS_GHC -fno-warn-orphans #-}

module Gamgee.Program.Effects
  ( runM_
  , runByteStoreIO
  , runOutputStdOut
  , runOutputClipboard
  , runErrorStdErr
  , configFilePath
  , ByteStoreError(..)
  ) where

import           Control.Exception.Safe (catch)
import qualified Data.Text.IO           as TIO
import qualified Gamgee.Effects         as Eff
import qualified Gamgee.Token           as Token
import           Polysemy               (Embed, Member, Members, Sem)
import qualified Polysemy               as P
import qualified Polysemy.Error         as P
import qualified Polysemy.Output        as P
import           Relude
import qualified System.Directory       as Dir
import           System.FilePath        ((</>))
import qualified System.Hclip           as Clip
import qualified System.IO.Error        as IO
import qualified System.Posix.Files     as Files


-- | A version of runM that ignores its result
runM_ :: Monad m => Sem '[Embed m] a -> m ()
runM_ = void . P.runM


----------------------------------------------------------------------------------------------------
-- Interpret Output by writing it to stdout or clipboard
----------------------------------------------------------------------------------------------------

runOutputStdOut :: Member (Embed IO) r => Sem (P.Output Text : r) a -> Sem r a
runOutputStdOut = P.interpret $ \case
  P.Output s -> P.embed @IO $ putTextLn s

runOutputClipboard :: Member (Embed IO) r => Sem (P.Output Text : r) a -> Sem r a
runOutputClipboard = P.interpret $ \case
  P.Output s -> P.embed $ Clip.setClipboard $ toString s


----------------------------------------------------------------------------------------------------
-- Interpret Error by writing it to stderr
----------------------------------------------------------------------------------------------------

instance ToText Eff.EffError where
  toText (Eff.AlreadyExists ident)        = "A token named '" <> Token.unTokenIdentifier ident <> "' already exists."
  toText (Eff.NoSuchToken ident)          = "No such token: '" <> Token.unTokenIdentifier ident <> "'"
  toText (Eff.CryptoError ce)             = show ce
  toText (Eff.CorruptIV _)                = "Internal Error: Unable to decode initial vector, your config is probably corrupt"
  toText (Eff.CorruptBase64Encoding msg)  = msg
  toText (Eff.SecretDecryptError _)       = "Error decrypting token. Did you provide an incorrect password?"
  toText (Eff.InvalidTokenPeriod tp)      = "Unsupported token period: " <> show (Token.unTokenPeriod tp)
  toText (Eff.UnsupportedConfigVersion v) = "Internal Error: Unsupported config version: " <> show v
  toText (Eff.JSONDecodeError msg)        = "Internal Error: Could not decode Gamgee config file: " <> msg

data ByteStoreError = ReadError IO.IOError
                    | WriteError IO.IOError

instance ToText ByteStoreError where
  toText (ReadError e)  = "Internal Error: Error reading configuration file: " <> show e
  toText (WriteError e) = "Internal Error: Error saving configuration file: " <> show e

runErrorStdErr :: Member (Embed IO) r => Sem (P.Error Eff.EffError : P.Error ByteStoreError : r) a -> Sem r (Maybe a)
runErrorStdErr = fmap join . runToTextError . runToTextError

runToTextError :: (Member (Embed IO) r, ToText e) => Sem (P.Error e : r) a -> Sem r (Maybe a)
runToTextError a = P.runError a >>= either (printError . toText) (return . Just)
  where
    printError :: Member (Embed IO) r => Text -> Sem r (Maybe a)
    printError msg = P.embed (TIO.hPutStrLn stderr msg) $> Nothing


----------------------------------------------------------------------------------------------------
-- Interpret ByteStore using a file
----------------------------------------------------------------------------------------------------

runByteStoreFile :: ( Members [Embed IO, P.Error e] r
                    , Exception e1
                    , Exception e2)
                 => FilePath
                 -> (e1 -> Either e (Maybe LByteString)) -- ^ Function to handle read errors
                 -> (e2 -> Maybe e)                      -- ^ Function to handle write errors
                 -> Sem (Eff.ByteStore : r) a
                 -> Sem r a
runByteStoreFile file handleReadError handleWriteError = P.interpret $ \case
  Eff.ReadByteStore        -> do
    res <- P.embed @IO $ (Right . Just <$> readFileLBS file) `catch` (return . handleReadError)
    either P.throw return res
  Eff.WriteByteStore bytes -> do
    res <- P.embed @IO $ (writeFileLBS file bytes $> Nothing) `catch` (return . handleWriteError)
    whenJust res P.throw
    P.embed $ Files.setFileMode file $ Files.ownerReadMode `Files.unionFileModes` Files.ownerWriteMode

runByteStoreIO :: Members [Embed IO, P.Error ByteStoreError] r
               => Sem (Eff.ByteStore : r) a
               -> Sem r a
runByteStoreIO prog = do
  file <- P.embed configFilePath
  runByteStoreFile file handleReadError handleWriteError prog

  where
    handleReadError :: IO.IOError -> Either ByteStoreError (Maybe LByteString)
    handleReadError e = if IO.isDoesNotExistError e
                        then Right Nothing
                        else Left $ ReadError e

    handleWriteError :: IO.IOError -> Maybe ByteStoreError
    handleWriteError e = Just $ WriteError e

-- | Path under which tokens are stored - typically ~/.config/gamgee/tokens.json
configFilePath :: IO FilePath
configFilePath = do
  dir <- Dir.getXdgDirectory Dir.XdgConfig "gamgee"
  Dir.createDirectoryIfMissing True dir
  return $ dir </> "tokens.json"
