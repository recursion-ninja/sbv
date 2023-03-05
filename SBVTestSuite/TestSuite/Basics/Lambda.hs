-----------------------------------------------------------------------------
-- |
-- Module    : TestSuite.Basics.Lambda
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Test lambda generation
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# OPTIONS_GHC -Wall -Werror #-}

module TestSuite.Basics.Lambda(tests)  where

import Prelude hiding((++), map, foldl, foldr, sum, length, zip, zipWith, all, any)
import qualified Prelude as P

import Control.Monad (unless)

import Data.SBV.List
import Data.SBV.Control
import Data.SBV.Internals hiding(free_)

import Utils.SBVTestFramework

-- Test suite
tests :: TestTree
tests =
  testGroup "Basics.Lambda" [
      goldenCapturedIO "lambda1" $ record $ lambdaTop (2 :: SInteger)
    , goldenCapturedIO "lambda2" $ record $ lambdaTop (\x -> x+1 :: SInteger)
    , goldenCapturedIO "lambda3" $ record $ lambdaTop (\x y -> x+y*2 :: SInteger)
    , goldenCapturedIO "lambda4" $ check t1
    , goldenCapturedIO "lambda5" $ check t2
    , goldenCapturedIO "lambda6" $ check t3
    , goldenCapturedIO "lambda7" $ check t4
    , goldenCapturedIO "lambda8" $ t5
    , goldenCapturedIO "lambda9" $ t6
    ]
  where record :: IO String -> FilePath -> IO ()
        record gen rf = appendFile rf . (P.++ "\n") =<< gen

        check :: Symbolic () -> FilePath -> IO ()
        check t rf = do r <- satWith z3{verbose=True, redirectVerbose=Just rf} t
                        appendFile rf ("\nRESULT:\n" P.++ show r P.++ "\n")

        t1 = do let arg = [1, 2, 3 :: Integer]
                res <- free_
                constrain $ res .== map (const sFalse) arg

        t2 = do let arg = [1 .. 5 :: Integer]
                res <- free_
                constrain $ res .== (map (+1) . map (+2)) arg

        t3 = do let arg = [1 .. 5 :: Integer]
                res <- free_
                constrain $ res .== map f arg
          where f x = P.sum [x.^i | i <- [literal i | i <- [1..10 :: Integer]]]

        t4 = do let arg = [[1..5], [1..10], [1..20]] :: SList [Integer]
                res <- free_
                let sum = foldl (+) 0
                constrain $ res .== sum (map sum arg)

        t5 rf = runSMTWith z3{verbose=True, redirectVerbose=Just rf} $ do

                   let expecting = 5 :: Integer

                   a :: SList Integer <- sList_
                   b :: SList Integer <- sList_

                   query $ do

                     constrain $ length (zip a b) .== literal expecting
                     constrain $ length a .== literal expecting
                     constrain $ length b .== literal expecting
                     constrain $ all (.== 1) a
                     constrain $ all (.== 2) b

                     cs <- checkSat
                     case cs of
                       Sat -> do av <- getValue a
                                 bv <- getValue b
                                 let len = P.fromIntegral $ P.length (P.zip av bv)

                                 unless (len == expecting) $
                                    error $ unlines [ "Bad output:"
                                                    , "  a       = " P.++ show av
                                                    , "  b       = " P.++ show bv
                                                    , "  zip a b = " P.++ show (P.zip av bv)
                                                    , "  Length  = " P.++ show len P.++ " was expecting: " P.++ show expecting
                                                    ]

                       _ -> error $ "Unexpected output: " P.++ show cs

        t6 rf = runSMTWith z3{verbose=True, redirectVerbose=Just rf} $ do

                   a :: SList [Integer] <- sList_

                   sumVal <- sInteger_

                   query $ do

                     let expecting = 5

                     constrain $ a .== literal (replicate expecting (replicate expecting 1))
                     let sum = foldl (+) 0

                     constrain $ sumVal .== sum (map sum a)  -- Must be expecting * expecting

                     cs <- checkSat
                     case cs of
                       Sat -> do final <- getValue sumVal
                                 av    <- getValue a

                                 unless (final == fromIntegral (expecting * expecting)) $
                                    error $ unlines [ "Bad output:"
                                                    , "  a     = " P.++ show av
                                                    , "  Final = " P.++ show final P.++ " was expecting: " P.++ show (expecting*expecting)
                                                    ]

                       _ -> error $ "Unexpected output: " P.++ show cs

{-# ANN module ("HLint: ignore Use map once" :: String) #-}
{-# ANN module ("HLint: ignore Use sum"      :: String) #-}