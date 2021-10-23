-- | This module provides toml configuration for the custom single service.
module Navi.Services.Custom.Single.Toml
  ( SingleToml (..),
    singleCodec,
  )
where

import Navi.Data.NaviNote (NaviNote)
import Navi.Data.NaviNote qualified as NaviNote
import Navi.Event (Command (..))
import Navi.Event.Toml (ErrorNoteToml, RepeatEvtToml)
import Navi.Event.Toml qualified as EventToml
import Navi.Prelude
import Toml (TomlCodec, (.=))
import Toml qualified

-- | Codec for 'SingleToml'.
data SingleToml = MkSingleToml
  { -- | The command to run.
    command :: Command,
    -- | The alert trigger.
    triggerVal :: Text,
    -- | The notification to send.
    note :: NaviNote,
    -- | Determines how we treat repeat alerts.
    repeatEvtCfg :: Maybe RepeatEvtToml,
    -- | Determines how we handle errors.
    errEvtCfg :: Maybe ErrorNoteToml
  }
  deriving (Show)

-- | Codec for 'SingleToml'.
singleCodec :: TomlCodec SingleToml
singleCodec =
  MkSingleToml
    <$> EventToml.commandCodec .= command
      <*> Toml.text "trigger" .= triggerVal
      <*> Toml.table NaviNote.naviNoteCodec "note" .= note
      <*> Toml.dioptional EventToml.repeatEvtCodec .= repeatEvtCfg
      <*> Toml.dioptional EventToml.errorNoteCodec .= errEvtCfg
