{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TupleSections              #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableInstances       #-}

{-|

Evaluation proceeds pretty much like in the Soutei paper.  Computations are performed in the
'AvaleryarT m' monad, which is built up from the paper's backtracking monad and maintains the
runtime state ('RT').  The latter consists of the current variable substitution, an 'Epoch' counter
for a supply of guaranteed-fresh variables, and a database of predicates 'Db'.

To 'resolve' a 'Goal' (really just a 'BodyLit'), we load its associated assertion, look its 'Pred'
up, and execute the rule (or native predicate) to which it's bound.  Our "compiled" representation
of rules amounts to fuctions from 'Lit's (the head of a rule) to 'AvaleryarT' computations.

The database distinguishes between 'Rule's and "native predicates".  In the original implementation,
all mode-restricted predicates were baked into the @application@ assertion.  But we expect to have a
larger number of built-in predicates (for example, to parse JWTs, manipulate dates and times, or
consult a SQL database), so it seemed worthwhile to deviate from the paper to allow native
predicates to come from assertions other than @application@.  Because native predicates are likely
to be mode restricted (one wouldn't want to backtrack through a signature-checking routine,
attempting to enumerate new bitstrings until one just so happened to be a digest of your plaintext),
we need some means of identifying them at load-time to mode-check them before attempting to call
them.  To simplify all this, we require that native predicates (the only mode-restricted predicates
in the system) reside in "native assertions", which maintain enough information in their
'NativePred's to allow mode-checking for subsequent assertion submissions.

Currently, native assertions are distinguished lexically from normal rule assertions by prefixing
their name with a colon.  Thus, @:ldap says user-group(?user, ?group)@ refers to the native
predicate @user-group\/2@ within the native assertion named @ldap@.  Variables may not currently
denote native assertions, so there's no way to express something like:

@
  may(read) :-
    application says directory-service(?ds),
    application says user(?user),
    :?ds says valid-user(?user).
@

With the syntax suggesting that the application might have sent @directory-service(ldap)@ along with
its query.  The colon syntax was selected to be evocative of possibly someday in the future having
signatures for native assertions, so we might one day write:

@
  may(read) :-
    application says directory-service(?ds),
    application says user(?user),
    DS:?ds says valid-user(?user).
@

and ensure well-modedness from the signature @DS@ of all directory service assertions.

-}


module Language.Avaleryar.Semantics where

import           Control.Applicative
import           Control.Monad.Except
import           Control.Monad.Fail
import           Control.Monad.State
import           Data.Foldable
import           Data.Map             (Map)
import qualified Data.Map             as Map
import           Data.String
import           Data.Text            (Text, pack)
import           Data.Void            (vacuous)

import Control.Monad.FBackTrackT

import Language.Avaleryar.Syntax

-- | A native predicate carries not just its evaluation function, but also its signature, so it may
-- be consulted when new assertions are submitted in order to mode-check them.
data NativePred m = NativePred
  { nativePred :: Lit EVar -> AvaleryarT m ()
  , nativeSig  :: ModedLit
  }

-- | Regular 'Rule' assertions may be named by any 'Value'.
newtype RulesDb  m = RulesDb  { unRulesDb  :: Map Value (Map Pred (Lit EVar -> AvaleryarT m ())) }
  deriving (Semigroup, Monoid)

-- | Native predicates are lexically restricted, so 'NativeDb's are keyed on 'Text' rather than
-- 'Value'.
newtype NativeDb m = NativeDb { unNativeDb :: Map Text (Map Pred (NativePred m)) }
  deriving (Semigroup, Monoid)

-- TODO: newtype harder (newtype RuleAssertion c = ..., newtype NativeAssertion c = ...)
data Db m = Db
  { rulesDb  :: RulesDb  m
  , nativeDb :: NativeDb m
  }

instance Semigroup (Db m) where
  Db rdb ndb <> Db rdb' ndb' = Db (rdb <> rdb') (ndb <> ndb')

instance Monoid (Db m) where
  mempty = Db mempty mempty
  mappend = (<>)

-- | As 'Map.lookup', but fail into 'empty' instead of 'Nothing' when the key is missing.
alookup :: (Alternative f, Ord k) => k -> Map k a -> f a
alookup k m = maybe empty pure $ Map.lookup k m

-- | Look up a the 'Pred' in the assertion denoted by the given 'Value', and return the code to
-- execute it.
loadRule :: (Monad m) => Value -> Pred -> AvaleryarT m (Lit EVar -> AvaleryarT m ())
loadRule c p = gets (unRulesDb . rulesDb . db) >>= alookup c >>= alookup p

-- | As 'loadRule' for native predicates.
loadNative :: Monad m => Text -> Pred -> AvaleryarT m (Lit EVar -> AvaleryarT m ())
loadNative n p = gets (unNativeDb . nativeDb . db) >>= alookup n >>= alookup p >>= pure . nativePred

-- | Runtime state for 'AvaleryarT' computations.
data RT m = RT
  { env   :: Env   -- ^ The accumulated substitution
  , epoch :: Epoch -- ^ A counter for generating fresh variables
  , db    :: Db m  -- ^ The database of compiled predicates
  }

-- | A fair, backtracking, terminating, stateful monad transformer that does all the work.  This is
-- 'StateT' over 'Stream', so state changes are undone on backtracking.  This is important.
newtype AvaleryarT m a = AvaleryarT { unAvaleryarT :: StateT (RT m) (Stream m) a }
  deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadFail, MonadState (RT m), MonadYield, MonadIO)

