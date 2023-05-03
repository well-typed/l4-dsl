{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module LS.XPile.CoreL4.LogicProgram.LogicProgram
  ( babyL4ToLogicProgram,
    LPType (..),
    LogicProgram,
  )
where

import Control.Monad.Validate (MonadValidate (refute), Validate)
import Data.List (nub, partition)
import Data.Maybe (mapMaybe)
import Data.Monoid (Ap (Ap))
import Data.Set qualified as Set
import Data.Tuple.All (Curry (uncurryN), SequenceT (sequenceT))
import Flow ((|>))
import L4.KeyValueMap (ValueKVM)
import L4.Syntax
import L4.SyntaxManipulation
  ( appToFunArgs,
    applyVars,
    applyVarsNoType,
    decomposeBinop,
    funArgsToAppNoType,
    fv,
    isLocalVar,
  )
import LS.Utils (mapThenSwallowErrs, maybe2validate, (|$>))
import LS.XPile.CoreL4.LogicProgram.Common
  ( LPRule (LPRule, precondOfLPRule),
    LPType (..),
    LogicProgram (..),
    OpposesClause (OpposesClause),
  )
import LS.XPile.CoreL4.LogicProgram.Pretty.Pretty ()
import LS.XPile.CoreL4.LogicProgram.Skolemize (skolemizeLPRule)
import Prettyprinter (Doc, Pretty (pretty), viaShow)

-- TODO: type of function has been abstracted, is not Program t and not Program (Tp())
-- The price to pay: No more preprocessing of rules (simplification with clarify and ruleDisjL)
-- This could possibly be remedied with NoType versions of these tactics
babyL4ToLogicProgram ::
  forall lpType t.
  (Show t, Ord t, Eq t) =>
  Program t ->
  LogicProgram lpType t
babyL4ToLogicProgram prg =
    -- let rules = concatMap ruleDisjL (clarify (rulesOfProgram prg))
    let rules = rulesOfProgram prg
    -- putStrLn "Simplified L4 rules:"
    -- putDoc $ vsep (map (showL4 []) rules) <> line
        lpRulesWithNegs :: [(LPRule lpType t, [(Var t, Var t, Int)])]
        lpRulesWithNegs = mapThenSwallowErrs ruleToLPRule rules

        lpRules :: [LPRule lpType t]
        lpRules = map fst lpRulesWithNegs

        (lpRulesFact, lpRulesNoFact) = partition isHeadOfPrecondFact lpRules 

        skolemizedLPRules :: [LPRule lpType t]
        skolemizedLPRules = map skolemizeLPRule lpRulesNoFact  -- TODO: not used ??

        oppClausePrednames :: [(Var t, Var t, Int)]
        oppClausePrednames = lpRulesWithNegs |> foldMap snd |> nub

        oppClauses :: [OpposesClause t]
        oppClauses = map genOppClauseNoType oppClausePrednames
    in LogicProgram {lpRulesNoFact, lpRulesFact, oppClauses}

genOppClause :: (Var (Tp ()), Var (Tp ()), Int) -> OpposesClause (Tp ())
genOppClause (posvar, negvar, n) =
    let args = zipWith (\ vn i -> LocalVar (QVarName IntegerT (vn ++ show i)) i) (replicate n "V") [0 .. n-1]
    in OpposesClause (applyVars posvar args) (applyVars negvar args)

genOppClauseNoType :: (Var t, Var t, Int) -> OpposesClause t
genOppClauseNoType (posvar, negvar, n) =
    let vart = annotOfQVarName (nameOfVar posvar) in
    let args = zipWith (\ vn i -> LocalVar (QVarName vart (vn ++ show i)) i) (replicate n "V") [0 .. n-1]
    in OpposesClause (applyVarsNoType posvar args) (applyVarsNoType negvar args)

-- TODO: details to be filled in
proveAssertionASP :: Show t => Program t -> ValueKVM  -> Assertion t -> IO ()
proveAssertionASP p v asrt = putStrLn "ASP solver implemented"

isFact :: Expr t -> Bool
isFact (ValE _ (BoolV True)) = True
isFact _ = False

isHeadOfPrecondFact :: LPRule lpType t -> Bool
isHeadOfPrecondFact
  (LPRule {precondOfLPRule = precond : _}) = isFact precond

isHeadOfPrecondFact _ = False

ruleToLPRule ::
  forall ann lpType t.
  (Show t, Ord t) =>
  Rule t ->
  Ap (Validate (Doc ann)) (LPRule lpType t, [(Var t, Var t, Int)])
ruleToLPRule r =
  let precondsNeg :: Ap (Validate (Doc ann)) [(Expr t, Maybe (Var t, Var t, Int))]
      precondsNeg =
        traverse negationPredicate (decomposeBinop (BBool BBand) (precondOfRule r))

      postcondNeg :: Ap (Validate (Doc ann)) (Expr t, Maybe (Var t, Var t, Int))
      postcondNeg = negationPredicate $ postcondOfRule r

      preconds :: Ap (Validate (Doc ann)) [Expr t]
      preconds = map fst <$> precondsNeg

      postcond :: Ap (Validate (Doc ann)) (Expr t)
      postcond = fst <$> postcondNeg

      negpreds :: Ap (Validate (Doc ann)) [(Var t, Var t, Int)]
      negpreds =
        (postcondNeg, precondsNeg)
          |> sequenceT
          |$> uncurry (:)
          |$> mapMaybe snd

      allVars :: Ap (Validate (Doc ann)) (Set.Set (Var t))
      allVars =
        (postcond, preconds)
          |> sequenceT
          |$> uncurry (:)
          |$> (Set.unions . map fv)

      globalvars :: Ap (Validate (Doc ann)) [VarDecl t]
      globalvars =
        allVars
          |$> map varTovarDecl . Set.toList . Set.filter (not . isLocalVar)

      localvars :: Ap (Validate (Doc ann)) [VarDecl t]
      localvars =
        allVars
          |$> map varTovarDecl . Set.toList . Set.filter isLocalVar

      ruleName :: Ap (Validate (Doc ann)) String
      ruleName =
        r
          |> nameOfRule
          |> maybe2validate
              ("ToASP: ruleToLPRule: nameOfRule is a Nothing :-(\n" <>
                viaShow r <> "\n" <>
                "To exclude the ToASP transpiler from a --workdir run, run natural4-exe with the --toasp option.")
  in
    (ruleName, globalvars, localvars, preconds, postcond)
      |> sequenceT
      |$> uncurryN LPRule
      |> (, negpreds)
      |> sequenceT

--varTovarDecl :: Var (Tp()) -> VarDecl (Tp())
--varTovarDecl :: Var t -> VarDecl t
varTovarDecl :: Var t -> VarDecl t
varTovarDecl (GlobalVar (QVarName a vn)) = VarDecl a vn OkT
varTovarDecl (LocalVar (QVarName a vn) _ind) = VarDecl a vn OkT

negationVarname :: QVarName t -> QVarName t
negationVarname (QVarName t vn) = QVarName t ("not"++vn)

negationPredicate :: Expr t -> Ap (Validate (Doc ann)) (Expr t, Maybe (Var t, Var t, Int))
negationPredicate (UnaOpE _ (UBool UBnot) e@AppE{}) =
  let (f, args) = appToFunArgs [] e in
      case f of
          VarE t posvar@(GlobalVar vn) ->
              let negvar = GlobalVar (negationVarname vn)
              in pure (funArgsToAppNoType (VarE t negvar) args, Just (posvar, negvar, length args))
          _ -> refute "negationPredicate: ill-formed negation"
negationPredicate e = pure (e, Nothing)

-- TODO: type of function has been abstracted, is not Program t and not Program (Tp())
-- The price to pay: No more preprocessing of rules (simplification with clarify and ruleDisjL)
-- This could possibly be remedied with NoType versions of these tactics
-- astToASP :: (Eq t, Ord t, Show t) => Program t -> IO ()
-- astToASP prg = do
--     -- let rules = concatMap ruleDisjL (clarify (rulesOfProgram prg))
--     let rules = rulesOfProgram prg
--     -- putStrLn "Simplified L4 rules:"
--     -- putDoc $ vsep (map (showL4 []) rules) <> line
--     let aspRulesWithNegs = map (ruleToLPRule ) rules
--     let aspRules = map fst aspRulesWithNegs
--     let aspRulesNoFact = removeFacts aspRules
--     let aspRulesFact = keepFacts aspRules
--     let skolemizedLPRules = map skolemizeLPRule aspRulesNoFact  -- TODO: not used ??
--     let oppClausePrednames = nub (concatMap snd aspRulesWithNegs)
--     let oppClauses = map genOppClauseNoType oppClausePrednames

--     -- putStrLn "ASP rules:"
--     putDoc $ vsep (map (showASP AccordingToR) aspRulesNoFact) <> line <> line
--     putDoc $ vsep (map (showASP VarSubs1R) aspRulesNoFact) <> line <> line
--     putDoc $ vsep (map (showASP AddFacts) aspRulesFact) <> line <> line
--     putDoc $ vsep (map (showASP VarSubs3R) aspRulesNoFact) <> line <> line
--     putDoc $ vsep (map (showASP VarSubs2R) aspRulesNoFact) <> line <> line
--     putDoc $ vsep (map (showASP VarSubs4R) aspRulesNoFact) <> line <> line
--     -- putDoc $ vsep (map (showASP VarSubs2R) aspRules) <> line <> line
--     -- putDoc $ vsep (map (showASP ExplainsR) aspRules) <> line <> line
--     -- putDoc $ vsep (map (showASP ExplainsR) skolemizedLPRules) <> line <> line
--     putDoc $ vsep (map (showASP CausedByR) aspRulesNoFact) <> line <> line
--     putDoc $ vsep (map showOppClause oppClauses) <> line


-- removeFacts :: [ASPRule t] -> [ASPRule t]
-- removeFacts [] = []
-- removeFacts (r : rs)
--       | isFact (head (precondOfASPRule r)) = removeFacts rs
--       | otherwise = r : removeFacts rs


-- keepFacts :: [ASPRule t] -> [ASPRule t]
-- keepFacts [] =[]
-- keepFacts (r : rs)
--       | isFact (head (precondOfASPRule r)) = r : keepFacts rs
--       | otherwise = keepFacts rs

-- filt :: Eq t1 => [VarDecl t1] -> [VarDecl t1] -> [VarDecl t1]
-- filt [] _ = []
-- filt (x:xs) ys =
--   if x `elem` ys
--      then filt xs ys
--   else x : filt xs ys