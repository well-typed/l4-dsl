{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-
  Work-in-progress transpiler to Maude.
  Note that since we do all the parsing and transpilation within Maude itself,
  all we do here is convert the list of rules to a textual, string
  representation that Maude can parse.
-}

module LS.XPile.Maude.Rule
  ( rule2doc,
  )
where

import AnyAll (BoolStruct (All, Leaf))
import Data.Foldable qualified as Fold
import Data.Monoid (Ap (Ap))
import Flow ((.>), (|>))
import LS.Types
    ( HornClause(..),
      MultiTerm,
      MyToken(Means),
      RPRel(RPis),
      RelationalPredicate(RPBoolStructR, RPMT) )
import LS.Rule (Rule (..), rkeyword)
import LS.XPile.Maude.RkeywordDeonticActorAction
  ( RKeywordActorDeonticAction (..),
    rkeywordDeonticActorAction2doc,
  )
import LS.XPile.Maude.Utils (text2qid, (|$>), throwDefaultErr, multiExprs2qid)
import Prettyprinter (Doc, vcat, (<+>), hsep)
import Witherable (wither)
import LS.XPile.Maude.TempConstr (tempConstr2doc)
import LS.XPile.Maude.HenceLest (HenceLestClause(..), HenceLest (..), henceLest2doc)
import Data.List (intersperse)

{-
  Based on experiments being run here:
  https://docs.google.com/spreadsheets/d/1leBCZhgDsn-Abg2H_OINGGv-8Gpf9mzuX1RR56v0Sss/edit#gid=929226277
-}
-- testRule :: String
-- testRule = rules2maudeStr [Regulative {..}]
--   where
--     rlabel = Just ("§", 1, "START")
--     rkeyword = RParty
--     subj = Leaf ((MTT "actor" :| [], Nothing) :| [])
--     deontic = DMust
--     action = Leaf ((MTT "action" :| [], Nothing) :| [])
--     temporal = Just (TemporalConstraint TBefore (Just 5) "day")
--     hence = Just (RuleAlias [MTT "rule0", MTT "and", MTT "rule1"])
--     lest = Nothing

--     -- The remaining fields aren't used and hence don't matter.
--     given = Nothing
--     having = Nothing
--     who = Nothing
--     cond = Nothing
--     lsource = Nothing
--     srcref = Nothing
--     upon = Nothing
--     wwhere = []
--     defaults = []
--     symtab = []

-- Main function that transpiles individual rules.
rule2doc :: Rule -> Ap (Either (Doc ann1)) (Doc ann2)
rule2doc
  Regulative
    { rlabel = Just (_, _, ruleName),
      rkeyword,
      subj = Leaf actor,
      deontic,
      action = Leaf action,
      temporal,
      hence,
      lest
      -- srcref, -- May want to use this for better error reporting.
    } =
    {-
      Here we first process separately:
      - RULE ruleName
      - rkeyword actor
      - deontic action
      - deadline
      - HENCE/LEST clauses
      If an error occurs, seaquenceA short-circuits the unhappy path.
      We continue along the happy path by removing empty docs and vcat'ing
      everything together.
    -}
    [ruleName', rkeywordActorDeonticAction, deadline, henceLestClauses]
      -- Sequence to propagate errors that occured while processing
      -- rkeyword actor, deontic action, deadline, and henceLestClauses.
      |> sequenceA
      |$> mconcat .> vcat
    where
      ruleName' = pure ["RULE" <+> text2qid ruleName]
      rkeywordActorDeonticAction =
        [RKeywordActor rkeyword actor, DeonticAction deontic action]
          |> traverse rkeywordDeonticActorAction2doc

      deadline = temporal |> tempConstr2doc |$> Fold.toList

      henceLestClauses =
        -- wither is an effectful mapMaybes, so that this maps henceLest2doc
        -- which returns (Either s (Maybe (Doc ann)) over the list,
        -- throwing out all the (Right Nothing).
        -- Note that this is effectful in that we short-circuit when we
        --- encounter a Left.
        [HenceLestClause HENCE hence, HenceLestClause LEST lest]
          |> wither henceLest2doc

rule2doc DefNameAlias {name, detail} =
  pure $ nameDetails2means name [detail]

{-
  clauses =
  [ RPBoolStructR ["Notification"] RPis
    (All _
      Leaf ( RPMT [MTT "Notify PDPC"] ),
      Leaf ( RPMT [MTT "Notify Individuals"] )) ]
-}
rule2doc
  Hornlike
    { keyword = Means,
      clauses = [HC {hHead = RPBoolStructR mtExpr RPis (All _ leaves)}]
    } =
    leaves |> traverse leaf2mtt |$> nameDetails2means mtExpr
    where
      leaf2mtt (Leaf (RPMT mtt)) = pure mtt
      leaf2mtt _ = throwDefaultErr

rule2doc _ = throwDefaultErr

nameDetails2means :: MultiTerm -> [MultiTerm] -> Doc ann
nameDetails2means name details =
  hsep [name', "MEANS", details']
  where
    name' = multiExprs2qid name
    details' =
      details
        |$> multiExprs2qid
        |> intersperse "AND"
        |> hsep
        |> parenthesizeIf (lengthMoreThanOne details)

    parenthesizeIf True x = mconcat ["(", x, ")"]
    parenthesizeIf False x = x

    lengthMoreThanOne (_ : _ : _) = True
    lengthMoreThanOne _ = False