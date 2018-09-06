-----------------------------------------------------------------------------
-- |
-- Module      :  Documentation.SBV.Examples.Lists.Nested
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Demonstrates nested lists
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Documentation.SBV.Examples.Lists.Nested where

import Data.SBV
import Data.SBV.Control

import Data.SBV.List ((.!!))
import qualified Data.SBV.List as L

-- | Simple example demonstrating the use of nested lists. We have:
--
-- >>> nestedExample
-- [[1,2,3],[4,5,6,7]]
nestedExample :: IO ()
nestedExample = runSMT $ do a :: SList [Integer] <- free "a"

                            constrain $ a .!! 0 .== [1, 2, 3]
                            constrain $ a .!! 1 .== [4, 5, 6, 7]
                            constrain $ L.length a .== 2

                            query $ do cs <- checkSat
                                       case cs of
                                         Unk   -> error "Solver said unknown!"
                                         Unsat -> io $ putStrLn "Unsat"
                                         Sat   -> do v <- getValue a
                                                     io $ print v
