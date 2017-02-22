{-# LANGUAGE FlexibleInstances, GeneralizedNewtypeDeriving #-}
{- |
This module defines the 'Form' type, its instances, core manipulation functions, and a bunch of helper utilities.
-}
module Text.Reform.Core where

import Control.Applicative         (Applicative(pure, (<*>)))
import Control.Arrow               (first, second)
import Control.Monad.Reader        (MonadReader(ask), ReaderT, runReaderT)
import Control.Monad.State         (MonadState(get,put), StateT, evalStateT)
import Control.Monad.Trans         (lift)
import Data.Biapplicative          (Biapplicative(bipure, (<<*>>)), Bifunctor(bimap))
import Data.Monoid                 (Monoid(mempty, mappend))
import Data.Text.Lazy              (Text, unpack)
import Text.Reform.Result          (FormId(..), FormRange(..), Result(..), unitRange, zeroId)

------------------------------------------------------------------------------
-- * Proved
------------------------------------------------------------------------------

-- | Proved records a value, the location that value came from, and something that was proved about the value.
data Proved proofs a =
    Proved { proofs   :: proofs
           , pos      :: FormRange
           , unProved :: a
           }
    deriving Show

instance Functor (Proved ()) where
    fmap f (Proved () pos a) = Proved () pos (f a)

-- | Utility Function: trivially prove nothing about ()
unitProved :: FormId -> Proved () ()
unitProved formId =
    Proved { proofs   = ()
           , pos      = unitRange formId
           , unProved = ()
           }

------------------------------------------------------------------------------
-- * FormState
------------------------------------------------------------------------------

-- | inner state used by 'Form'.
type FormState m input = ReaderT (Environment m input) (StateT FormRange m)

-- | used to represent whether a value was found in the form
-- submission data, missing from the form submission data, or expected
-- that the default value should be used
data Value a
    = Default
    | Missing
    | Found a

-- | Utility function: Get the current input
--
getFormInput :: Monad m => FormState m input (Value input)
getFormInput = getFormId >>= getFormInput'

-- | Utility function: Gets the input of an arbitrary 'FormId'.
--
getFormInput' :: Monad m => FormId -> FormState m input (Value input)
getFormInput' id' = do
    env <- ask
    case env of
      NoEnvironment -> return Default
      Environment f ->
          lift $ lift $ f id'

-- | Utility function: Get the current range
--
getFormRange :: Monad m => FormState m i FormRange
getFormRange = get

-- | The environment is where you get the actual input per form.
--
-- The 'NoEnvironment' constructor is typically used when generating a
-- view for a GET request, where no data has yet been submitted. This
-- will cause the input elements to use their supplied default values.
--
-- Note that 'NoEnviroment' is different than supplying an empty environment.
data Environment m input
    = Environment (FormId -> m (Value input))
    | NoEnvironment

-- | Not quite sure when this is useful and so hard to say if the rules for combining things with Missing/Default are correct
instance (Monoid input, Monad m) => Monoid (Environment m input) where
    mempty = NoEnvironment
    NoEnvironment `mappend` x = x
    x `mappend` NoEnvironment = x
    (Environment env1) `mappend` (Environment env2) =
        Environment $ \id' ->
            do r1 <- (env1 id')
               r2 <- (env2 id')
               case (r1, r2) of
                 (Missing, Missing) -> return Missing
                 (Default, Missing) -> return Default
                 (Missing, Default) -> return Default
                 (Found x, Found y) -> return $ Found (x `mappend` y)
                 (Found x, _      ) -> return $ Found x
                 (_      , Found y) -> return $ Found y

-- | Utility function: returns the current 'FormId'. This will only make sense
-- if the form is not composed
--
getFormId :: Monad m => FormState m i FormId
getFormId = do
    FormRange x _ <- get
    return x

-- | Utility function: increment the current 'FormId'.
incFormId :: Monad m => FormState m i ()
incFormId = do
        FormRange _ endF1 <- get
        put $ unitRange endF1

-- | A view represents a visual representation of a form. It is composed of a
-- function which takes a list of all errors and then produces a new view
--
newtype View error v = View
    { unView :: [(FormRange, error)] -> v
    } deriving (Monoid)

instance Functor (View e) where
    fmap f (View g) = View $ f . g

------------------------------------------------------------------------------
-- * Form
------------------------------------------------------------------------------

-- | a 'Form' contains a 'View' combined with a validation function
-- which will attempt to extract a value from submitted form data.
--
-- It is highly parameterized, allowing it work in a wide variety of
-- different configurations. You will likely want to make a type alias
-- that is specific to your application to make type signatures more
-- manageable.
--
--   [@m@] A monad which can be used by the validator
--
--   [@input@] A framework specific type for representing the raw key/value pairs from the form data
--
--   [@error@] A application specific type for error messages
--
--   [@view@] The type of data being generated for the view (HSP, Blaze Html, Heist, etc)
--
--   [@proof@] A type which names what has been proved about the return value. @()@ means nothing has been proved.
--
--   [@a@] Value return by form when it is successfully decoded, validated, etc.
--
--
-- This type is very similar to the 'Form' type from
-- @digestive-functors <= 0.2@. If @proof@ is @()@, then 'Form' is an
-- applicative functor and can be used almost exactly like
-- @digestive-functors <= 0.2@.
newtype Form m input error view proof a = Form { unForm :: FormState m input (View error view, m (Result error (Proved proof a))) }

instance (Monad m) => Bifunctor (Form m input view error) where
    bimap f g (Form frm) =
        Form $ do (view, mval) <- frm
                  val <- lift $ lift $ mval
                  case val of
                    (Ok (Proved p pos a)) -> return (view, return $ Ok (Proved (f p) pos (g a)))
                    (Error errs)          -> return (view, return $ Error errs)

instance (Monoid view, Monad m) => Biapplicative (Form m input error view) where
    bipure p a = Form $ do i <- getFormId
                           return (mempty, return $ Ok (Proved p (unitRange i) a))

    (Form frmF) <<*>> (Form frmA) =
        Form $ do ((view1, mfok), (view2, maok)) <- bracketState $
                    do res1 <- frmF
                       incFormId
                       res2 <- frmA
                       return (res1, res2)
                  fok <- lift $ lift $ mfok
                  aok <- lift $ lift $ maok
                  case (fok, aok) of
                     (Error errs1, Error errs2) -> return (view1 `mappend` view2, return $ Error $ errs1 ++ errs2)
                     (Error errs1, _)           -> return (view1 `mappend` view2, return $ Error $ errs1)
                     (_          , Error errs2) -> return (view1 `mappend` view2, return $ Error $ errs2)
                     (Ok (Proved p (FormRange x _) f), Ok (Proved q (FormRange _ y) a)) ->
                         return (view1 `mappend` view2, return $ Ok $ Proved { proofs   = p q
                                                                           , pos      = FormRange x y
                                                                           , unProved = f a
                                                                           })

bracketState :: Monad m => FormState m input a -> FormState m input a
bracketState k = do
    FormRange startF1 _ <- get
    res <- k
    FormRange _ endF2 <- get
    put $ FormRange startF1 endF2
    return res


instance (Functor m) => Functor (Form m input error view ()) where
    fmap f form =
        Form $ fmap (second (fmap (fmap (fmap f)))) (unForm form)


instance (Functor m, Monoid view, Monad m) => Applicative (Form m input error view ()) where
    pure a =
      Form $
        do i <- getFormId
           return (View $ const $ mempty, return $ Ok $ Proved { proofs    = ()
                                                               , pos       = FormRange i i
                                                               , unProved  = a
                                                               })
    -- this coud be defined in terms of <<*>> if we just changed the proof of frmF to (() -> ())
    (Form frmF) <*> (Form frmA) =
       Form $
         do ((view1, mfok), (view2, maok)) <- bracketState $
              do res1 <- frmF
                 incFormId
                 res2 <- frmA
                 return (res1, res2)
            fok <- lift $ lift $ mfok
            aok <- lift $ lift $ maok
            case (fok, aok) of
              (Error errs1, Error errs2) -> return (view1 `mappend` view2, return $ Error $ errs1 ++ errs2)
              (Error errs1, _)           -> return (view1 `mappend` view2, return $ Error $ errs1)
              (_          , Error errs2) -> return (view1 `mappend` view2, return $ Error $ errs2)
              (Ok (Proved p (FormRange x _) f), Ok (Proved q (FormRange _ y) a)) ->
                  return (view1 `mappend` view2, return $ Ok $ Proved { proofs   = ()
                                                                      , pos      = FormRange x y
                                                                      , unProved = f a
                                                                      })

-- ** Ways to evaluate a Form

-- | Run a form
--
runForm :: (Monad m) =>
           Environment m input
        -> Text
        -> Form m input error view proof a
        -> m (View error view, m (Result error (Proved proof a)))
runForm env prefix' form =
    evalStateT (runReaderT (unForm form) env) (unitRange (zeroId $ unpack prefix'))

-- | Run a form
--
runForm' :: (Monad m) =>
            Environment m input
         -> Text
        -> Form m input error view proof a
        -> m (view , Maybe a)
runForm' env prefix form =
    do (view', mresult) <- runForm env prefix form
       result <- mresult
       return $ case result of
                  Error e  -> (unView view' e , Nothing)
                  Ok x     -> (unView view' [], Just (unProved x))

-- | Just evaluate the form to a view. This usually maps to a GET request in the
-- browser.
--
viewForm :: (Monad m) =>
            Text                          -- ^ form prefix
         -> Form m input error view proof a -- ^ form to view
         -> m view
viewForm prefix form =
    do (v, _) <- runForm NoEnvironment prefix form
       return (unView v [])

-- | Evaluate a form
--
-- Returns:
--
-- [@Left view@] on failure. The @view@ will have already been applied to the errors.
--
-- [@Right a@] on success.
--
eitherForm :: (Monad m) =>
              Environment m input             -- ^ Input environment
           -> Text                          -- ^ Identifier for the form
           -> Form m input error view proof a -- ^ Form to run
           -> m (Either view a)               -- ^ Result
eitherForm env id' form = do
    (view', mresult) <- runForm env id' form
    result <- mresult
    return $ case result of
        Error e  -> Left $ unView view' e
        Ok x     -> Right (unProved x)

-- | create a 'Form' from some @view@.
--
-- This is typically used to turn markup like @\<br\>@ into a 'Form'.
view :: (Monad m) =>
        view                           -- ^ View to insert
     -> Form m input error view () ()  -- ^ Resulting form
view view' =
  Form $
    do i <- getFormId
       return ( View (const view')
              , return (Ok (Proved { proofs   = ()
                                   , pos      = FormRange i i
                                   , unProved = ()
                                   })))

-- | Append a unit form to the left. This is useful for adding labels or error
-- fields.
--
-- The 'Forms' on the left and right hand side will share the same
-- 'FormId'. This is useful for elements like @\<label
-- for=\"someid\"\>@, which need to refer to the id of another
-- element.
(++>) :: (Monad m, Monoid view)
      => Form m input error view () ()
      -> Form m input error view proof a
      -> Form m input error view proof a
f1 ++> f2 = Form $ do
    -- Evaluate the form that matters first, so we have a correct range set
    (v2, r) <- unForm f2
    (v1, _) <- unForm f1
    return (v1 `mappend` v2, r)

infixl 6 ++>

-- | Append a unit form to the right. See '++>'.
--
(<++) :: (Monad m, Monoid view)
      => Form m input error view proof a
      -> Form m input error view () ()
      -> Form m input error view proof a
f1 <++ f2 = Form $ do
    -- Evaluate the form that matters first, so we have a correct range set
    (v1, r) <- unForm f1
    (v2, _) <- unForm f2
    return (v1 `mappend` v2, r)

infixr 5 <++

-- | Change the view of a form using a simple function
--
-- This is useful for wrapping a form inside of a \<fieldset\> or other markup element.
mapView :: (Monad m, Functor m)
        => (view -> view')        -- ^ Manipulator
        -> Form m input error view  proof a  -- ^ Initial form
        -> Form m input error view' proof a  -- ^ Resulting form
mapView f = Form . fmap (first $ fmap f) . unForm

-- | Utility Function: turn a view and return value into a successful 'FormState'
mkOk :: (Monad m) =>
         FormId
      -> view
      -> a
      -> FormState m input (View error view, m (Result error (Proved () a)))
mkOk i view val =
    return ( View $ const $ view
           , return $ Ok (Proved { proofs   = ()
                                 , pos      = unitRange i
                                 , unProved = val
                                 })
           )
