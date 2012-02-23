{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Allocate resources which are guaranteed to be released.
--
-- For more information, see <http://www.yesodweb.com/blog/2011/12/resourcet>.
--
-- One point to note: all register cleanup actions live in the base monad, not
-- the main monad. This allows both more efficient code, and for monads to be
-- transformed.
module Control.Monad.Trans.Resource
    ( -- * Data types
      ResourceT
    , ReleaseKey
      -- * Unwrap
    , runResourceT
      -- * Resource allocation
    , with
    , register
    , release
      -- * Special actions
    , resourceForkIO
      -- * Monad transformation
    , transResourceT
      -- * A specific Exception transformer
    , ExceptionT (..)
    , runExceptionT_
      -- * Type class/associated types
    , ResourceIO
    , MonadUnsafeIO (..)
    , MonadThrow (..)
      -- ** Low-level
    , InvalidAccess (..)
    , resourceActive
      -- * Re-exports
    , MonadBaseControl
    ) where

import Data.Typeable
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Control.Exception (SomeException, throw, Exception)
import Control.Monad.Trans.Control
    ( MonadTransControl (..), MonadBaseControl (..)
    , ComposeSt, defaultLiftBaseWith, defaultRestoreM
    , liftBaseDiscard, control
    )
import qualified Data.IORef as I
import Control.Monad.Base (MonadBase, liftBase)
import Control.Applicative (Applicative (..))
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad (liftM)
import qualified Control.Exception as E
import Data.Monoid (Monoid)
import qualified Control.Exception.Lifted as L

import Control.Monad.Trans.Identity ( IdentityT)
import Control.Monad.Trans.List     ( ListT    )
import Control.Monad.Trans.Maybe    ( MaybeT   )
import Control.Monad.Trans.Error    ( ErrorT, Error)
import Control.Monad.Trans.Reader   ( ReaderT  )
import Control.Monad.Trans.State    ( StateT   )
import Control.Monad.Trans.Writer   ( WriterT  )
import Control.Monad.Trans.RWS      ( RWST     )

import Data.Word (Word)

import qualified Control.Monad.Trans.RWS.Strict    as Strict ( RWST   )
import qualified Control.Monad.Trans.State.Strict  as Strict ( StateT )
import qualified Control.Monad.Trans.Writer.Strict as Strict ( WriterT )
import Control.Concurrent (ThreadId, forkIO)

import Control.Monad.ST (ST, unsafeIOToST)
import qualified Control.Monad.ST.Lazy as Lazy

-- | A lookup key for a specific release action. This value is returned by
-- 'register', 'with' and 'withIO', and is passed to 'release'.
newtype ReleaseKey = ReleaseKey Int
    deriving Typeable

type RefCount = Word
type NextKey = Int

data ReleaseMap =
    ReleaseMap !NextKey !RefCount !(IntMap (IO ()))
  | ReleaseMapClosed

-- | The Resource transformer. This transformer keeps track of all registered
-- actions, and calls them upon exit (via 'runResourceT'). Actions may be
-- registered via 'register', or resources may be allocated atomically via
-- 'with' or 'withIO'. The with functions correspond closely to @bracket@.
--
-- Releasing may be performed before exit via the 'release' function. This is a
-- highly recommended optimization, as it will ensure that scarce resources are
-- freed early. Note that calling @release@ will deregister the action, so that
-- a release action will only ever be called once.
newtype ResourceT m a = ResourceT (I.IORef ReleaseMap -> m a)

instance Typeable1 m => Typeable1 (ResourceT m) where
    typeOf1 = goType undefined
      where
        goType :: Typeable1 m => m a -> ResourceT m a -> TypeRep
        goType m _ =
            mkTyConApp
                (mkTyCon "Control.Monad.Trans.Resource.ResourceT")
                [ typeOf1 m
                ]

class (MonadIO m, MonadBaseControl IO m) => ResourceIO m
instance (MonadIO m, MonadBaseControl IO m) => ResourceIO m

-- | Perform some allocation, and automatically register a cleanup action.
--
-- If you are performing an @IO@ action, it will likely be easier to use the
-- 'withIO' function, which handles types more cleanly.
with :: MonadIO m
     => IO a -- ^ allocate
     -> (a -> IO ()) -- ^ free resource
     -> ResourceT m (ReleaseKey, a)
with acquire rel = ResourceT $ \istate -> liftIO $ E.mask $ \restore -> do
    a <- restore acquire
    key <- register' istate $ rel a
    return (key, a)

-- | Register some action that will be called precisely once, either when
-- 'runResourceT' is called, or when the 'ReleaseKey' is passed to 'release'.
register :: MonadIO m
         => IO ()
         -> ResourceT m ReleaseKey
register rel = ResourceT $ \istate -> liftIO $ register' istate rel

register' :: I.IORef ReleaseMap
          -> IO ()
          -> IO ReleaseKey
register' istate rel = I.atomicModifyIORef istate $ \rm ->
    case rm of
        ReleaseMap key rf m ->
            ( ReleaseMap (key + 1) rf (IntMap.insert key rel m)
            , ReleaseKey key
            )
        ReleaseMapClosed -> throw $ InvalidAccess "register'"

data InvalidAccess = InvalidAccess { functionName :: String }
    deriving Typeable

instance Show InvalidAccess where
    show (InvalidAccess f) = concat
        [ "Control.Monad.Trans.Resource."
        , f
        , ": The mutable state is being accessed after cleanup. Please contact the maintainers."
        ]

instance Exception InvalidAccess

-- | Call a release action early, and deregister it from the list of cleanup
-- actions to be performed.
release :: MonadIO m
        => ReleaseKey
        -> ResourceT m ()
release rk = ResourceT $ \istate -> liftIO $ release' istate rk

release' :: I.IORef ReleaseMap
         -> ReleaseKey
         -> IO ()
release' istate (ReleaseKey key) = E.mask $ \restore -> do
    maction <- I.atomicModifyIORef istate lookupAction
    maybe (return ()) restore maction
  where
    lookupAction rm@(ReleaseMap next rf m) =
        case IntMap.lookup key m of
            Nothing -> (rm, Nothing)
            Just action ->
                ( ReleaseMap next rf $ IntMap.delete key m
                , Just action
                )
    lookupAction ReleaseMapClosed = throw $ InvalidAccess "release'"

stateAlloc :: I.IORef ReleaseMap -> IO ()
stateAlloc istate = do
    I.atomicModifyIORef istate $ \rm ->
        case rm of
            ReleaseMap nk rf m ->
                (ReleaseMap nk (rf + 1) m, ())
            ReleaseMapClosed -> throw $ InvalidAccess "stateAlloc"

stateCleanup :: I.IORef ReleaseMap -> IO ()
stateCleanup istate = E.mask_ $ do
    mm <- I.atomicModifyIORef istate $ \rm ->
        case rm of
            ReleaseMap nk rf m ->
                let rf' = rf - 1
                 in if rf' == minBound
                        then (ReleaseMapClosed, Just m)
                        else (ReleaseMap nk rf' m, Nothing)
            ReleaseMapClosed -> throw $ InvalidAccess "stateCleanup"
    case mm of
        Just m ->
            mapM_ (\x -> try x >> return ()) $ IntMap.elems m
        Nothing -> return ()
  where
    try :: IO a -> IO (Either SomeException a)
    try = E.try

-- | Unwrap a 'ResourceT' transformer, and call all registered release actions.
--
-- Note that there is some reference counting involved due to 'resourceForkIO'.
-- If multiple threads are sharing the same collection of resources, only the
-- last call to @runResourceT@ will deallocate the resources.
runResourceT :: MonadBaseControl IO m => ResourceT m a -> m a
runResourceT (ResourceT r) = do
    istate <- liftBase $ I.newIORef
        $ ReleaseMap minBound minBound IntMap.empty
    bracket_
        (stateAlloc istate)
        (stateCleanup istate)
        (r istate)

bracket_ :: MonadBaseControl IO m => IO () -> IO () -> m a -> m a
bracket_ alloc cleanup inside =
    control $ \run -> E.bracket_ alloc cleanup (run inside)

-- | Transform the monad a @ResourceT@ lives in. This is most often used to
-- strip or add new transformers to a stack, e.g. to run a @ReaderT@. Note that
-- the original and new monad must both have the same 'Base' monad.
transResourceT :: (m a -> n b)
               -> ResourceT m a
               -> ResourceT n b
transResourceT f (ResourceT mx) = ResourceT (\r -> f (mx r))

-------- All of our monad et al instances
instance Functor m => Functor (ResourceT m) where
    fmap f (ResourceT m) = ResourceT $ \r -> fmap f (m r)

instance Applicative m => Applicative (ResourceT m) where
    pure = ResourceT . const . pure
    ResourceT mf <*> ResourceT ma = ResourceT $ \r ->
        mf r <*> ma r

instance Monad m => Monad (ResourceT m) where
    return = ResourceT . const . return
    ResourceT ma >>= f = ResourceT $ \r -> do
        a <- ma r
        let ResourceT f' = f a
        f' r

instance MonadTrans ResourceT where
    lift = ResourceT . const

instance MonadIO m => MonadIO (ResourceT m) where
    liftIO = lift . liftIO

instance MonadBase b m => MonadBase b (ResourceT m) where
    liftBase = lift . liftBase

instance MonadTransControl ResourceT where
    newtype StT ResourceT a = StReader {unStReader :: a}
    liftWith f = ResourceT $ \r -> f $ \(ResourceT t) -> liftM StReader $ t r
    restoreT = ResourceT . const . liftM unStReader
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadBaseControl b m => MonadBaseControl b (ResourceT m) where
     newtype StM (ResourceT m) a = StMT (StM m a)
     liftBaseWith f = ResourceT $ \reader ->
         liftBaseWith $ \runInBase ->
             f $ liftM StMT . runInBase . (\(ResourceT r) -> r reader)
     restoreM (StMT base) = ResourceT $ const $ restoreM base
instance Monad m => MonadThrow (ExceptionT m) where
    monadThrow = ExceptionT . return . Left . E.toException


-- | The express purpose of this transformer is to allow the 'ST' monad to
-- catch exceptions via the 'MonadThrow' typeclass.
newtype ExceptionT m a = ExceptionT { runExceptionT :: m (Either SomeException a) }

-- | Same as 'runExceptionT', but immediately 'E.throw' any exception returned.
runExceptionT_ :: Monad m => ExceptionT m a -> m a
runExceptionT_ = liftM (either E.throw id) . runExceptionT

instance Monad m => Functor (ExceptionT m) where
    fmap f = ExceptionT . (liftM . fmap) f . runExceptionT
instance Monad m => Applicative (ExceptionT m) where
    pure = ExceptionT . return . Right
    ExceptionT mf <*> ExceptionT ma = ExceptionT $ do
        ef <- mf
        case ef of
            Left e -> return (Left e)
            Right f -> do
                ea <- ma
                case ea of
                    Left e -> return (Left e)
                    Right x -> return (Right (f x))
instance Monad m => Monad (ExceptionT m) where
    return = pure
    ExceptionT ma >>= f = ExceptionT $ do
        ea <- ma
        case ea of
            Left e -> return (Left e)
            Right a -> runExceptionT (f a)
instance MonadBase b m => MonadBase b (ExceptionT m) where
    liftBase = lift . liftBase
instance MonadTrans ExceptionT where
    lift = ExceptionT . liftM Right
instance MonadTransControl ExceptionT where
    newtype StT ExceptionT a = StExc { unStExc :: Either SomeException a }
    liftWith f = ExceptionT $ liftM return $ f $ liftM StExc . runExceptionT
    restoreT = ExceptionT . liftM unStExc
instance MonadBaseControl b m => MonadBaseControl b (ExceptionT m) where
    newtype StM (ExceptionT m) a = StE { unStE :: ComposeSt ExceptionT m a }
    liftBaseWith = defaultLiftBaseWith StE
    restoreM = defaultRestoreM unStE

-- | A 'Resource' which can throw exceptions. Note that this does not work in a
-- vanilla @ST@ monad. Instead, you should use the 'ExceptionT' transformer on
-- top of @ST@.
class Monad m => MonadThrow m where
    monadThrow :: E.Exception e => e -> m a

instance MonadThrow IO where
    monadThrow = E.throwIO

#define GO(T) instance (MonadThrow m) => MonadThrow (T m) where monadThrow = lift . monadThrow
#define GOX(X, T) instance (X, MonadThrow m) => MonadThrow (T m) where monadThrow = lift . monadThrow
GO(IdentityT)
GO(ListT)
GO(MaybeT)
GOX(Error e, ErrorT e)
GO(ReaderT r)
GO(StateT s)
GOX(Monoid w, WriterT w)
GOX(Monoid w, RWST r w s)
GOX(Monoid w, Strict.RWST r w s)
GO(Strict.StateT s)
GOX(Monoid w, Strict.WriterT w)
#undef GO
#undef GOX

-- | Introduce a reference-counting scheme to allow a resource context to be
-- shared by multiple threads. Once the last thread exits, all remaining
-- resources will be released.
--
-- Note that abuse of this function will greatly delay the deallocation of
-- registered resources. This function should be used with care. A general
-- guideline:
--
-- If you are allocating a resource that should be shared by multiple threads,
-- and will be held for a long time, you should allocate it at the beginning of
-- a new @ResourceT@ block and then call @resourceForkIO@ from there.
resourceForkIO :: MonadBaseControl IO m => ResourceT m () -> ResourceT m ThreadId
resourceForkIO (ResourceT f) = ResourceT $ \r -> L.mask $ \restore ->
    -- We need to make sure the counter is incremented before this call
    -- returns. Otherwise, the parent thread may call runResourceT before
    -- the child thread increments, and all resources will be freed
    -- before the child gets called.
    bracket_
        (stateAlloc r)
        (return ())
        (liftBaseDiscard forkIO $ bracket_
            (return ())
            (stateCleanup r)
            (restore $ f r))

-- | Determine if the current @ResourceT@ is still active. This is necessary
-- for such cases as lazy I\/O, where an unevaluated thunk may still refer to a
-- closed @ResourceT@.
resourceActive :: MonadIO m => ResourceT m Bool
resourceActive = ResourceT $ \rmMap -> do
    rm <- liftIO $ I.readIORef rmMap
    case rm of
        ReleaseMapClosed -> return False
        _ -> return True

-- | A 'Resource' based on some monad which allows running of some 'IO'
-- actions, via unsafe calls. This applies to 'IO' and 'ST', for instance.
class Monad m => MonadUnsafeIO m where
    unsafeLiftIO :: IO a -> m a

instance MonadUnsafeIO IO where
    unsafeLiftIO = id

instance MonadUnsafeIO (ST s) where
    unsafeLiftIO = unsafeIOToST

instance MonadUnsafeIO (Lazy.ST s) where
    unsafeLiftIO = Lazy.unsafeIOToST

instance (MonadTrans t, MonadUnsafeIO m, Monad (t m)) => MonadUnsafeIO (t m) where
    unsafeLiftIO = lift . unsafeLiftIO