-- | Run an 'AvaleryarT' computation.  The first argument is an upper limit on the number of
-- backtracking steps the computation may take before terminating, the second is an upper limit on
-- the number of values the computation may produce before terminating.  Both could be made optional
-- (unlimited depth, unlimited answers), but that doesn't seem like the point of what we're trying
-- to do here.
runAvalaryarT :: Monad m => Int -> Int -> Db m -> AvaleryarT m a -> m [a]
runAvalaryarT x y db = runM (Just x) (Just y)
                     . flip evalStateT (RT mempty 0 db)
                     . unAvaleryarT

-- | Try to find a binding for the given variable in the current substitution.
--
-- NB: The resulting 'Term' may still be a variable.
lookupEVar :: Monad m => EVar -> AvaleryarT m (Term EVar)
lookupEVar ev = do
  RT {..} <- get
  alookup ev env

-- | As 'lookupEVar', using the current value of the 'Epoch' counter in the runtime state.
lookupVar :: Monad m => TextVar -> AvaleryarT m (Term EVar)
lookupVar v = do
  ev <- (,) <$> gets epoch <*> pure v
  lookupEVar ev

-- | Unifies two terms, updating the substitution in the state.
unifyTerm :: (Monad m) => Term EVar -> Term EVar -> AvaleryarT m ()
unifyTerm t t' = do
  ts  <- subst t
  ts' <- subst t'
  unless (ts == ts') $ do
    rt@RT {..} <- get
    case (ts, ts') of
      (Var v, _) -> put rt {env = Map.insert v ts' env}
      (_, Var v) -> put rt {env = Map.insert v ts  env}
      _          -> empty -- ts /= ts', both are values

-- | Apply the current substitution on the given 'Term'.  This function does path compression: if it
-- finds a variable, it recurs.  This function does not fail: if there is no binding for the given
-- variable, it will give it right back.
subst :: Monad m => Term EVar -> AvaleryarT m (Term EVar)
subst v@(Val _)    = pure v
subst var@(Var ev) = gets env >>= maybe (pure var) subst . Map.lookup ev

type Goal = BodyLit EVar

-- | Analyze the given assertion reference and look up the given predicate to find some code to
-- execute.
loadResolver :: (Monad m) => ARef EVar -> Pred -> AvaleryarT m (Lit EVar -> AvaleryarT m ())
loadResolver (ARNative n) p = loadNative n p
loadResolver (ARTerm   t) p = do
  Val c <- subst t -- mode checking should assure that assertion references are ground by now
  loadRule c p

-- | Load the appropriate assertion, and execute the predicate in the goal.  Eagerly substitutes,
-- which I think might be inefficient, but I also think was tricky to not-do here way back when I
-- wrote this.
resolve :: (Monad m) => Goal -> AvaleryarT m (Lit EVar)
resolve (assn `Says` l@(Lit p as)) = do
  resolver <- yield' $ loadResolver assn p
  resolver l
  Lit p <$> traverse subst as


-- | A slightly safer version of @'zipWithM_' 'unifyTerm'@ that ensures its argument lists are the
-- same length.
unifyArgs :: Monad m => [Term EVar] -> [Term EVar] -> AvaleryarT m ()
unifyArgs [] []         = pure ()
unifyArgs (x:xs) (y:ys) = unifyTerm x y >> unifyArgs xs ys
unifyArgs _ _           = empty

-- | NB: 'compilePred' doesn't look at the 'Pred' for any of the given rules, it assumes it was
-- given a query that applies, and that the rules it was handed are all for the same predicate.
-- This is not the function you want.  FIXME: Suck less
compilePred :: (Monad m) => [Rule TextVar] -> Lit EVar -> AvaleryarT m ()
compilePred rules (Lit _ qas) = do
  rt@RT {..} <- get
  put rt {epoch = succ epoch}
  let rules' = fmap (epoch,) <$> rules
      go (Rule (Lit _ has) body) = do
        unifyArgs has qas
        traverse_ resolve body
  msum $ go <$> rules'

-- | Turn a list of 'Rule's into a map from their names to code that executes them.
compileRules :: (Monad m) => [Rule TextVar] -> Map Pred (Lit EVar -> AvaleryarT m ())
compileRules rules = fmap compilePred $ Map.fromListWith (++) [(p, [r]) | r@(Rule (Lit p _) _) <- rules]

compileQuery :: (Monad m) => String -> Text -> [Term TextVar] -> AvaleryarT m (Lit EVar)
compileQuery assn p args = resolve $ assn' `Says` (Lit (Pred p (length args)) (fmap (fmap (-1,)) args))
  where assn' = case assn of
                  (':':_) -> ARNative (pack assn)
                  _       -> ARTerm . Val $ fromString assn

-- | TODO: Suck less
compileQuery' :: Monad m => String -> Query -> AvaleryarT m (Lit EVar)
compileQuery' assn (Lit (Pred p _) args) = compileQuery assn p args

insertRuleAssertion :: Text -> Map Pred (Lit EVar -> AvaleryarT m ()) -> RulesDb m -> RulesDb m
insertRuleAssertion assn rules = RulesDb . Map.insert (T assn) rules . unRulesDb

retractRuleAssertion :: Text -> RulesDb m -> RulesDb m
retractRuleAssertion assn = RulesDb . Map.delete (T assn) . unRulesDb

---------------------

inMode :: Mode TextVar
inMode = In "+"

outMode :: Mode TextVar
outMode = Out "-"

-- | Typeclass machinery for easing the creation of native predicates.  The idea is to do our best
-- to translate regular Haskell functions into predicates callable from soutei code without needing
-- to concern ourselves with the intricacies of the evaluator.
class ToNative a where
  -- | Think of 'toNative' as describing how to unify the /result/ of a function with the complete
  -- list of 'Term's given.  Usually, the list will only have one value in it, but it can have more
  -- or fewer in the case of e.g., tuples.  Implementations /must/ ground-out every variable in the
  -- list, or the mode-checker will become unsound.
  toNative :: MonadIO m => a -> [Term EVar] -> AvaleryarT m ()

  -- | Probably this should be 'outMode' for each argument expected in the list of 'Term's in
  -- 'toNative'.
  inferMode :: [Mode TextVar]

instance ToNative Value where
  toNative v args = unifyArgs [val v] args
  inferMode = [outMode]

-- TODO: Figure out if there's a reason I didn't do:
--
-- instance Valuable a => ToNative a where
--   toNative v args = toNative (toValue a) args
--   inferMode = [outMode]

instance ToNative () where
  toNative () [] = pure ()
  toNative () _  = empty
  inferMode     = []

-- TODO: This is either slick or extremely hokey, figure out which.
instance ToNative Bool where
  toNative b [] = guard b
  toNative _ _  = empty
  inferMode     = []

-- TODO: This is also either slick or extremely hokey, figure out which.
instance ToNative a => ToNative [a] where
  toNative as xs = msum [toNative a xs | a <- as]
  inferMode      = inferMode @a

instance ToNative a => ToNative (Maybe a) where
  toNative ma xs = toNative (toList ma) xs
  inferMode      = inferMode @[a]

-- | Pretty much just a 1-tuple, like @Only@ from @postgresql-simple@.
newtype Solely a = Solely a

instance Valuable a => ToNative (Solely a) where
  toNative (Solely a) args = unifyArgs [val a] args
  inferMode = [outMode]

instance (Valuable a, Valuable b) => ToNative (a, b) where
  toNative (a, b) args = unifyArgs [val a, val b] args
  inferMode = [outMode, outMode]

instance (Valuable a, Valuable b, Valuable c) => ToNative (a, b, c) where
  toNative (a, b, c) args = unifyArgs [val a, val b, val c] args
  inferMode = [outMode, outMode, outMode]

instance (Valuable a, Valuable b, Valuable c, Valuable d) => ToNative (a, b, c, d) where
  toNative (a, b, c, d) args = unifyArgs [val a, val b, val c, val d] args
  inferMode = [outMode, outMode, outMode, outMode]

instance (Valuable a, Valuable b, Valuable c, Valuable d, Valuable e) => ToNative (a, b, c, d, e) where
  toNative (a, b, c, d, e) args = unifyArgs [val a, val b, val c, val d, val e] args
  inferMode = [outMode, outMode, outMode, outMode, outMode]

instance (Valuable a, Valuable b, Valuable c, Valuable d, Valuable e, Valuable f) => ToNative (a, b, c, d, e, f) where
  toNative (a, b, c, d, e, f) args = unifyArgs [val a, val b, val c, val d, val e, val f] args
  inferMode = [outMode, outMode, outMode, outMode, outMode, outMode]

-- | This is where the magic happens.  We require 'Valuable' (rather than 'ToNative') of the input
-- so we can use 'fromValue' to pull the value back from Soutei into Haskell.  We assign 'inMode'
-- here to ensure that we actually get a value from the substitution so that 'fromValue' might
-- conceivably work.
instance (Valuable a, ToNative b) => ToNative (a -> b) where
  toNative f (x:xs) = do
    Val x' <- subst x -- mode checking should make this safe (because of the 'inMode' below)
    case fromValue x' of
      Just a  -> toNative (f a) xs
      Nothing -> empty
  toNative _ _      = empty
  inferMode = inMode : inferMode @b

-- | Executes the IO action and produces the result.
--
-- TODO: This should possibly cache the result, but only once per query, probably.  That would
-- likely require infrastructure we lack at present.
instance ToNative a => ToNative (IO a) where
  toNative ma xs = do
    a <- liftIO ma
    toNative a xs

  inferMode = inferMode @a

-- | Create a native predicate from a 'ToNative' instance with the given name.
mkNativePred :: forall a m. (ToNative a, MonadIO m) => Text -> a -> NativePred m
mkNativePred pn f = NativePred np moded
  where np (Lit _ args) = toNative f args
        modes = inferMode @a
        moded = Lit (Pred pn $ length modes) (Var <$> modes)

-- TODO: Feels like I should be able to do this less manually, maybe?
mkNativeFact :: (Factual a, MonadIO m) => a -> NativePred m
mkNativeFact a = NativePred np $ fmap Out f
  where f@(Lit _ args)   = vacuous $ toFact a
        np (Lit _ args') = unifyArgs args args'

-- | Create a native database with the given assertion name from the given list of native
-- predicates.
mkNativeDb :: Monad m => Text -> [NativePred m] -> NativeDb m
mkNativeDb assn preds = NativeDb . Map.singleton assn $ Map.fromList [(p, np) | np@(NativePred _ (Lit p _)) <- preds]
