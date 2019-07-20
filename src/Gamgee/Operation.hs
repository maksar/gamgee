module Gamgee.Operation
  ( addToken
  , deleteToken
  , listTokens
  , getOTP
  , getInfo
  ) where


import           Data.Aeson            ((.=))
import qualified Data.Aeson            as Aeson
import qualified Data.Time.Clock.POSIX as Clock
import qualified Data.Version          as Version
import qualified Gamgee.Effects        as Eff
import qualified Gamgee.Token          as Token
import           Paths_gamgee          (version)
import           Polysemy              (Member, Members, Sem)
import qualified Polysemy.Error        as P
import qualified Polysemy.Input        as P
import qualified Polysemy.Output       as P
import qualified Polysemy.State        as P
import           Relude
import qualified Relude.Extra.Map      as Map


getTokens :: Member (P.State Token.Tokens) r => Sem r Token.Tokens
getTokens = P.get

addToken :: Members [ P.State Token.Tokens
                    , Eff.Crypto
                    , Eff.SecretInput Text
                    , P.Error Eff.EffError ] r
         => Token.TokenSpec
         -> Sem r ()
addToken spec = do
  let ident = Token.getIdentifier spec
  tokens <- getTokens
  if ident `Map.member` tokens
  then P.throw $ Eff.AlreadyExists ident
  else do
    spec' <- Eff.encryptSecret spec
    P.put $ Map.insert ident spec' tokens

deleteToken :: Members [ P.State Token.Tokens
                       , P.Error Eff.EffError ] r
            => Token.TokenIdentifier
            -> Sem r ()
deleteToken ident = do
  tokens <- getTokens
  case Map.lookup ident tokens of
    Nothing -> P.throw $ Eff.NoSuchToken ident
    Just _  -> P.put $ Map.delete ident tokens

listTokens :: Members [ P.State Token.Tokens
                      , P.Output Text ] r
           => Sem r ()
listTokens = do
  tokens <- getTokens
  mapM_ (P.output . Token.unTokenIdentifier . Token.getIdentifier) tokens

getOTP :: Members [ P.State Token.Tokens
                  , P.Error Eff.EffError
                  , P.Output Text
                  , Eff.TOTP ] r
       => Token.TokenIdentifier
       -> Clock.POSIXTime
       -> Sem r ()
getOTP ident time = do
  tokens <- getTokens
  case Map.lookup ident tokens of
    Nothing   -> P.throw $ Eff.NoSuchToken ident
    Just spec -> Eff.getTOTP spec time >>= P.output

getInfo :: Members [ P.Input FilePath
                   , P.Output Aeson.Value ] r
        => Sem r (Maybe Token.Config)
        -> Sem r ()
getInfo cfg = do
  path <- P.input @FilePath

  -- Info command should work even if the config file can't be read. So we handle the
  -- potential "missing" config here with a `Maybe Config`.
  cfgVersion <- maybe Aeson.Null (Aeson.toJSON . Token.configVersion) <$> cfg

  let info = Aeson.object [ "version" .= Version.showVersion version
                          , "config"  .= Aeson.object [ "filepath" .= path
                                                      , "version"  .= cfgVersion ]
                          ]
  P.output info

