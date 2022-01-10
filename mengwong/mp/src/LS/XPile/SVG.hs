{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module LS.XPile.SVG where

import LS
import LS.XPile.Petri
import AnyAll as AA

import Data.GraphViz
import Data.GraphViz.Attributes
import Data.Graph.Inductive.Graph
import Data.Graph.Inductive.PatriciaTree

import           Debug.Trace
import           Text.Pretty.Simple
import qualified Data.Text.Lazy     as Text
import           Data.Text.Lazy              (Text)
import qualified Data.List.NonEmpty as NE
import           Data.Maybe                  (fromMaybe, listToMaybe)
import qualified Data.Map           as Map
import Data.GraphViz.Printing (renderDot)
import Data.GraphViz.Attributes.Complete (Attribute(TailPort,HeadPort, Comment)
                                         , CompassPoint(..)
                                         , PortPos(..))
import Control.Monad.State.Strict (State, MonadState (get, put), evalState, runState, gets)

type RuleSet = [Rule]

getByName :: RuleSet -> RuleName -> Maybe Rule
getByName rs rn = listToMaybe (filter (\r -> ruleName r == rn) rs)

-- initially let's just draw the state diagram in a manner typical of GraphViz.
-- see the README

toPetri :: [Rule] -> Text.Text
toPetri rules =
  let newgraph = insrules rules startGraph
  in renderDot $ unqtDot $ graphToDot (petriParams newgraph) newgraph


prefix :: Int -> Text.Text -> Text.Text
prefix n t = Text.pack (replicate n ' ') <> t

startGraph :: Petri
startGraph = mkGraph [ (1, PN Place "FULFILLED" [])
                     , (0, PN Place "BREACH"    []) ] []


getNodeByLabel :: Petri -> Text -> Maybe Node
getNodeByLabel gr ntxt = listToMaybe $ nodes $ labnfilter (\ln -> ntext (snd ln) == ntxt) gr

insrules :: RuleSet -> Petri -> Petri
insrules rs sg = foldr (\r g -> traceShowId $ runGM g (r2fgl rs r)
                       ) sg rs

data NodesEdges = NE { neNodes :: [LNode PNode], neEdges :: [LEdge PLabel] }
  deriving (Show, Eq)

instance Semigroup NodesEdges where
  (NE ns es) <> (NE ns' es') = NE (ns ++ ns') (es ++ es')
instance Monoid NodesEdges where
  mempty = NE [] []

insertNE :: DynGraph gr => NodesEdges -> gr PNode PLabel -> gr PNode PLabel
insertNE ne = insEdges (neEdges ne) . insNodes (neNodes ne)

{-

Alternative imperative approach:

do
  node1 <- newNode
  node2 <- newNode
  let edge = (node1, node2, "")

-}

data GraphState = GS { lastNode :: Node, curentGraph :: Petri }

newtype GraphMonad a = GM { runGM_ :: State GraphState a }
  deriving newtype (Functor, Applicative, Monad)

-- instance Semigroup a => Semigroup (GraphMonad a) where
--   a <> b = (<>) <$> a <*> b

-- instance Monoid a => Monoid (GraphMonad a) where
--   mempty = pure mempty

newNode :: PNode -> GraphMonad Node
newNode lbl = do
  gs@GS {lastNode = n, curentGraph = g} <- GM get
  let n' = succ n
  -- traceM $ "newNode: " <> show n' <> " " <> show lbl
  GM . put $ gs {lastNode = n' , curentGraph = insNode (n', lbl) g }
  return n'

newEdge :: Node -> Node -> PLabel -> GraphMonad ()
newEdge n1 n2 lbl = do
  gs@GS {curentGraph = g} <- GM get
  GM . put $ gs {curentGraph = insEdge (n1, n2, lbl) g }

newEdge' :: (Node, Node, PLabel) -> GraphMonad ()
newEdge' (a,b,c) = newEdge a b c

-- runGM :: Petri -> GraphMonad a -> a
runGM :: Petri -> GraphMonad a -> Petri
runGM gr (GM m) = cg
-- runGM gr (GM m) = traceShow (neNodes res, neNodes cg) res
  where (_, n0) = nodeRange gr
        (_res, GS _ln cg) = runState m (GS n0 gr)

-- This is currently kind of inefficient, but when NE is replaced by a real graph, it becomes simpler and faster
getGraph :: GraphMonad Petri
getGraph = do
    GM $ gets curentGraph

