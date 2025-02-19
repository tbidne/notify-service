{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Tests fatal exceptions.
module Integration.Exceptions (tests) where

import Data.Text qualified as T
import Data.Time.Calendar.OrdinalDate (fromOrdinalDate)
import Data.Time.LocalTime (LocalTime (LocalTime), TimeOfDay (TimeOfDay), utc)
import Effects.Concurrent.Async (ExceptionInLinkedThread (ExceptionInLinkedThread))
import Effects.Concurrent.Async qualified as Async
import Effects.Concurrent.Thread (sleep)
import Effects.FileSystem.FileReader (decodeUtf8Lenient)
import Effects.LoggerNS
  ( MonadLoggerNS (getNamespace, localNamespace),
    defaultLogFormatter,
    formatLog,
  )
import Effects.System.Terminal
  ( MonadTerminal
      ( getChar,
        getContents',
        getLine,
        getTerminalSize,
        putBinary,
        putStr,
        supportsPretty
      ),
  )
import Effects.Time
  ( MonadTime (getMonotonicTime, getSystemZonedTime),
    ZonedTime (ZonedTime),
  )
import Integration.Prelude
import Navi (runNavi)
import Navi.Data.NaviLog (LogEnv (MkLogEnv, logHandle, logLevel, logNamespace))
import Navi.Data.NaviNote (NaviNote)
import Navi.Effects.MonadNotify (MonadNotify (sendNote))
import Navi.Effects.MonadSystemInfo (MonadSystemInfo (query))
import Navi.Env.Core
  ( HasEvents (getEvents),
    HasLogEnv (getLogEnv, localLogEnv),
    HasLogQueue (getLogQueue),
    HasNoteQueue (getNoteQueue),
  )
import Navi.Event.Types
  ( AnyEvent (MkAnyEvent),
    ErrorNote (NoErrNote),
    Event
      ( MkEvent,
        errorNote,
        name,
        pollInterval,
        raiseAlert,
        repeatEvent,
        serviceType
      ),
    RepeatEvent (AllowRepeats),
  )
import Navi.NaviT (NaviT, runNaviT)
import Navi.Services.Types
  ( ServiceType
      ( BatteryPercentage,
        BatteryStatus,
        Multiple,
        NetworkInterface,
        Single
      ),
  )
import Navi.Utils qualified as U
import Test.Tasty qualified as Tasty

data BadThread
  = LogThread
  | NotifyThread

-- | Mock configuration.
data ExceptionEnv = MkExceptionEnv
  { badThread :: BadThread,
    events :: NonEmpty AnyEvent,
    logEnv :: LogEnv,
    logQueue :: TBQueue LogStr,
    logsRef :: IORef (Seq ByteString),
    noteQueue :: TBQueue NaviNote
  }

makeFieldLabelsNoPrefix ''ExceptionEnv

instance HasEvents ExceptionEnv where
  getEvents = view #events

instance HasLogEnv ExceptionEnv where
  getLogEnv = view #logEnv
  localLogEnv = over' #logEnv

instance HasLogQueue ExceptionEnv where
  getLogQueue = view #logQueue

instance HasNoteQueue ExceptionEnv where
  getNoteQueue = view #noteQueue

newtype ExceptionIO a = MkExceptionIO (IO a)
  deriving
    ( Functor,
      Applicative,
      Monad,
      MonadAsync,
      MonadCatch,
      MonadHandleWriter,
      MonadIORef,
      MonadMask,
      MonadSTM,
      MonadThread,
      MonadThrow
    )
    via IO

newtype TestEx = MkTestE String
  deriving stock (Show)
  deriving anyclass (Exception)

instance MonadTerminal (NaviT ExceptionEnv ExceptionIO) where
  putStr = error "putStr: todo"
  getChar = error "getChar: todo"
  getContents' = error "getContents': todo"
  getLine = error "getLine: todo"
  getTerminalSize = error "getTerminalSize: todo"

  -- NOTE: putBinary is used to fatally kill the logger thread, if we are
  -- testing it (badThread == LogThread)
  putBinary bs = do
    asks (view #badThread) >>= \case
      NotifyThread -> do
        logsRef <- asks (view #logsRef)
        modifyIORef' logsRef (bs :<|)
      LogThread -> sleep 2 *> throwM (MkTestE "logger dying")
  supportsPretty = error "supportsPretty: todo"

instance MonadSystemInfo (NaviT ExceptionEnv ExceptionIO) where
  query = \case
    BatteryPercentage _ -> error "battery percentage unimplemented"
    BatteryStatus _ -> error "battery status unimplemented"
    NetworkInterface _ _ -> error "network interface unimplemented"
    Single _ -> pure "single"
    Multiple _ -> pure "multiple"

instance MonadLogger (NaviT ExceptionEnv ExceptionIO) where
  monadLoggerLog loc _src lvl msg = do
    logQueue <- asks getLogQueue
    logLevel <- asks (view #logLevel . getLogEnv)
    when (logLevel <= lvl) $ do
      formatted <- formatLog (defaultLogFormatter loc) lvl msg
      writeTBQueueA logQueue formatted

instance MonadLoggerNS (NaviT ExceptionEnv ExceptionIO) where
  getNamespace = asks (view #logNamespace . getLogEnv)
  localNamespace f = local (localLogEnv (over' #logNamespace f))

instance MonadTime (NaviT ExceptionEnv ExceptionIO) where
  getSystemZonedTime = pure zonedTime
  getMonotonicTime = pure 0

localTime :: LocalTime
localTime = LocalTime day tod
  where
    day = fromOrdinalDate 2022 39
    tod = TimeOfDay 10 20 5

zonedTime :: ZonedTime
zonedTime = ZonedTime localTime utc

instance MonadNotify (NaviT ExceptionEnv ExceptionIO) where
  -- NOTE: sendNote is used to fatally kill the notify thread, if we are
  -- testing it (badThread == NotifyThread)
  sendNote _ = do
    asks (view #badThread) >>= \case
      LogThread -> pure ()
      NotifyThread -> sleep 2 *> throwM (MkTestE "notify dying")

-- | Runs integration tests.
tests :: TestTree
tests =
  Tasty.testGroup
    "Exceptions"
    [ badLoggerDies,
      badNotifierDies
    ]

badLoggerDies :: TestTree
badLoggerDies = testCase "Logger exception kills Navi" $ do
  (ExceptionInLinkedThread _ ex, _) <- runExceptionApp LogThread
  "MkTestE \"logger dying\"" @=? U.displayInner ex

badNotifierDies :: TestTree
badNotifierDies = testCase "Notify exception kills Navi" $ do
  (ex, logs) <- runExceptionApp @SomeException NotifyThread
  "MkTestE \"notify dying\"" @=? U.displayInner ex

  -- search for log
  foundLogRef <- newIORef False
  for_ logs $ \l -> do
    let t = decodeUtf8Lenient l
    when (errLog `T.isPrefixOf` t) $ writeIORef foundLogRef True

  foundLog <- readIORef foundLogRef
  unless foundLog (assertFailure $ "Did not find expectedLog: " <> show logs)
  where
    errLog = "[2022-02-08 10:20:05][int-ex-test][src/Navi.hs:123:8][Error] Notify: MkTestE \"notify dying\""

runExceptionApp ::
  forall e.
  (Exception e) =>
  BadThread ->
  IO (e, Seq ByteString)
runExceptionApp badThread = do
  let event =
        MkAnyEvent
          $ MkEvent
            { name = "exception test",
              serviceType = Single "",
              pollInterval = 1,
              repeatEvent = AllowRepeats,
              errorNote = NoErrNote,
              raiseAlert = const Nothing
            }

  logQueue <- newTBQueueA 10
  noteQueue <- newTBQueueA 10
  logsRef <- newIORef []

  let env :: ExceptionEnv
      env =
        MkExceptionEnv
          { badThread,
            events = [event],
            logEnv =
              MkLogEnv
                { logHandle = Nothing,
                  logLevel = LevelDebug,
                  logNamespace = "int-ex-test"
                },
            logQueue,
            logsRef,
            noteQueue
          }

      -- NOTE: timeout after 10 seconds
      MkExceptionIO testRun = Async.race (sleep 10_000_000) (runNaviT runNavi env)

  try @_ @e testRun >>= \case
    Left ex -> do
      logs <- readIORef logsRef
      pure (ex, logs)
    Right (Left _) -> error "Exception test timed out!"
    Right (Right _) -> error "Navi finished successfully, impossible!"
