{-# LANGUAGE OverloadedStrings #-}

module Haskell.Ide.Engine.Plugin.Floskell
  ( floskellDescriptor
  )
where

import           Control.Monad.IO.Class         (liftIO)
import           Data.Aeson                     (Value (Null))
import qualified Data.ByteString.Lazy           as BS
import qualified Data.Text                      as T
import qualified Data.Text.Encoding             as T
import           Data.Maybe
import           Floskell
import           Haskell.Ide.Engine.MonadTypes
import           Haskell.Ide.Engine.PluginUtils
import qualified Language.Haskell.LSP.Types            as J

floskellDescriptor :: PluginId -> PluginDescriptor
floskellDescriptor plId = PluginDescriptor
  { pluginId                 = plId
  , pluginName               = "Floskell"
  , pluginDesc               = "A flexible Haskell source code pretty printer."
  , pluginCommands = [ PluginCommand "formatText"
                                     "Format the given Text with Floskell"
                                     formatCmd
                     ]
  , pluginCodeActionProvider = Nothing
  , pluginDiagnosticProvider = Nothing
  , pluginHoverProvider      = Nothing
  , pluginSymbolProvider     = Nothing
  , pluginFormattingProvider = Just provider
  }

-- | Format provider of Floskell.
-- Formats the given source in either a given Range or the whole Document.
-- If the provider fails an error is returned that can be displayed to the user.
provider :: FormattingProvider
provider uri typ _opts =
  pluginGetFile "Floskell: " uri $ \file -> do
    config <- liftIO $ findConfigOrDefault file
    mContents <- readVFS uri
    case mContents of
      Nothing -> return $ IdeResultFail (IdeError InternalError "File was not open" Null)
      Just contents ->
        let (range, selectedContents) = case typ of
              FormatDocument -> (fullRange contents, contents)
              FormatRange r  -> (r, extractRange r contents)
            result = reformat config (uriToFilePath uri) (BS.fromStrict (T.encodeUtf8 selectedContents))
        in  case result of
              Left  err -> return $ IdeResultFail (IdeError PluginError (T.pack $  "floskellCmd: " ++ err) Null)
              Right new -> return $ IdeResultOk [TextEdit range (T.decodeUtf8 (BS.toStrict new))]

-- | Format a source with the given options.
-- Synchronized command.
-- Other plugins can use this Command it to execute formatters.
-- Command can be run by 
-- ```
-- runPluginCommand
--     (pluginId plugin)
--     "formatText"
--     (dynToJSON $ toDynJSON $ FormatTextCmdParams t r (FormattingOptions 2 True))
-- ```
formatCmd :: CommandFunc FormatTextCmdParams [TextEdit]
formatCmd = CmdSync $ \(FormatTextCmdParams text fmtRange _) -> do
  rootPath <- getRootPath
  config   <- liftIO $ findConfigOrDefault (fromMaybe "" rootPath)
  let textEdit = reformat config Nothing (BS.fromStrict (T.encodeUtf8 text))
  case textEdit of
    Left err -> return $ IdeResultFail
      (IdeError PluginError (T.pack $ "floskellCmd: " ++ err) Null)
    Right newText -> do
      let edit = J.TextEdit fmtRange (T.decodeUtf8 (BS.toStrict newText))
      return $ IdeResultOk [edit]

-- | Find Floskell Config, user and system wide or provides a default style.
-- Every directory of the filepath will be searched to find a user configuration.
-- Also looks into places such as XDG_CONFIG_DIRECTORY<https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html>.
-- This function may not throw an exception and returns a default config.
findConfigOrDefault :: FilePath -> IO AppConfig
findConfigOrDefault file = do
  mbConf <- findAppConfigIn file
  case mbConf of
    Just confFile -> readAppConfig confFile
    Nothing ->
      let gibiansky = head (filter (\s -> styleName s == "gibiansky") styles)
      in return $ defaultAppConfig { appStyle = gibiansky }