-- we convert each rule to a list of nodes and edges which can be inserted into an existing graph
r2fgl :: RuleSet -> Rule -> GraphMonad (Maybe Node)
r2fgl rs RegFulfilled   = pure Nothing
r2fgl rs RegBreach      = pure Nothing
-- what do we do with a RuleAlias? it only ever appears as the target of a Hence or a Lest,
-- so we just wire it up to whatever existing rule has been labeled appropriately.
-- however, if no existing rule in our list of rules bears that label (yet(, we put in a placeholder state.
-- the following function assumes the rulealias does not appear in the ruleset, so we are calling r2fgl as a last resort.
-- we will do another pass over the graph subsequently to rewire any rulealiases
r2fgl rs (RuleAlias rn) = do
  sg <- getGraph
  let ntxt = Text.unwords rn
      already = getNodeByLabel sg ntxt
  maybe (fmap Just . newNode $ mkPlace ntxt) (pure . Just) already
r2fgl rs r@(Regulative{..}) = do
  -- let newN = newNodes 9 sg
  --     -- new n = newN !! n
  -- traceShowM newN
  let everywho = Text.unwords ( ( if keyword == Every then [ Text.pack (show keyword) ] else [] )
                                <> [ subj2nl NLen subj ] )
  whoN  <- case who of Nothing  -> newNode $ mkPlace everywho
                       Just bsr -> do everyN <- newNode $ mkDecis everywho
                                      whoN <- newNode $ mkTrans $ "who " <> bsr2text bsr
                                      newEdge everyN whoN []
                                      pure whoN
  upoN  <- case upon of Nothing -> pure whoN
                        Just pt -> do 
                              uponN <- newNode $ mkPlace "upon"
                              uponCondN <- newNode $ mkTrans $ pt2text pt
                              newEdge' ( whoN,      uponN, [])
                              newEdge' ( uponN, uponCondN, [])
                              pure uponCondN
  -- let cNE = whoNE <> upoNE
  conN  <- case cond of Nothing  -> pure upoN
                        Just bsr -> do
                            ifN <- newNode $ mkDecis "if"
                            ifCondN <- newNode $ mkTrans $ bsr2text bsr
                            newEdge' ( upoN,    ifN, [] )
                            newEdge' ( ifN, ifCondN, [] ) 
                            pure ifCondN
  -- let dNE = cNE <> conNE
  (onSuccessN, onFailureN) <- do
    let deon = case deontic of { DMust -> "must"; DMay -> "may"; DShant -> "shant" }
        temp = tc2nl NLen temporal
        actn = actionFragments action
        oblLab = mkDecis (addnewlines [ deon
                                      , Text.unwords . NE.toList . fst . NE.head $ head actn
                                      , temp
                                      ])
        successLab = mkTrans $ vp2np ( actionWord $ head $ actionFragments action) <> " " <> henceWord deontic
    obligationN <- newNode oblLab
    onSuccessN <- newNode successLab
    onFailureN <- if deontic /= DMay then do 
        onFailureN <- newNode $ mkTrans $ lestWord deontic
        newEdge' ( obligationN, onFailureN, swport)
        pure (Just onFailureN)
      else pure Nothing
    -- let failureNE = NE [( onFailureN, mkTrans $ lestWord deontic ) | deontic /= DMay] [( obligationN, onFailureN, swport) | deontic /= DMay]
    newEdge' ( conN, obligationN, [] )
    newEdge' ( obligationN, onSuccessN, seport)
    pure (onSuccessN, onFailureN)
           
  -- let sg1 = insertNE (dNE <> dtaNE) sg

  mbHenceN <- maybe (pure Nothing) (r2fgl rs) hence
  -- traceM $ "henceNEs: " <> show henceNEs
  -- let sg2 = insertNE henceNEs sg1

  mbLestN  <- maybe (pure Nothing) (r2fgl rs) lest
  -- traceM $ "lestNEs: " <> show lestNEs
  -- let sg3 = insertNE lestNEs  sg2
      -- connect up the hence and lest bits
      -- the "hence" transition from dtaE should plug in to the first node in our henceContexts
  case mbHenceN of Just henceN -> newEdge onSuccessN henceN []
                   Nothing -> newEdge onSuccessN 1 []
  let toLest
        | Just lestN <- mbLestN, Just nd <- onFailureN = newEdge' (nd, lestN, [])
        | deontic /= DMay , Just nd <- onFailureN = newEdge' (nd, 0, [Comment "onoes, go to breach"])
        | otherwise = pure ()
  toLest
  pure $ Just whoN
  where
    vp2np "assess" = "assessment"
    vp2np "respond" = "response"
    vp2np x = x

    seport = [TailPort (CompassPoint SouthEast), Comment "southeast for positive"]
    swport = [TailPort (CompassPoint SouthWest), Comment "southwest for negative"]
    henceWord DMust  = "done"
    henceWord DMay   = "occurred"
    henceWord DShant = "avoided"
    lestWord DMust  = "not done"
    lestWord DMay   = error "a MAY has no LEST"  -- this should never arise
    lestWord DShant = "violation"

r2fgl rs r = pure Nothing

c2n :: Context a b -> Node
c2n (_, n, nl, _) = n

{-
  party Who is Nothing       (party)

  party Who is Just          <party>
                               [who-pos]

  upon is Just                   (Upon)
                                   [event]

  cond is Just                       (if) -- optional, only if the previous exit node is a transition
                                       [if conds]

  deontic                                (must (within temporal) action)

  hence                                    [hence]
  lest                                     [lest]
-}




subj2nl :: NatLang -> BoolStructP -> Text.Text
subj2nl NLen (AA.Leaf pt) = pt2text pt


deonticTemporal :: Rule -> [(Text.Text, Text.Text)]
deonticTemporal r@(Regulative{..}) =
  let d = case deontic of { DMust -> "must"; DMay -> "may"; DShant -> "shant" }
      temp = tc2nl NLen temporal
      actions = actionFragments action
  in dTshow d temp <$> actions
  where
    dTshow :: Text -> Text -> ParamText -> (Text,Text)
    dTshow deon temp actn =
      let aW = actionWord actn
          aLine1 = Text.unwords . NE.toList . fst . NE.head $ actn
      in (aW, addnewlines [ deon
                          , "(" <> temp <> ")"
                          , aLine1 ])

addnewlines :: [Text] -> Text
addnewlines = Text.intercalate "\\n"

-- the BoolStructP could be an AND  .. or an OR .. how do we represent all that in the petri net?
-- for now let's only handle
    -- a simple Leaf situation
    -- an AND situation

actionFragments :: BoolStructP -> [ParamText]
actionFragments (AA.All _ xs) = concatMap actionFragments xs
actionFragments (AA.Leaf x) = [x]
actionFragments _           = []

actionWord :: ParamText -> Text.Text
actionWord = NE.head . fst . NE.head

