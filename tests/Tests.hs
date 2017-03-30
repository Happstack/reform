{-# LANGUAGE TemplateHaskell #-}

module Main where

import           Control.Monad
-- import           Data.DeriveTH
import           Test.Hspec
import           Test.Hspec.QuickCheck           (prop)
import           Test.QuickCheck hiding (Result)
import           Test.QuickCheck.Checkers
import           Test.QuickCheck.Classes

import Text.Reform
import Text.Reform.Result
{-
$(derive makeArbitrary ''FormId)
$(derive makeArbitrary ''FormRange)
$(derive makeArbitrary ''Result)

instance (Eq e, Eq a) => EqProp (Result e a) where (=-=) = eq
-}
main :: IO ()
main = pure ()
{-
hspec $ do
  describe "Applicative/Monad instances" $ do
    it "Applicative and Monad should match behavior" $ do
      let result :: Result String (Int, String)
          result = Ok (1, "blah")
      quickBatch $ monadApplicative result
-}
