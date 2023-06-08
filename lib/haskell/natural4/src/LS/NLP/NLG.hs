{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs, NamedFieldPuns, FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

module LS.NLP.NLG where


import LS.NLP.NL4
import LS.NLP.NL4Transformations
import LS.Types
import LS.Interpreter (expandBSR, expandRP, expandClause, expandClauses)
import LS.Rule (Rule(..), Interpreted(..), ruleName)
import PGF
import Control.Monad (when)
import Data.HashMap.Strict (keys, elems, lookup, toList)
import qualified Data.HashMap.Strict as Map
import Data.Maybe (catMaybes, maybeToList, listToMaybe)
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Text as Text
import qualified AnyAll as AA
import System.Environment (lookupEnv)
import Paths_natural4
import qualified Data.Foldable as F
import Data.List (intercalate)
import qualified Data.Char as Char (toLower)
import LS.XPile.Logging

import Debug.Trace

data NLGEnv = NLGEnv
  { gfGrammar :: PGF
  , gfLang :: Language
  , gfParse :: Type -> Text.Text -> [Expr]
  , gfLin :: Expr -> Text.Text
  , verbose :: Bool
  , interpreted :: Interpreted
  }

allLangs :: IO [Language]
allLangs = do
  grammarFile <- getDataFileName $ gfPath "NL4.pgf"
  gr <- readPGF grammarFile
  pure $ languages gr

langEng :: IO Language
langEng = do
  grammarFile <- getDataFileName $ gfPath "NL4.pgf"
  gr <- readPGF grammarFile
  pure $ getLang "NL4Eng" gr

printLangs :: IO [Language] -> IO String
printLangs = fmap (intercalate "\", \"" . map (map Char.toLower . showLanguage))

getLang :: String -> PGF -> Language
getLang str gr = case (readLanguage str, languages gr) of
  (Just l, langs@(l':_))  -- Language looks valid, check if in grammar
    -> if l `elem` langs
         then l -- Expected case: language looks valid and is in grammar
         else trace (fallbackMsg $ show l') l' -- Language is valid but not in grammar, warn and fall back to another language
  (Nothing, l':_) -- Language not valid, warn and fall back to another language
    -> trace (fallbackMsg $ show l') l'
  (_, []) -- The PGF has no languages, truly unexpected and fatal
    -> error "NLG.getLang: the PGF has no languages, maybe you only compiled the abstract syntax?"
  where
    fallbackMsg fblang = unwords ["language", str, "not found, falling back to", fblang]

myNLGEnv :: Interpreted -> Language -> IO NLGEnv
myNLGEnv l4i lang = do
  mpn <- lookupEnv "MP_NLG"
  let verbose = maybe False (read :: String -> Bool) mpn
  grammarFile <- getDataFileName $ gfPath "NL4.pgf"
  gr <- readPGF grammarFile
  eng <- langEng
  let myParse typ txt = parse gr eng typ (Text.unpack txt)
      myLin = rmBIND . Text.pack . linearize gr lang
  pure $ NLGEnv gr lang myParse myLin verbose l4i

rmBIND :: Text.Text -> Text.Text
rmBIND = Text.replace " &+ " ""

gfPath :: String -> String
gfPath x = "grammars/" ++ x

-----------------------------------------------------------------------------
-- Main

-- WIP: crude way of keeping track of whether we're in hence, lest or whatever
data RecursionLevel = TopLevel | MyHence Int | MyLest Int
  deriving (Eq,Ord,Show)

getLevel :: RecursionLevel -> Int
getLevel l = case l of
  TopLevel -> 2
  MyHence i -> i
  MyLest i -> i

debugNesting :: Language -> RecursionLevel -> (Text.Text, Text.Text)
debugNesting lang level = (getPrefix lang level, Text.pack "")
  where
    getPrefix _ TopLevel = Text.pack ""
    getPrefix lang (MyHence _)
      | isChinese lang = Text.pack "在此之后，做:"
      | isMalay lang = Text.pack "Tindakan seterusnya:"
      | otherwise = Text.pack "Follow by:"
    getPrefix lang (MyLest _)
      | isChinese lang = Text.pack "万一失败，"
      | isMalay lang = Text.pack "Dalam kes kegagalan:"
      | otherwise = Text.pack "In case of failure:"

getIf :: Language -> Text.Text
getIf lang
  | isChinese lang = ". 如果 "
  | isMalay lang = ". Jika "
  | otherwise = ". If "

getWhen :: Language -> Text.Text
getWhen lang
  | isChinese lang = "于"
  | isMalay lang = "ketika"
  | otherwise = "when"

nlg :: NLGEnv -> Rule -> IO Text.Text
nlg = nlg' TopLevel

nlg' :: RecursionLevel -> NLGEnv -> Rule -> IO Text.Text
nlg' thl env rule = case rule of
    Regulative {subj,upon,temporal,cond,who,deontic,action,lest,hence} -> do
      let subjExpr = introduceSubj $ parseSubj env subj
          deonticExpr = parseDeontic deontic
          actionExpr = parseAction env action
          whoSubjExpr = case who of
                        Just w -> GSubjWho subjExpr (bsWho2gfWho (parseWhoBS env w))
                        Nothing -> subjExpr
          ruleTree = gf $ GRegulative whoSubjExpr deonticExpr actionExpr
          ruleText = gfLin env ruleTree
          uponText = case upon of  -- TODO: doesn't work once we add another language
                      Just u ->
                        let uponExpr = gf $ GadvUPON $ parseUpon env u
                         in gfLin env uponExpr <> ", "
                      Nothing -> mempty
          tcText = case temporal of
                      Just t -> " " <> gfLin env (gf $ parseTemporal env t)
                      Nothing -> mempty
          condText = case cond of
                      Just c ->
                        let condExpr = gf $ pastTense $ bsCond2gfCond (parseCondBS env c)
                         in getIf (gfLang env) <> gfLin env condExpr <> ", "
                      Nothing -> mempty
          ruleTextDebug = Text.unwords [prefix, uponText <> ruleText <> tcText <> condText, suffix]
      lestText <- case lest of
                    Just r -> do
                      rt <- nlg' (MyLest i) env r
                      pure $ pad rt
                    Nothing -> pure mempty
      henceText <- case hence of
                    Just r -> do
                      rt <- nlg' (MyHence i) env r
                      pure $ pad rt
                    Nothing -> pure mempty
      when (verbose env) $ do
        putStrLn "nlg': regulative"
        putStrLn $ "    " <> showExpr [] ruleTree
      pure $ Text.strip $ Text.unlines [ruleTextDebug, henceText, lestText]
    Hornlike {clauses} -> do
      let headTrees = gf . parseConstraint env . hHead <$> clauses -- :: [GConstraint] -- this will not become a question
          headLins = gfLin env <$> headTrees
          parseBodyHC cl = case hBody cl of
            Just bs -> [gf $ bsConstraint2gfConstraint $ parseConstraintBS env bs]
            Nothing -> []
          bodyTrees = concatMap parseBodyHC clauses
          bodyLins = gfLin env <$> bodyTrees
      when (verbose env) $ do
        putStrLn "nlg': hornlike"
        putStrLn $ unlines $ ["   head: " <> showExpr [] t | t <- headTrees]
        putStrLn $ unlines $ ["   body: " <> showExpr [] t | t <- bodyTrees]
      pure $ Text.unlines $ headLins <> [getWhen (gfLang env)] <> bodyLins
    RuleAlias mt -> do
      let ruleText = gfLin env $ gf $ parseSubj env $ mkLeafPT $ mt2text mt
          ruleTextDebug = Text.unwords [prefix, ruleText, suffix]
      pure $ Text.strip ruleTextDebug
    DefNameAlias {} -> pure mempty
    DefTypically {} -> pure mempty
    _ -> pure $ "NLG.hs is under construction, we don't support yet " <> Text.pack (show rule)
  where
    (prefix,suffix) = debugNesting (gfLang env) thl
    i = getLevel thl + 2
    pad x = Text.replicate i " " <> x


-- | rewrite statements into questions, for use by the Q&A web UI
--
-- +-----------------+-----------------------------------------------------+
-- | input           | the data breach, occurs on or after 1 Feb 2022      |
-- | output          | Did the data breach occur on or after 1 Feb 2022?   |
-- +-----------------+-----------------------------------------------------+
-- | input           | Organisation, NOT, is a Public Agency               |
-- | intermediate    | (AA.Not (...) :: BoolStructT                        |
-- | output          | Is the Organisation a Public Agency?                |
-- +-----------------+-----------------------------------------------------+
-- | input           | Claim Count <= 2                                    |
-- | intermediate    | RPConstraint (RPMT ["Claim Count"]) RelLTE          |
-- |                 |               (RPMT ["2"]) :: RelationalPredicate   |
-- | output          | Have there been more than two claims?               |
-- +-----------------+-----------------------------------------------------+


ruleQuestions :: NLGEnv -> Maybe (MultiTerm,MultiTerm) -> Rule -> XPileLog [AA.OptionallyLabeledBoolStruct Text.Text]
ruleQuestions env alias rule = do
  case rule of
    Regulative {subj,who,cond,upon} -> do
      when (verbose env) $ do
        mutter "ruleQuestions: regulative"
      text
    Hornlike {clauses} -> do
      when (verbose env) $ do
        mapM_ mutter ["ruleQuestions: horn"
                     , show $ ruleQnTrees env alias rule
                     , "---"]
      text
    Constitutive {cond} -> text
    DefNameAlias {} -> pure [] -- no questions needed to produce from DefNameAlias
    _ -> pure [AA.Leaf $ Text.pack ("ruleQuestions: doesn't work yet for " <> show rule)]
    where
      text = pure $ fmap (linBStext env) (concat $ ruleQnTrees env alias rule)


ruleQnTrees :: NLGEnv -> Maybe (MultiTerm,MultiTerm) -> Rule -> [[BoolStructGText]]
ruleQnTrees env alias rule = do
  let (youExpr, orgExpr) =
        case alias of
          Just (you,org) ->
              case parseSubj env . mkLeafPT . mt2text <$> [you, org] of
                [y,o] -> (y,o) -- both are parsed
                _ -> (GYou, GYou) -- dummy values
          Nothing -> (GYou, GYou) -- dummy values
  case rule of
    Regulative {subj,who,cond,upon} -> do
      let subjExpr = parseSubj env subj
          aliasExpr = if subjExpr==orgExpr then youExpr else referSubj subjExpr
          qWhoTrees = mkWhoText env GqPREPOST (GqWHO aliasExpr) <$> who
          qCondTrees = mkCondText env GqPREPOST GqCOND <$> cond
          qUponTrees = mkUponText env (GqUPON aliasExpr) <$> upon
      return $ catMaybes [qWhoTrees, qCondTrees, qUponTrees]
    Hornlike {clauses} -> do
      let bodyTrees = fmap (mkConstraintText env GqPREPOST GqCONSTR) . hBody <$> clauses
      return $ catMaybes bodyTrees
    Constitutive {cond} -> do
      let qCondTrees = mkCondText env GqPREPOST GqCOND <$> cond
      return $ catMaybes [qCondTrees]
    DefNameAlias {} -> pure []
    _ -> pure []

linBStext :: NLGEnv -> BoolStructGText -> AA.OptionallyLabeledBoolStruct Text.Text
linBStext env = mapBSLabel (gfLin env . gf) (gfLin env . gf)

mkWhoText :: NLGEnv -> (GPrePost -> GText) -> (GWho -> GText) -> BoolStructR -> BoolStructGText
mkWhoText env f g bsr = mapBSLabel f g $ aggregateBoolStruct (gfLang env) $ parseWhoBS env bsr

mkCondText :: NLGEnv -> (GPrePost -> GText) -> (GCond -> GText) -> BoolStructR -> BoolStructGText
mkCondText env f g bsr = mapBSLabel f g $ aggregateBoolStruct (gfLang env) $ parseCondBS env bsr

mkConstraintText :: NLGEnv -> (GPrePost -> GText) -> (GConstraint -> GText) -> BoolStructR -> BoolStructGText
mkConstraintText env f g bsr = mapBSLabel f g $ aggregateBoolStruct (gfLang env) $ parseConstraintBS env bsr

mkUponText :: NLGEnv -> (GUpon -> GText) -> ParamText -> BoolStructGText
mkUponText env f pt = AA.Leaf  (f $ parseUpon env pt)

-- mkUponText :: NLGEnv -> (GUpon -> GText) -> ParamText -> AA.OptionallyLabeledBoolStruct Text.Text
-- mkUponText env f = AA.Leaf . gfLin env . gf . f . parseUpon env

nlgQuestion :: NLGEnv -> Rule -> XPileLog [Text.Text]
nlgQuestion env rl = do
  questionsInABoolStruct <- ruleQuestions env Nothing rl -- TODO: the Nothing means there is no AKA
  pure $ concatMap F.toList questionsInABoolStruct

-----------------------------------------------------------------------------
-- Parsing fields into GF categories – all typed, no PGF.Expr allowed

-- Special constructions for the fields that are BoolStructR
parseConstraintBS :: NLGEnv -> BoolStructR -> BoolStructConstraint
parseConstraintBS env = mapBSLabel (parsePrePost env) (parseConstraint env)

parseWhoBS :: NLGEnv -> BoolStructR -> BoolStructWho
parseWhoBS env = mapBSLabel (parsePrePost env) (parseWho env)

parseCondBS :: NLGEnv -> BoolStructR -> BoolStructCond
parseCondBS env = mapBSLabel (parsePrePost env) (parseCond env)

-- not really parsing, just converting nL4 constructors to GF constructors
parseDeontic :: Deontic -> GDeontic
parseDeontic DMust = GMUST
parseDeontic DMay = GMAY
parseDeontic DShant = GSHANT

parseTComparison :: TComparison -> GTComparison
parseTComparison TBefore = GBEFORE
parseTComparison TAfter = GAFTER
parseTComparison TBy = GBY
parseTComparison TOn = GON
parseTComparison TVague = GVAGUE

parseDate :: MultiTerm -> GDate
parseDate mt = case Text.words $ mt2text mt of
  [d, m, y] -> GMkDate (tDay d) (tMonth m) (mkYear y)
  _ -> GMkDate (LexDay "Day1") (LexMonth "Jan") dummyYear
 where
  dummyYear = mkYear "1970"

  mkYear :: Text.Text -> GYear
  mkYear y = GMkYear (LexYearComponent y1) (LexYearComponent y2) (LexYearComponent y3) (LexYearComponent y4)
    where [y1, y2, y3, y4] = splitYear y

  splitYear :: Text.Text -> [String]
  splitYear y = case ["Y" <> [d] | d <- Text.unpack y] of
    xs@[_, _, _, _] -> xs
    _ -> ["Y2", "Y0", "Y0", "Y0"]

  tDay :: Text.Text -> GDay
  tDay t = LexDay ("Day"<> Text.unpack t)

  tMonth :: Text.Text -> GMonth
  tMonth = LexMonth . Text.unpack


-- TODO: stop using *2text, instead use the internal structure
  -- "respond" :| []  -> respond : VP
  -- "demand" :| [ "an explanation for your inaction" ] -> demand : V2, NP complement, call ComplV2
  -- "assess" :| [ "if it is a Notifiable Data Breach" ] -> assess : VS, S complement, call ComplS2
parseAction :: NLGEnv -> BoolStructP -> GAction
parseAction env bsp = fg tree
  where
    txt = bsp2text bsp
    tree :| _ = parseAny "Action" env txt

parseSubj :: NLGEnv -> BoolStructP -> GSubj
parseSubj env bsp = fg tree
  where
    txt = bsp2text bsp
    tree :| _ = parseAny "Subj" env txt

parseWho :: NLGEnv -> RelationalPredicate -> GWho
parseWho env rp = fg tree
  where
    txt = rp2text rp
    tree :| _ = parseAny "Who" env txt

parseCond :: NLGEnv -> RelationalPredicate -> GCond
parseCond env (RPConstraint c (RPTC t) d) = GRPConstraint cond tc date
  where
    cond = parseCond env (RPMT c)
    tc = parseTComparison t
    date = parseDate d
parseCond env rp = fg tree
  where
    txt = rp2text rp
    tree :| _ = parseAny "Cond" env txt

parseUpon :: NLGEnv -> ParamText -> GUpon
parseUpon env pt = fg tree
  where
    txt = pt2text pt
    tree :| _ = parseAny "Upon" env txt

parseTemporal :: NLGEnv -> TemporalConstraint Text.Text -> GTemporal
parseTemporal env (TemporalConstraint t (Just int) text) = GTemporalConstraint tc digits unit
  where
    tc = parseTComparison t
    digits = mkDigits int
    unit = parseTimeUnit text

    mkDigits :: Integer -> GDigits
    mkDigits i = case [LexDig $ "D_" <> [d] | d <- show i] of
      [] -> GIDig (LexDig "D_0") -- shouldn't happen, TODO alert user?
      [dig] -> GIDig dig
      xs -> foldr GIIDig (GIDig (last xs)) (init xs)

parseTemporal _ (TemporalConstraint t Nothing text) = GTemporalConstraintNoDigits tc unit
  where
    tc = parseTComparison t
    unit = parseTimeUnit text

parseTimeUnit :: Text.Text -> GTimeUnit
parseTimeUnit text = case take 3 $ Text.unpack $ Text.toLower text of
  "day" -> GDay_Unit
  "mon" -> GMonth_Unit
  "yea" -> GYear_Unit
  _xs -> trace ("NLG.hs: unrecognised time unit: " <> Text.unpack text) (GrecoverUnparsedTimeUnit (tString text))

parseConstraint :: NLGEnv -> RelationalPredicate -> GConstraint
parseConstraint env (RPBoolStructR a RPis (AA.Not b)) = case (nps,vps) of
  (np:_, vp:_) -> GRPleafS (fg np) (flipPolarity $ fg vp)
  _ -> GrecoverRPis (tString aTxt) (tString $ Text.unwords ["not", bTxt])
  where
    aTxt = mt2text a
    bTxt = bsr2text b
    nps = parseAnyNoRecover "NP" env aTxt
    vps = parseAnyNoRecover "VPS" env $ Text.unwords ["is", bTxt]

parseConstraint env (RPConstraint a RPis b) = case (nps,vps) of
  (np:_, vp:_) -> GRPleafS (fg np) (fg vp)
  _ -> GrecoverRPis (tString aTxt) (tString bTxt)
  where
    aTxt = mt2text a
    bTxt = mt2text b
    nps = parseAnyNoRecover "NP" env aTxt
    vps = parseAnyNoRecover "VPS" env $ Text.unwords ["is", bTxt]

    tString :: Text.Text -> GString
    tString = GString . Text.unpack

parseConstraint env rp = fg tree
  where
    txt = rp2text rp
    tree :| _ = parseAny "Constraint" env txt

parsePrePost :: NLGEnv -> Text.Text -> GPrePost
parsePrePost env txt = fg tree
  where
    tree :| _ = parseAny "PrePost" env txt

-- TODO: later if grammar is ambiguous, should we rank trees here?
parseAny :: String -> NLGEnv -> Text.Text -> NonEmpty Expr
parseAny cat env txt = res
  where
    typ = case (readType cat, categories (gfGrammar env)) of
            (Just t, cats) -> if t `elem` [mkType [] c [] | c <- cats]
                                then t
                                else typeError cat cats
            (Nothing, cats) -> typeError cat cats
    res = case gfParse env typ txt of
            -- [] -> parseError cat --- Alternative, if we don't want to use recoverUnparsedX
            [] -> NE.fromList [mkApp (mkCId $ "recoverUnparsed"<>cat) [mkStr $ Text.unpack txt]]
            xs -> NE.fromList xs

parseAnyNoRecover :: String -> NLGEnv -> Text.Text -> [Expr]
parseAnyNoRecover cat env = gfParse env typ
  where
    typ = case (readType cat, categories (gfGrammar env)) of
            (Just t, cats) -> if t `elem` [mkType [] c [] | c <- cats]
                                then t
                                else typeError cat cats
            (Nothing, cats) -> typeError cat cats

-- parseError :: String -> Text.Text -> a
-- parseError cat txt = error $ unwords ["parse"<>cat, "failed to parse", Text.unpack txt]

typeError :: String -> [CId] -> a
typeError cat actualCats = error $ unwords ["category", cat, "not a valid GF cat, use one of these instead:", show actualCats]

tString :: Text.Text -> GString
tString = GString . Text.unpack
-----------------------------------------------------------------------------
-- Expand a set of rules

expandRulesForNLG :: NLGEnv -> [Rule] -> [Rule]
expandRulesForNLG env rules = expandRuleForNLG l4i 1 <$> uniqrs
  where
    l4i = interpreted env
    usedrules = getExpandedRuleNames l4i `concatMap` rules
    uniqrs = [r | r <- rules, ruleName r `notElem` usedrules ]

getExpandedRuleNames :: Interpreted -> Rule -> [RuleName]
getExpandedRuleNames l4i rule = case rule of
  Regulative {} -> concat $ maybeToList $ getNamesBSR l4i 1 <$> who rule
  Hornlike {} -> getNamesHC l4i `concatMap` clauses rule
  _ -> []

  where
    getNamesBSR :: Interpreted -> Int -> BoolStructR -> [RuleName]
    getNamesBSR l4i depth (AA.Leaf rp)  =
      case expandRP l4i (depth + 1) rp of
        RPBoolStructR mt1 RPis _bsr -> [mt1]
        o                           -> []
    getNamesBSR l4i depth (AA.Not item)   = getNamesBSR l4i (depth + 1) item
    getNamesBSR l4i depth (AA.All lbl xs) = getNamesBSR l4i (depth + 1) `concatMap` xs
    getNamesBSR l4i depth (AA.Any lbl xs) = getNamesBSR l4i (depth + 1) `concatMap` xs

    getNamesRP :: Interpreted -> Int -> RelationalPredicate -> [RuleName]
    getNamesRP l4i depth (RPConstraint  mt1 RPis mt2) = [mt2]
    getNamesRP l4i depth (RPBoolStructR mt1 RPis bsr) = getNamesBSR l4i depth bsr
    getNamesRP _l4i _depth _x                          = []

    getNamesHC :: Interpreted -> HornClause2 -> [RuleName]
    getNamesHC l4i clause = headNames <> bodyNames
     where
      headNames = getNamesRP l4i 1 $ hHead clause
      bodyNames = concat $ maybeToList $ getNamesBSR l4i 1 <$> hBody clause

-- This is used for creating questions from the rule, so we only expand
-- the fields that are used in ruleQuestions
expandRuleForNLG :: Interpreted -> Int -> Rule -> Rule
expandRuleForNLG l4i depth rule = case rule of
  Regulative{} -> rule {
    who = expandBSR l4i depth <$> who rule
  , cond = expandBSR l4i depth <$> cond rule
  , upon = expandPT l4i depth <$> upon rule
  , hence = expandRuleForNLG l4i depth <$> hence rule
  , lest = expandRuleForNLG l4i depth <$> lest rule
  }
  Hornlike {} -> rule {
    clauses = expandClauses l4i depth $ clauses rule
  }
  Constitutive {} -> rule {
    cond = expandBSR l4i depth <$> cond rule
  }
  _ -> rule

-- I suspect that original intention was to not include expansions in UPON?
-- But in any case, here is a function that is applied in expandRuleForNLG to expand the UPON field.
-- There's a test case for this in NLGSpec ("test expandRulesForNLG for pdpa1 with added UPON expansion")
expandPT :: Interpreted -> Int -> ParamText -> ParamText
expandPT l4i depth pt = maybe pt ptFromRP expanded
  where
    ptAsMt = [MTT $ pt2text pt]
    fallbackPTfromRP = mt2pt . rp2mt
    ptFromRP (RPParamText pt)         = pt
    ptFromRP (RPMT mt)                = mt2pt mt
    ptFromRP (RPConstraint _ RPis mt) = mt2pt mt
    ptFromRP rp@(RPBoolStructR _ RPis bsr@(AA.Leaf _)) = mt2pt [MTT $ bsr2text bsr] -- Only works if the BSR is a leaf; otherwise we lose structure when trying to convert a BSR into ParamText
    ptFromRP rp = trace ("ptFromRP: encountered " <> show rp) $ fallbackPTfromRP rp

    expanded = listToMaybe
                [ outrp
                | (_scopename, symtab) <- Map.toList (scopetable l4i)
                , (_mytype, cs) <- maybeToList $ Map.lookup ptAsMt symtab
                , c <- cs
                , let outs = expandClause l4i depth c
                , outrp <- outs
                ]
