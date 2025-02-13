{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ViewPatterns #-}

module LS.XPile.Edn.Common.Ast
  ( AstNode (..),
    AstNodeF (..),
    Op (..),
    pattern IsA,
    pattern IsOneOf,
    pattern Bool,
    pattern Number,
    pattern Integer,
    pattern Date,
    pattern PrefixOp,
    pattern UnaryOp,
    pattern InfixBinOp,
    pattern Fact,
    pattern Rule,
    pattern Program,
    pattern Not,
    pattern And,
    pattern Or,
    pattern Is,
    pattern IsNot,
    pattern IsIn,
    pattern IsNotIn,
    pattern Sum,
    pattern Product,
    pattern Plus,
    pattern Minus,
    pattern Times,
    pattern Divide,
    pattern Lt,
    pattern Leq,
    pattern Gt,
    pattern Geq,
    pattern Parens,
    pattern Seq,
    pattern Map,
    pattern Set,
  )
where

import Control.Arrow ((>>>))
import Data.Coerce (coerce)
import Data.Functor.Foldable.TH (makeBaseFunctor)
import Data.Hashable (Hashable)
import Data.String (IsString)
import Data.String.Interpolate (i)
import Data.Text qualified as T
import Data.Text.Read qualified as TRead
import GHC.Generics (Generic)
import LS.XPile.Edn.Common.Utils (listToPairs, pairsToList)
import Text.Read (readMaybe)

data AstNode metadata
  = HornClause
      { metadata :: Maybe metadata,
        givens :: [AstNode metadata],
        giveths :: [AstNode metadata],
        head :: AstNode metadata,
        body :: Maybe (AstNode metadata)
      }
  | CompoundTerm
      { metadata :: Maybe metadata,
        op :: Op,
        children :: [AstNode metadata]
      }
  | Text {metadata :: Maybe metadata, text :: T.Text}
  deriving (Eq, Ord, Show, Generic, Hashable)

data Op
  = ParensOp
  | SeqOp
  | MapOp
  | SetOp
  | AndOp
  | OrOp
  deriving (Eq, Ord, Show, Generic, Hashable)

makeBaseFunctor ''AstNode

pattern IsA ::
  Maybe metadata -> AstNode metadata -> [AstNode metadata] -> AstNode metadata
pattern IsA {metadata, var, typ} =
  Seq
    { metadata,
      elements = var : Text {metadata = Nothing, text = "IS A"} : typ
    }

pattern IsOneOf ::
  Maybe metadata -> AstNode metadata -> [AstNode metadata] -> AstNode metadata
pattern IsOneOf {metadata, var, elements} =
  Seq
    { metadata,
      elements = var : Text {metadata = Nothing, text = "IS ONE OF"} : elements
    }

pattern Parens :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern Parens {metadata, children} =
  CompoundTerm {metadata, op = ParensOp, children}

pattern Seq :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern Seq {metadata, elements} =
  CompoundTerm {metadata, op = SeqOp, children = elements}

pattern Map ::
  Maybe metadata -> [(AstNode metadata, AstNode metadata)] -> AstNode metadata
pattern Map {metadata, kvPairs} <-
  CompoundTerm {metadata, op = MapOp, children = listToPairs -> kvPairs}
  where
    Map metadata kvPairs =
      CompoundTerm {metadata, op = MapOp, children = pairsToList kvPairs}

pattern Set :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern Set {metadata, elements} =
  CompoundTerm {metadata, op = SetOp, children = elements}

pattern Number :: Maybe metadata -> Double -> AstNode metadata
pattern Number {metadata, number} <-
  Text {metadata, text = TRead.double -> Right (number, "")}
  where
    Number metadata number = Text {metadata, text = [i|#{number}|]}

pattern Bool :: Maybe metadata -> Bool -> AstNode metadata
pattern Bool {metadata, bool} <-
  Text {metadata, text = show >>> readMaybe -> Just bool}
  where
    Bool metadata bool =
      Text
        { metadata,
          text = if bool then "true" else "false"
        }

pattern Integer :: Maybe metadata -> Integer -> AstNode metadata
pattern Integer {metadata, int} <-
  Text {metadata, text = TRead.decimal -> Right (int, "")}
  where
    Integer metadata int = Text {metadata, text = [i|#{int}|]}

pattern Date ::
  Maybe metadata -> Integer -> Integer -> Integer -> AstNode metadata
pattern Date {metadata, year, month, day} =
  Parens
    { metadata,
      children = [Integer' year, Dash, Integer' month, Dash, Integer' day]
    }

pattern PrefixOp ::
  Maybe metadata -> T.Text -> [AstNode metadata] -> AstNode metadata
pattern PrefixOp {metadata, op, args} =
  Parens {metadata, children = [Text Nothing op, Parens Nothing args]}

pattern UnaryOp ::
  Maybe metadata -> T.Text -> AstNode metadata -> AstNode metadata
pattern UnaryOp {metadata, op, arg} = PrefixOp {metadata, op, args = [arg]}

pattern Not :: Maybe metadata -> AstNode metadata -> AstNode metadata
pattern Not {metadata, arg} = UnaryOp {metadata, op = "NOT", arg}

pattern Integer' :: Integer -> AstNode metadata
pattern Integer' {int} = Integer {metadata = Nothing, int}

pattern Dash :: AstNode metadata
pattern Dash = Text {metadata = Nothing, text = "-"}

pattern Fact ::
  Maybe metadata ->
  [AstNode metadata] ->
  [AstNode metadata] ->
  AstNode metadata ->
  AstNode metadata
pattern Fact {metadata, givens, giveths, head} =
  HornClause {metadata, givens, giveths, head, body = Nothing}

pattern Rule ::
  Maybe metadata ->
  [AstNode metadata] ->
  [AstNode metadata] ->
  AstNode metadata ->
  AstNode metadata ->
  AstNode metadata
pattern Rule {metadata, givens, giveths, head, body} =
  HornClause {metadata, givens, giveths, head, body = Just body}

pattern Program :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern Program {metadata, rules} = Seq {metadata, elements = rules}

pattern And :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern And {metadata, conjuncts} =
  CompoundTerm {metadata, op = AndOp, children = conjuncts}

pattern Or :: Maybe metadata -> [AstNode metadata] -> AstNode metadata
pattern Or {metadata, conjuncts} =
  CompoundTerm {metadata, op = OrOp, children = conjuncts}

pattern InfixBinOp ::
  Maybe metadata ->
  T.Text ->
  AstNode metadata ->
  AstNode metadata ->
  AstNode metadata
pattern InfixBinOp {metadata, op, lhs, rhs} =
  Parens
    { metadata,
      children = [lhs, Text {metadata = Nothing, text = op}, rhs]
    }

pattern Is ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Is {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "IS", rhs}

pattern IsNot ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern IsNot {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "IS NOT", rhs}

pattern IsIn ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern IsIn {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "IS IN", rhs}

pattern IsNotIn ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern IsNotIn {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "IS NOT IN", rhs}

pattern Sum :: Maybe metadata -> AstNode metadata -> AstNode metadata
pattern Sum {metadata, args} =
  Parens
    { metadata,
      children = [Text {metadata = Nothing, text = "SUM"}, args]
    }

pattern Product :: Maybe metadata -> AstNode metadata -> AstNode metadata
pattern Product {metadata, args} =
  Parens
    { metadata,
      children = [Text {metadata = Nothing, text = "PRODUCT"}, args]
    }

pattern Plus ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Plus {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "+", rhs}

pattern Minus ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Minus {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "-", rhs}

pattern Times ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Times {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "*", rhs}

pattern Divide ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Divide {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "/", rhs}

pattern Lt ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Lt {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "<", rhs}

pattern Leq ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Leq {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = "<=", rhs}

pattern Gt ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Gt {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = ">", rhs}

pattern Geq ::
  Maybe metadata -> AstNode metadata -> AstNode metadata -> AstNode metadata
pattern Geq {metadata, lhs, rhs} =
  InfixBinOp {metadata, lhs, op = ">=", rhs}