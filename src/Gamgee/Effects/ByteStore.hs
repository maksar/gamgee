module Gamgee.Effects.ByteStore
  ( -- * Effect
    ByteStore (..)

    -- * Actions
  , readByteStore
  , writeByteStore

  ) where

import qualified Polysemy as P
import           Relude


----------------------------------------------------------------------------------------------------
-- A store for saving and reading bytes
----------------------------------------------------------------------------------------------------

data ByteStore m a where
  ReadByteStore :: ByteStore m (Maybe LByteString)
  WriteByteStore :: LByteString -> ByteStore m ()

P.makeSem ''ByteStore
