{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MonadComprehensions, ParallelListComp #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ViewPatterns #-}

{-| transpiler to SVG visualization of the AnyAll and/or trees.

Largely a wrapper. Most of the functionality is in the anyall lib.

-}

module LS.XPile.Purescript where

import qualified AnyAll as AA
import AnyAll.BoolStruct (alwaysLabeled)
import Control.Applicative (liftA2)
import Control.Monad (guard, join, liftM, unless, when)
import Data.Bifunctor (second)
import qualified Data.Char as Char
import Data.Either (lefts, rights)
import Data.HashMap.Strict ((!))
import qualified Data.HashMap.Strict as Map
import Data.List (sortOn)
import qualified Data.List as DL
import Data.List.Split (chunk)
import Data.Maybe (listToMaybe)
import qualified Data.Ord
import Data.String.Interpolate (i, __i)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Flow ((|>))
import LS
import LS.Interpreter
import LS.NLP.NL4Transformations
import LS.NLP.NLG
import LS.Utils ((|$>))
import LS.XPile.Logging
import PGF
import Prettyprinter
import Prettyprinter.Interpolate (__di)
import Text.Pretty.Simple (pShowNoColor)

-- | extract the tree-structured rules from Interpreter
-- currently: construct a Data.Map of rulenames to exposed decision root expanded BSR
-- in future: also ship out a Marking which represents the TYPICALLY values
-- far future: construct a JSON with everything in it, and get the Purescript to read the JSON, so we are more interoperable with non-FP languages

data Tuple a b = Tuple a b
  deriving (Show, Eq, Ord)

toTuple :: (a,b) -> Tuple a b
toTuple (x,y) = Tuple x y

textMT :: [RuleName] -> [T.Text]
textMT = map mt2text

-- two boolstructT: one question and one phrase
namesAndStruct :: [Rule] -> XPileLog [([RuleName], [BoolStructT])]
namesAndStruct rl = do
  mutter $ "*** namesAndStruct: running on " ++ show (length rl) ++ " rules"
  mutter "calling qaHornsT against l4i"
  pure [ (names, [bs]) | (names, bs) <- qaHornsT interp]
  where
    interp = l4interpret defaultInterpreterOptions rl

-- | for each rule, construct the questions for that rule;
-- and then jam them together with all the names for all the rules???
namesAndQ :: NLGEnv -> [Rule] -> XPileLog [([RuleName], [BoolStructT])]
namesAndQ env rl = do
  mutter $ "*** namesAndQ: name = " ++ show name
  questStruct <- traverse (ruleQuestions env alias) (expandRulesForNLG env rl)
  let wut = concat [ [ (name, q)
                     | q' <- q ]
                   | q <- questStruct ]
  mutter $ "*** wut the heck are we returning?"
  mutters ["- " ++ show w | w <- wut]
  return wut
  where
    name = map ruleLabelName rl
    alias = listToMaybe [ (you,org) | DefNameAlias you org _ _ <- rl]
    -- [AA.OptionallyLabeledBoolStruct Text.Text]

combine :: [([RuleName], [BoolStructT])]
        -> [([RuleName], [BoolStructT])]
        -> XPileLog [([RuleName], [BoolStructT])]
combine [] [] = pure []
combine (b:bs) [] = pure []
combine [] (q:qs) = pure []
combine (b:bs) (q:qs) =
  (:) <$> pure ((fst b), (snd b) ++ (snd q)) <*> combine bs qs


-- [TODO] shouldn't this recurse down into the All and Any structures?
-- something like fixNot AA.Any k xs = AA.Any k (fixNot <$> xs)
fixNot :: BoolStructT -> BoolStructT
fixNot (AA.Leaf x) = AA.Leaf x
fixNot (AA.Not (AA.Leaf x)) = AA.Leaf x
fixNot y = y

-- | this throws away the first argument, in favour of the second. Not sure about this ...
justQuestions :: BoolStructT -> [BoolStructT] -> BoolStructT
justQuestions (AA.All Nothing a) q = AA.All Nothing q
justQuestions (AA.Any Nothing a) q = AA.Any Nothing q
justQuestions xs y = xs

justStatements :: BoolStructT -> [BoolStructT] -> BoolStructT
justStatements (AA.All Nothing a) q = AA.All Nothing a
justStatements (AA.Any Nothing a) q = AA.Any Nothing a
justStatements xs y = xs

labelQs :: [AA.OptionallyLabeledBoolStruct T.Text] -> [AA.BoolStruct (AA.Label T.Text) T.Text]
labelQs = map alwaysLabeled

biggestQ :: NLGEnv -> [Rule] -> XPileLog [BoolStructT]
biggestQ env rl = do
  mutter $ "*** biggestQ: running"
  q <- join $ combine <$> namesAndStruct rl <*> namesAndQ env rl
  let flattened = (\(x,ys) ->
        (x, [ AA.extractLeaves y | y <- ys])) <$> q

      onlyqs = [ (x, justQuestions yh (map fixNot yt))
               | (x, y) <- q
               , Just (yh, yt) <- [DL.uncons y] ]

      sorted = sortOn (Data.Ord.Down . DL.length) flattened
  if not (null sorted)
    then case fst (DL.head sorted) `Map.lookup` Map.fromList onlyqs of
           Nothing -> mutter ("biggestQ didn't work, couldn't find " ++ show (fst (DL.head sorted)) ++ " in dict") >> return []
           Just x  -> return [x]
    else return []

biggestS :: NLGEnv -> [Rule] -> XPileLog [BoolStructT]
biggestS env rl = do
  mutter $ "*** biggestS running"
  q <- join $ combine <$> namesAndStruct rl <*> namesAndQ env rl
  let flattened = (\(x,ys) ->
        (x, [ AA.extractLeaves y | y <- ys])) <$> q
      onlys = [ (x, justStatements yh (map fixNot yt))
              | (x,y) <- q
              , Just (yh, yt) <- [DL.uncons y] ]
      sorted = sortOn (Data.Ord.Down . DL.length) flattened
  return $
    if not (null sorted)
    then pure $ Map.fromList onlys ! fst (DL.head sorted)
    else []

asPurescript :: NLGEnv -> [Rule] -> XPileLogE String
asPurescript env rl = do
  let nlgEnvStr = env |> gfLang |> showLanguage
  -- [TODO] why don't we stick l4i in the env instead of recalculating it each time?
  let l4i = l4interpret defaultInterpreterOptions rl
  mutter [i|** asPurescript running for gfLang=#{nlgEnvStr}|]

  c' <- join $ combine <$> namesAndStruct rl <*> namesAndQ env rl
  mutter $ "*** c'\n" ++ show c'

  guts <- sequence [
    do
      mutter $ "*** names: " ++ show ( mt2text <$> names )
      mutter $ "**** hbs = head boolstruct\n" ++ show hbs
      mutter $ "**** tbs = tail boolstruct\n" ++ show tbs
      mutter $ "**** fixedNot\n" ++ show fixedNot
      mutter $ "**** jq\n" ++ show jq
      mutter $ "**** labeled\n" ++ show labeled
      xpReturn $ toTuple ( T.intercalate " / " (mt2text <$> names) , labeled)

    | (names,bs) <- c'
    , Just (hbs, tbs) <- [DL.uncons bs]
    , let fixedNot = map fixNot tbs
          jq       = justQuestions hbs fixedNot
          labeled  = alwaysLabeled jq
    ]
  let nlgEnvStrLower = Char.toLower <$> nlgEnvStr
      listOfMarkings = Map.toList . AA.getMarking $ getMarkings l4i

  mutter "*** Markings"
  mutters [ "**** " ++ T.unpack (fst m) ++ "\n" ++ show (snd m) | m <- listOfMarkings]

  xpReturn $ show
    [__di|
      #{nlgEnvStrLower} :: Object.Object (Item String)
      #{nlgEnvStrLower} = Object.fromFoldable
        #{pShowNoColor guts}
      #{nlgEnvStrLower}Marking :: Marking
      #{nlgEnvStrLower}Marking = Marking $ Map.fromFoldable
        #{TL.replace "False" "false"
          . TL.replace "True" "true"
          . pShowNoColor $
              fmap toTuple listOfMarkings}
    |]
          -- #{pretty $ showLanguage $ gfLang env}Statements :: Object.Object (Item String)
          -- , (pretty $ showLanguage $ gfLang env) <> "Statements = Object.fromFoldable " <>
          --   (pretty $ TL.unpack (
          --       pShowNoColor
          --         [ toTuple ( T.intercalate " / " (mt2text <$> names)
          --                 , alwaysLabeled (justStatements (head bs) (map fixNot (tail bs))))
          --         | (names,bs) <- (combine (namesAndStruct env rl) (namesAndQ env rl))
          --         ]
          --       )
          --   )

translate2PS :: [NLGEnv] -> NLGEnv -> [Rule] -> XPileLogE String
translate2PS nlgEnv eng rules = do
  mutter $ "** translate2PS: running against " ++ show (length rules) ++ " rules"
  mutter $ "*** nlgEnv has " ++ show (length nlgEnv) ++ " elements"
  mutter $ "*** eng.gfLang = " ++ show (gfLang eng)
  mutter $ "** calling biggestQ"
  bigQ <- biggestQ eng rules
  mutter $ "** got back bigQ"
  mutter $ show bigQ
  let topBit =
        bigQ
          |$> alwaysLabeled
          |> pShowNoColor
          |> TL.unpack
          |> init
          |> tail
          |> interviewRulesRHS2topBit
  bottomBit <- traverse (`asPurescript` rules) nlgEnv
  mutter $ "** topBit =";    mutter $ show topBit
  mutter $ "** bottomBit ="; mutter $ show bottomBit
  -- [TODO] make this work
  -- mutters (concat $ lefts bottomBit) >>
  xpReturn [__i|
    #{topBit}

    #{unlines $ rights bottomBit}
  |]

interviewRulesRHS2topBit :: String -> String
interviewRulesRHS2topBit interviewRulesRHS =
  let interviewRulesRHS' = case interviewRulesRHS of
        (null -> True) -> [i|Leaf ""|]
        _ -> interviewRulesRHS
  in [__i|
    -- This file was automatically generated by natural4.
    -- Do not edit by hand.
    -- Instead, revise the toolchain starting at smucclaw/dsl/lib/haskell/natural4/app/Main.hs

    module RuleLib.Interview where

    import Prelude
    import Data.Either
    import Data.Maybe
    import Data.Tuple
    import Data.Map as Map
    import Foreign.Object as Object

    import AnyAll.Types

    interviewRules :: Item String
    interviewRules = #{interviewRulesRHS'}

    interviewRules_nl :: NLDict
    interviewRules_nl =
      Map.fromFoldable
        [ ]
  |]
