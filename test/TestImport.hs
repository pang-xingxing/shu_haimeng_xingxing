{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module TestImport
  ( module TestImport,
    module X,
  )
where

import Application (makeFoundation, makeLogWare)
import ClassyPrelude as X hiding (Handler, delete, deleteBy)
-- Wiping the database

import Control.Monad.Logger (runLoggingT)
import Database.Persist as X hiding (get)
import Database.Persist.Sql (SqlPersistM, rawExecute, rawSql, runSqlPersistMPool, unSingle)
import Database.Persist.SqlBackend (getEscapedRawName)
import Database.Persist.Sqlite (createSqlitePoolFromInfo, fkEnabled, mkSqliteConnectionInfo, sqlDatabase)
import Foundation as X
import Lens.Micro (set)
import Model as X
import Settings (appDatabaseConf)
import Test.Hspec as X
import Yesod.Auth as X
import Yesod.Core (messageLoggerSource)
import Yesod.Core.Unsafe (fakeHandlerGetLogger)
import Yesod.Default.Config2 (loadYamlSettings, useEnv)
import Yesod.Test as X

runDB :: SqlPersistM a -> YesodExample App a
runDB query = do
  pool <- fmap appConnPool getTestYesod
  liftIO $ runSqlPersistMPool query pool

runHandler :: Handler a -> YesodExample App a
runHandler handler = do
  app <- getTestYesod
  fakeHandlerGetLogger appLogger app handler

withApp :: SpecWith (TestApp App) -> Spec
withApp = before $ do
  settings <-
    loadYamlSettings
      ["config/test-settings.yml", "config/settings.yml"]
      []
      useEnv
  foundation <- makeFoundation settings
  wipeDB foundation
  logWare <- liftIO $ makeLogWare foundation
  return (foundation, logWare)

-- This function will truncate all of the tables in your database.
-- 'withApp' calls it before each test, creating a clean environment for each
-- spec to run in.
wipeDB :: App -> IO ()
wipeDB app = do
  -- In order to wipe the database, we need to use a connection which has
  -- foreign key checks disabled.  Foreign key checks are enabled or disabled
  -- per connection, so this won't effect queries outside this function.
  --
  -- Aside: foreign key checks are enabled by persistent-sqlite, as of
  -- version 2.6.2, unless they are explicitly disabled in the
  -- SqliteConnectionInfo.

  let logFunc = messageLoggerSource app (appLogger app)

  let dbName = sqlDatabase $ appDatabaseConf $ appSettings app
      connInfo = set fkEnabled False $ mkSqliteConnectionInfo dbName

  pool <- runLoggingT (createSqlitePoolFromInfo connInfo 1) logFunc

  flip runSqlPersistMPool pool $ do
    tables <- getTables
    sqlBackend <- ask
    let queries = map (\t -> "DELETE FROM " ++ getEscapedRawName t sqlBackend) tables
    forM_ queries (`rawExecute` [])

getTables :: DB [Text]
getTables = do
  tables <- rawSql "SELECT name FROM sqlite_master WHERE type = 'table';" []
  return (fmap unSingle tables)

-- | Authenticate as a user. This relies on the `auth-dummy-login: true` flag
-- being set in test-settings.yaml, which enables dummy authentication in
-- Foundation.hs
authenticateAs :: Entity User -> YesodExample App ()
authenticateAs (Entity _ u) = do
  request $ do
    setMethod "POST"
    addPostParam "ident" $ userIdent u
    setUrl $ AuthR $ PluginR "dummy" []

-- | Create a user.  The dummy email entry helps to confirm that foreign-key
-- checking is switched off in wipeDB for those database backends which need it.
createUser :: Text -> YesodExample App (Entity User)
createUser ident = runDB $ do
  user <-
    insertEntity
      User
        { userIdent = ident,
          userPassword = Nothing
        }
  _ <-
    insert
      Email
        { emailEmail = ident,
          emailUserId = Just $ entityKey user,
          emailVerkey = Nothing
        }
  return user
