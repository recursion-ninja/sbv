-----------------------------------------------------------------------------
-- |
-- Module    : Data.SBV.Tools.GenTest
-- Copyright : (c) Levent Erkok
-- License   : BSD3
-- Maintainer: erkokl@gmail.com
-- Stability : experimental
--
-- Test generation from symbolic programs
-----------------------------------------------------------------------------

{-# OPTIONS_GHC -Wall -Werror -Wno-incomplete-uni-patterns #-}

module Data.SBV.Tools.GenTest (
        -- * Test case generation
        genTest, TestVectors, getTestValues, renderTest, TestStyle(..)
        ) where

import Control.Monad (unless)

import Data.Bits     (testBit)
import Data.Char     (isAlpha, toUpper)
import Data.Function (on)
import Data.List     (intercalate, groupBy)
import Data.Maybe    (fromMaybe)

import Data.SBV.Core.AlgReals
import Data.SBV.Core.Data

import Data.SBV.Utils.PrettyNum
import Data.SBV.Provers.Prover(defaultSMTCfg)

import qualified Data.Foldable as F (toList)

-- | Type of test vectors (abstract)
newtype TestVectors = TV [([CV], [CV])]

-- | Retrieve the test vectors for further processing. This function
-- is useful in cases where 'renderTest' is not sufficient and custom
-- output (or further preprocessing) is needed.
getTestValues :: TestVectors -> [([CV], [CV])]
getTestValues (TV vs) = vs

-- | Generate a set of concrete test values from a symbolic program. The output
-- can be rendered as test vectors in different languages as necessary. Use the
-- function 'output' call to indicate what fields should be in the test result.
-- (Also see 'constrain' for filtering acceptable test values.)
genTest :: Outputtable a => Int -> Symbolic a -> IO TestVectors
genTest n m = gen 0 []
  where gen i sofar
         | i == n = return $ TV $ reverse sofar
         | True   = do t <- tc
                       gen (i+1) (t:sofar)
        tc = do (_, Result {resTraces=tvals, resConsts=(_, cs), resDefinitions=definitions, resConstraints=cstrs, resOutputs=os}) <- runSymbolic defaultSMTCfg (Concrete Nothing) (m >>= output)
                let cval = fromMaybe (error "Cannot generate tests in the presence of uninterpeted constants!") . (`lookup` cs)
                    cond = and [cvToBool (cval v) | (False, _, v) <- F.toList cstrs] -- Only pick-up "hard" constraints, as indicated by False in the fist component
                unless (null definitions) $ error "Cannot generate tests in the presence of 'smtFunction' calls!"
                if cond
                   then return (map snd tvals, map cval os)
                   else tc   -- try again, with the same set of constraints

-- | Test output style
data TestStyle = Haskell String                     -- ^ As a Haskell value with given name
               | C       String                     -- ^ As a C array of structs with given name
               | Forte   String Bool ([Int], [Int]) -- ^ As a Forte/Verilog value with given name.
                                                    -- If the boolean is True then vectors are blasted big-endian, otherwise little-endian
                                                    -- The indices are the split points on bit-vectors for input and output values

-- | Render the test as a Haskell value with the given name @n@.
renderTest :: TestStyle -> TestVectors -> String
renderTest (Haskell n)    (TV vs) = haskell n vs
renderTest (C n)          (TV vs) = c       n vs
renderTest (Forte n b ss) (TV vs) = forte   n b ss vs

haskell :: String -> [([CV], [CV])] -> String
haskell vname vs = intercalate "\n" $ [ "-- Automatically generated by SBV. Do not edit!"
                                      , ""
                                      , "module " ++ modName ++ "(" ++ n ++ ") where"
                                      , ""
                                      ]
                                   ++ imports
                                   ++ [ n ++ " :: " ++ getType vs
                                      , n ++ " = [ " ++ intercalate ("\n" ++ pad ++  ", ") (map mkLine vs), pad ++ "]"
                                      ]
  where n = case vname of
              ""                    -> "testVectors"
              f:_ | not (isAlpha f) -> "tv" ++ vname
                  | True            -> vname

        imports
          | null vs               = []
          | needsInt && needsWord = ["import Data.Int", "import Data.Word", ""]
          | needsInt              = ["import Data.Int", ""]
          | needsWord             = ["import Data.Word", ""]
          | needsRatio            = ["import Data.Ratio"]
          | True                  = []
          where ((is, os):_) = vs
                params       = is ++ os
                needsInt     = any isSW params
                needsWord    = any isUW params
                needsRatio   = any isR params
                isR cv       = case kindOf cv of
                                 KReal -> True
                                 _     -> False
                isSW cv      = case kindOf cv of
                                 KBounded True _ -> True
                                 _               -> False
                isUW cv      = case kindOf cv of
                                 KBounded False sz -> sz > 1
                                 _                 -> False
        modName = let (f:r) = n in toUpper f : r
        pad = replicate (length n + 3) ' '
        getType []         = "[a]"
        getType ((i, o):_) = "[(" ++ mapType typeOf i ++ ", " ++ mapType typeOf o ++ ")]"
        mkLine  (i, o)     = "("  ++ mapType valOf  i ++ ", " ++ mapType valOf  o ++ ")"
        mapType f cvs = mkTuple $ map f $ groupBy ((==) `on` kindOf) cvs
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        typeOf []    = "()"
        typeOf [x]   = t x
        typeOf (x:_) = "[" ++ t x ++ "]"
        valOf  []    = "()"
        valOf  [x]   = s x
        valOf  xs    = "[" ++ intercalate ", " (map s xs) ++ "]"

        t cv = case kindOf cv of
                 KBool             -> "Bool"
                 KBounded False 8  -> "Word8"
                 KBounded False 16 -> "Word16"
                 KBounded False 32 -> "Word32"
                 KBounded False 64 -> "Word64"
                 KBounded True  8  -> "Int8"
                 KBounded True  16 -> "Int16"
                 KBounded True  32 -> "Int32"
                 KBounded True  64 -> "Int64"
                 KUnbounded        -> "Integer"
                 KFloat            -> "Float"
                 KDouble           -> "Double"
                 KChar             -> error "SBV.renderTest: Unsupported char"
                 KString           -> error "SBV.renderTest: Unsupported string"
                 KReal             -> error $ "SBV.renderTest: Unsupported real valued test value: " ++ show cv
                 KList es          -> error $ "SBV.renderTest: Unsupported list valued test: [" ++ show es ++ "]"
                 KSet  es          -> error $ "SBV.renderTest: Unsupported set valued test: {" ++ show es ++ "}"
                 KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                 _                 -> error $ "SBV.renderTest: Unexpected CV: " ++ show cv

        s cv = case kindOf cv of
                  KBool             -> take 5 (show (cvToBool cv) ++ repeat ' ')
                  KBounded sgn   sz -> let CInteger w = cvVal cv in shex  False True (sgn, sz) w
                  KUnbounded        -> let CInteger w = cvVal cv in shexI False True           w
                  KFloat            -> let CFloat   w = cvVal cv in showHFloat w
                  KDouble           -> let CDouble  w = cvVal cv in showHDouble w
                  KRational         -> error "SBV.renderTest: Unsupported rational number"
                  KFP{}             -> error "SBV.renderTest: Unsupported arbitrary float"
                  KChar             -> error "SBV.renderTest: Unsupported char"
                  KString           -> error "SBV.renderTest: Unsupported string"
                  KReal             -> let CAlgReal w = cvVal cv in algRealToHaskell w
                  KList es          -> error $ "SBV.renderTest: Unsupported list valued sort: [" ++ show es ++ "]"
                  KSet  es          -> error $ "SBV.renderTest: Unsupported set valued sort: {" ++ show es ++ "}"
                  KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                  k@KTuple{}        -> error $ "SBV.renderTest: Unsupported tuple: " ++ show k
                  k@KMaybe{}        -> error $ "SBV.renderTest: Unsupported maybe: " ++ show k
                  k@KEither{}       -> error $ "SBV.renderTest: Unsupported sum: " ++ show k

c :: String -> [([CV], [CV])] -> String
c n vs = intercalate "\n" $
              [ "/* Automatically generated by SBV. Do not edit! */"
              , ""
              , "#include <stdio.h>"
              , "#include <inttypes.h>"
              , "#include <stdint.h>"
              , "#include <stdbool.h>"
              , "#include <string.h>"
              , "#include <math.h>"
              , ""
              , "/* The boolean type */"
              , "typedef bool SBool;"
              , ""
              , "/* The float type */"
              , "typedef float SFloat;"
              , ""
              , "/* The double type */"
              , "typedef double SDouble;"
              , ""
              , "/* Unsigned bit-vectors */"
              , "typedef uint8_t  SWord8;"
              , "typedef uint16_t SWord16;"
              , "typedef uint32_t SWord32;"
              , "typedef uint64_t SWord64;"
              , ""
              , "/* Signed bit-vectors */"
              , "typedef int8_t  SInt8;"
              , "typedef int16_t SInt16;"
              , "typedef int32_t SInt32;"
              , "typedef int64_t SInt64;"
              , ""
              , "typedef struct {"
              , "  struct {"
              ]
           ++ (case vs of
                 []       -> []
                 (i, _):_ -> zipWith (mkField "i") i [(0::Int)..])
           ++ [ "  } input;"
              , "  struct {"
              ]
           ++ (case vs of
                 []       -> []
                 (_, o):_ -> zipWith (mkField "o") o [(0::Int)..])
           ++ [ "  } output;"
              , "} " ++ n ++ "TestVector;"
              , ""
              , n ++ "TestVector " ++ n ++ "[] = {"
              ]
           ++ ["      " ++ intercalate "\n    , " (map mkLine vs)]
           ++ [ "};"
              , ""
              , "int " ++ n ++ "Length = " ++ show (length vs) ++ ";"
              , ""
              , "/* Stub driver showing the test values, replace with code that uses the test vectors. */"
              , "int main(void)"
              , "{"
              , "  int i;"
              , "  for(i = 0; i < " ++ n ++ "Length; ++i)"
              , "  {"
              , "    " ++ outLine
              , "  }"
              , ""
              , "  return 0;"
              , "}"
              ]
  where mkField p cv i = "    " ++ t ++ " " ++ p ++ show i ++ ";"
            where t = case kindOf cv of
                        KBool             -> "SBool"
                        KBounded False 8  -> "SWord8"
                        KBounded False 16 -> "SWord16"
                        KBounded False 32 -> "SWord32"
                        KBounded False 64 -> "SWord64"
                        KBounded True  8  -> "SInt8"
                        KBounded True  16 -> "SInt16"
                        KBounded True  32 -> "SInt32"
                        KBounded True  64 -> "SInt64"
                        k@KBounded{}      -> error $ "SBV.renderTest: Unsupported kind: " ++ show k
                        KFloat            -> "SFloat"
                        KDouble           -> "SDouble"
                        KRational         -> error "SBV.renderTest: Unsupported rational number"
                        KFP{}             -> error "SBV.renderTest: Unsupported arbitrary float"
                        KChar             -> error "SBV.renderTest: Unsupported char"
                        KString           -> error "SBV.renderTest: Unsupported string"
                        KUnbounded        -> error "SBV.renderTest: Unbounded integers are not supported when generating C test-cases."
                        KReal             -> error "SBV.renderTest: Real values are not supported when generating C test-cases."
                        KUserSort us _    -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                        k@KList{}         -> error $ "SBV.renderTest: Unsupported list sort: "   ++ show k
                        k@KSet{}          -> error $ "SBV.renderTest: Unsupported set sort: "   ++ show k
                        k@KTuple{}        -> error $ "SBV.renderTest: Unsupported tuple sort: "  ++ show k
                        k@KMaybe{}        -> error $ "SBV.renderTest: Unsupported maybe sort: "  ++ show k
                        k@KEither{}       -> error $ "SBV.renderTest: Unsupported either sort: " ++ show k


        mkLine (is, os) = "{{" ++ intercalate ", " (map v is) ++ "}, {" ++ intercalate ", " (map v os) ++ "}}"

        v cv = case kindOf cv of
                  KBool            -> if cvToBool cv then "true " else "false"
                  KBounded sgn sz  -> let CInteger w = cvVal cv in chex  False True (sgn, sz) w
                  KUnbounded       -> let CInteger w = cvVal cv in shexI False True           w
                  KFloat           -> let CFloat w   = cvVal cv in showCFloat w
                  KDouble          -> let CDouble w  = cvVal cv in showCDouble w
                  KRational        -> error "SBV.renderTest: Unsupported rational number"
                  KFP{}            -> error "SBV.renderTest: Unsupported arbitrary float"
                  KChar            -> error "SBV.renderTest: Unsupported char"
                  KString          -> error "SBV.renderTest: Unsupported string"
                  k@KList{}        -> error $ "SBV.renderTest: Unsupported list sort!" ++ show k
                  k@KSet{}         -> error $ "SBV.renderTest: Unsupported set sort!" ++ show k
                  KUserSort us _   -> error $ "SBV.renderTest: Unsupported uninterpreted sort: " ++ us
                  KReal            -> error "SBV.renderTest: Real values are not supported when generating C test-cases."
                  k@KTuple{}       -> error $ "SBV.renderTest: Unsupported tuple sort!" ++ show k
                  k@KMaybe{}       -> error $ "SBV.renderTest: Unsupported maybe sort!" ++ show k
                  k@KEither{}      -> error $ "SBV.renderTest: Unsupported sum sort!" ++ show k

        outLine
          | null vs = "printf(\"\");"
          | True    = "printf(\"%*d. " ++ fmtString ++ "\\n\", " ++ show (length (show (length vs - 1))) ++ ", i"
                    ++ concatMap ("\n           , " ++ ) (zipWith inp is [(0::Int)..] ++ zipWith out os [(0::Int)..])
                    ++ ");"
          where (is, os) = case vs of
                             h:_ -> h
                             _   -> error "outLine: Impossible hapepned, empty vs!"

                inp cv i = mkBool cv (n ++ "[i].input.i"  ++ show i)
                out cv i = mkBool cv (n ++ "[i].output.o" ++ show i)
                mkBool cv s = case kindOf cv of
                                KBool -> "(" ++ s ++ " == true) ? \"true \" : \"false\""
                                _     -> s
                fmtString = unwords (map fmt is) ++ " -> " ++ unwords (map fmt os)

        fmt cv = case kindOf cv of
                    KBool             -> "%s"
                    KBounded False  8 -> "0x%02\"PRIx8\""
                    KBounded False 16 -> "0x%04\"PRIx16\"U"
                    KBounded False 32 -> "0x%08\"PRIx32\"UL"
                    KBounded False 64 -> "0x%016\"PRIx64\"ULL"
                    KBounded True   8 -> "%\"PRId8\""
                    KBounded True  16 -> "%\"PRId16\""
                    KBounded True  32 -> "%\"PRId32\"L"
                    KBounded True  64 -> "%\"PRId64\"LL"
                    KFloat            -> "%f"
                    KDouble           -> "%f"
                    KChar             -> error "SBV.renderTest: Unsupported char"
                    KString           -> error "SBV.renderTest: Unsupported string"
                    KUnbounded        -> error "SBV.renderTest: Unsupported unbounded integers for C generation."
                    KReal             -> error "SBV.renderTest: Unsupported real valued values for C generation."
                    _                 -> error $ "SBV.renderTest: Unexpected CV: " ++ show cv

forte :: String -> Bool -> ([Int], [Int]) -> [([CV], [CV])] -> String
forte vname bigEndian ss vs = intercalate "\n" $ [ "// Automatically generated by SBV. Do not edit!"
                                             , "let " ++ n ++ " ="
                                             , "   let c s = val [_, r] = str_split s \"'\" in " ++ blaster
                                             ]
                                          ++ [ "   in [ " ++ intercalate "\n      , " (map mkLine vs)
                                             , "      ];"
                                             ]
  where n = case vname of
              ""                    -> "testVectors"
              f:_ | not (isAlpha f) -> "tv" ++ vname
                  | True            -> vname

        blaster
         | bigEndian = "map (\\s. s == \"1\") (explode (string_tl r))"
         | True      = "rev (map (\\s. s == \"1\") (explode (string_tl r)))"

        toF True  = '1'
        toF False = '0'

        blast cv = let noForte w = error "SBV.renderTest: " ++ w ++ " values are not supported when generating Forte test-cases."
                   in case kindOf cv of
                        KBool             -> [toF (cvToBool cv)]
                        KBounded False 8  -> xlt  8 (cvVal cv)
                        KBounded False 16 -> xlt 16 (cvVal cv)
                        KBounded False 32 -> xlt 32 (cvVal cv)
                        KBounded False 64 -> xlt 64 (cvVal cv)
                        KBounded True 8   -> xlt  8 (cvVal cv)
                        KBounded True 16  -> xlt 16 (cvVal cv)
                        KBounded True 32  -> xlt 32 (cvVal cv)
                        KBounded True 64  -> xlt 64 (cvVal cv)
                        KFloat            -> noForte "Float"
                        KDouble           -> noForte "Double"
                        KChar             -> noForte "Char"
                        KString           -> noForte "String"
                        KReal             -> noForte "Real"
                        KList ek          -> noForte $ "List of " ++ show ek
                        KSet  ek          -> noForte $ "Set of " ++ show ek
                        KUnbounded        -> noForte "Unbounded integers"
                        KUserSort s _     -> noForte $ "Uninterpreted kind " ++ show s
                        _                 -> error $ "SBV.renderTest: Unexpected CV: " ++ show cv

        xlt s (CInteger  v)  = [toF (testBit v i) | i <- [s-1, s-2 .. 0]]
        xlt _ (CFloat    r)  = error $ "SBV.renderTest.Forte: Unexpected float value: "            ++ show r
        xlt _ (CDouble   r)  = error $ "SBV.renderTest.Forte: Unexpected double value: "           ++ show r
        xlt _ (CFP       r)  = error $ "SBV.renderTest.Forte: Unexpected arbitrary float value: "  ++ show r
        xlt _ (CRational r)  = error $ "SBV.renderTest.Forte: Unexpected rational  value: "        ++ show r
        xlt _ (CChar     r)  = error $ "SBV.renderTest.Forte: Unexpected char value: "             ++ show r
        xlt _ (CString   r)  = error $ "SBV.renderTest.Forte: Unexpected string value: "           ++ show r
        xlt _ (CAlgReal  r)  = error $ "SBV.renderTest.Forte: Unexpected real value: "             ++ show r
        xlt _ CList{}        = error   "SBV.renderTest.Forte: Unexpected list value!"
        xlt _ CSet{}         = error   "SBV.renderTest.Forte: Unexpected set value!"
        xlt _ CTuple{}       = error   "SBV.renderTest.Forte: Unexpected list value!"
        xlt _ CMaybe{}       = error   "SBV.renderTest.Forte: Unexpected maybe value!"
        xlt _ CEither{}      = error   "SBV.renderTest.Forte: Unexpected sum value!"
        xlt _ (CUserSort r)  = error $ "SBV.renderTest.Forte: Unexpected uninterpreted value: " ++ show r

        mkLine  (i, o) = "("  ++ mkTuple (form (fst ss) (concatMap blast i)) ++ ", " ++ mkTuple (form (snd ss) (concatMap blast o)) ++ ")"
        mkTuple []  = "()"
        mkTuple [x] = x
        mkTuple xs  = "(" ++ intercalate ", " xs ++ ")"
        form []     [] = []
        form []     bs = error $ "SBV.renderTest: Mismatched index in stream, extra " ++ show (length bs) ++ " bit(s) remain."
        form (i:is) bs
          | length bs < i = error $ "SBV.renderTest: Mismatched index in stream, was looking for " ++ show i ++ " bit(s), but only " ++ show bs ++ " remains."
          | i == 1        = let b:r = bs
                                v   = if b == '1' then "T" else "F"
                            in v : form is r
          | True          = let (f, r) = splitAt i bs
                                v      = "c \"" ++ show i ++ "'b" ++ f ++ "\""
                            in v : form is r
