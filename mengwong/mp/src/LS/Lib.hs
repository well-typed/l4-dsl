{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE TypeOperators      #-}
{-# LANGUAGE FlexibleInstances  #-}  -- One more extension.
{-# LANGUAGE StandaloneDeriving #-}  -- To derive Show


module LS.Lib where

-- import qualified Data.Tree      as Tree
import qualified Data.Text.Lazy as Text
-- import Data.Text.Lazy.Encoding (decodeUtf8)
import Text.Megaparsec
import qualified Data.Set           as Set
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString)
import qualified Data.Csv as Cassava
import qualified Data.Vector as V
import Data.Vector ((!), (!?))
import Data.Maybe (fromMaybe, listToMaybe, isJust, fromJust, maybeToList)
import Text.Pretty.Simple (pPrint)
import qualified AnyAll as AA
import qualified Text.PrettyPrint.Boxes as Box
import           Text.PrettyPrint.Boxes hiding ((<>))
import System.Environment (lookupEnv)
import qualified Data.ByteString.Lazy as BS
import qualified Data.List.Split as DLS
import Text.Parser.Permutation
import Data.Aeson.Encode.Pretty
import Data.List.NonEmpty ( NonEmpty((:|)), nonEmpty, toList )
import Options.Generic

import LS.Types
import LS.Tokens
import LS.Parser
import LS.ParamText
import LS.RelationalPredicates
import LS.Error ( errorBundlePrettyCustom )
import LS.NLG (nlg)
import Control.Monad.Reader (asks, local)
import Control.Monad.Writer.Lazy

import LS.XPile.CoreL4
-- import LS.XPile.Prolog
import qualified Data.List.NonEmpty as NE
import Data.List (transpose)
import qualified LS.XPile.Uppaal as Uppaal

-- our task: to parse an input CSV into a collection of Rules.
-- example "real-world" input can be found at https://docs.google.com/spreadsheets/d/1qMGwFhgPYLm-bmoN2es2orGkTaTN382pG2z3RjZ_s-4/edit

-- the wrapping 'w' here is needed for <!> defaults and <?> documentation
data Opts w = Opts { demo :: w ::: Bool <!> "False"
                   , only :: w ::: String <!> "" <?> "native | tree | svg | babyl4 | corel4 | prolog | uppaal"
                   , dbug :: w ::: Bool <!> "False"
                   }
  deriving (Generic)
instance ParseRecord (Opts Wrapped)
deriving instance Show (Opts Unwrapped)


getConfig :: Opts Unwrapped -> IO RunConfig
getConfig o = do
  mpd <- lookupEnv "MP_DEBUG"
  mpj <- lookupEnv "MP_JSON"
  mpn <- lookupEnv "MP_NLG"
  return RC
        { debug = maybe (dbug o) (read :: String -> Bool) mpd
        , callDepth = 0
        , parseCallStack = []
        , sourceURL = "STDIN"
        , asJSON = maybe False (read :: String -> Bool) mpj
        , toNLG = maybe False (read :: String -> Bool) mpn
        , toBabyL4 = only o == "babyl4" || only o == "corel4"
        , toProlog = only o == "prolog"
        , toUppaal = only o == "uppaal"
        }



someFunc :: Opts Unwrapped -> IO ()
someFunc opts = do
  runConfig <- getConfig opts
  myinput <- BS.getContents
  runExample runConfig myinput

-- printf debugging infrastructure





runExample :: RunConfig -> ByteString -> IO ()
runExample rc str = forM_ (exampleStreams str) $ \stream ->
    case runMyParser id rc pToplevel "dummy" stream of
      Left bundle -> putStr (errorBundlePrettyCustom bundle)
      -- Left bundle -> putStr (errorBundlePretty bundle)
      -- Left bundle -> pPrint bundle
      Right ([], []) -> return ()
      Right (xs, xs') -> do
        let rules = xs ++ xs'
        when (asJSON rc) $
          putStrLn $ toString $ encodePretty rules
        when (toNLG rc) $ do
          naturalLangSents <- mapM nlg xs
          mapM_ (putStrLn . Text.unpack) naturalLangSents
        when (toBabyL4 rc) $ do
          pPrint $ sfl4ToCorel4 rules
--        when (toProlog rc) $ do
--          pPrint $ sfl4ToProlog rules
        when (toUppaal rc) $ do
          pPrint $ Uppaal.toL4TA rules
          putStrLn $ Uppaal.taSysToString $ Uppaal.toL4TA rules
        unless (asJSON rc || toBabyL4 rc || toNLG rc || toProlog rc) $
          pPrint rules

exampleStream :: ByteString -> MyStream
exampleStream s = case getStanzas <$> asCSV s of
                    Left errstr -> error errstr
                    Right rawsts -> stanzaAsStream (head rawsts)

exampleStreams :: ByteString -> [MyStream]
exampleStreams s = case getStanzas <$> asCSV s of
                    Left errstr -> error errstr
                    Right rawsts -> stanzaAsStream <$> rawsts

    -- the raw input looks like this:
dummySing :: ByteString
dummySing =
  -- ",,,,\n,EVERY,person,,\n,WHO,walks,// comment,continued comment should be ignored\n,AND,runs,,\n,AND,eats,,\n,AND,drinks,,\n,MUST,,,\n,->,sing,,\n"
  -- ",,,,\n,EVERY,person,,\n,WHO,eats,,\n,OR,drinks,,\n,MUST,,,\n,->,sing,,\n"
  ",,,,\n,EVERY,person,,\n,WHO,walks,// comment,continued comment should be ignored\n,AND,runs,,\n,AND,eats,,\n,OR,drinks,,\n,MUST,,,\n,->,sing,,\n"

indentedDummySing :: ByteString
indentedDummySing =
  ",,,,\n,EVERY,person,,\n,WHO,walks,,\n,AND,runs,,\n,AND,eats,,\n,OR,,drinks,\n,,AND,swallows,\n,MUST,,,\n,>,sing,,\n"


--
-- the desired output has type Rule
--


--
-- we begin by stripping comments and extracting the stanzas. Cassava gives us Vector Vector Text.
--

asBoxes :: RawStanza -> String
asBoxes _rs =
  render $ nullBox Box.<> nullBox Box.<> nullBox Box.<> Box.char 'a' Box.<> Box.char 'b' Box.<> Box.char 'c'


asCSV :: ByteString -> Either String RawStanza
asCSV s =
  let decoded = Cassava.decode Cassava.NoHeader s :: Either String RawStanza
  in preprocess decoded
  where
    preprocess :: Either String RawStanza -> Either String RawStanza
    preprocess x = do
      vvt <- x
      -- process // comments by setting all righter elements to empty.
      -- if we ever need to maximize efficiency we can consider rewriting this to not require a Vector -> List -> Vector trip.
      return $ rewriteDitto $ fmap trimLegalSource . trimComment False . V.toList <$> vvt
    -- ignore the () at the beginning of the line. Here it actually trims any (...) from any position but this is good enough for now
    trimLegalSource x = let asChars = Text.unpack x
                        in if not (null asChars)
                              && head asChars == '('
                              && last asChars == ')'
                           then ""
                           else x
    trimComment _       []                           = V.empty
    trimComment True  (_x:xs)                        = V.cons "" $ trimComment True xs
    trimComment False (x:xs) | Text.take 2 (Text.dropWhile (== ' ') x)
                               `elem` Text.words "// -- ##"
                                                     = trimComment True (x:xs) -- a bit baroque, why not just short-circuit here?
    trimComment False (x:xs)                         = V.cons x $ trimComment False xs

rewriteDitto :: V.Vector (V.Vector Text.Text) -> RawStanza
rewriteDitto vvt = V.imap (V.imap . rD) vvt
  where
    rD :: Int -> Int -> Text.Text -> Text.Text
    rD row col "\"" = -- first non-blank above
      let aboves = V.filter (`notElem` ["", "\""]) $ (! col) <$> V.slice 0 row vvt
      in if V.null aboves
         then error $ "line " ++ show (row+1) ++ " column " ++ show (col+1) ++ ": ditto lacks referent (upward nonblank cell)"
         else V.last aboves
    rD _   _   orig = orig


getStanzas :: RawStanza -> [RawStanza]
getStanzas rs = splitPilcrows `concatMap` chunks
  -- traceM ("getStanzas: extracted range " ++ (Text.unpack $ pShow toreturn))
  where chunks = getChunks rs

        -- traceStanzas xs = trace ("stanzas: " ++ show xs) xs

splitPilcrows :: RawStanza -> [RawStanza]
splitPilcrows rs = map (listsToStanza . transpose) splitted
  where
    listsToStanza = V.fromList . map V.fromList
    stanzaToLists = map V.toList . V.toList
    rst = transpose $ stanzaToLists rs
    splitted = (DLS.split . DLS.dropDelims . DLS.whenElt) (all (== "¶")) rst

-- highlight each chunk using range attribute.
-- method: cheat and use Data.List.Split's splitWhen to chunk on paragraphs separated by newlines
getChunks :: RawStanza -> [RawStanza]
getChunks rs = [rs]
  -- let listChunks = (DLS.split . DLS.keepDelimsR . DLS.whenElt) emptyRow [ 0 .. V.length rs - 1 ]
  --     containsMagicKeyword rowNr = V.any (`elem` magicKeywords) (rs ! rowNr)
  --     emptyRow rowNr = V.all Text.null (rs ! rowNr)
  --     wantedChunks = [ firstAndLast neRows
  --                    | rows <- listChunks
  --                    ,    any containsMagicKeyword rows
  --                      || all emptyRow rows
  --                    , Just neRows <- pure $ NE.nonEmpty rows
  --                    ]
  --     toreturn = extractLines rs <$> glueLineNumbers wantedChunks
  -- in -- trace ("getChunks: input = " ++ show [ 0 .. V.length rs - 1 ])
  --    -- trace ("getChunks: listChunks = " ++ show listChunks)
  --    -- trace ("getChunks: wantedChunks = " ++ show wantedChunks)
  --    -- trace ("getChunks: returning " ++ show (length toreturn) ++ " stanzas: " ++ show toreturn)
  -- toreturn

firstAndLast :: NonEmpty Int -> (Int, Int)
firstAndLast xs = (NE.head xs, NE.last xs)

-- because sometimes a chunk followed by another chunk is really part of the same chunk.
-- so we glue contiguous chunks together.
glueLineNumbers :: [(Int,Int)] -> [(Int,Int)]
glueLineNumbers ((a0, a1) : (b0, b1) : xs)
  | a1 + 1 == b0 = glueLineNumbers $ (a0, b1) : xs
  | otherwise = (a0, a1) : glueLineNumbers ((b0, b1) : xs)
glueLineNumbers [x] = [x]
glueLineNumbers [] = []

extractLines :: RawStanza -> (Int,Int) -> RawStanza
extractLines rs (y0, yLast) = V.slice y0 (yLast - y0 + 1) rs

vvlookup :: RawStanza -> (Int, Int) -> Maybe Text.Text
vvlookup rs (x,y) = rs !? y >>= (!? x)


-- gaze Down 1 (== "UNLESS") >> gaze rs Right 1





-- a multistanza is multiple stanzas separated by pilcrow symbols

-- a stanza is made up of:
--    a stanza head followed by
--      zero or more (one or more blank lines followed by
--                    a stanza fragment)
-- a stanza fragment is
--    a line starting with a BoolConnector or an IF
--    followed by one or more blank lines
--    followed by other keywords we recognize, like a MUST
-- a stanza head is
--    a group of lines where the left-most nonblank, noncitation, nonITIS column contains one of EVERY / WHEN / IF etc
--    or the leftmost nonblank, noncitation column is IT IS

--
-- putting the above together, we arrive at a MyStream object ready for proper parsing.
--

stanzaAsStream :: RawStanza -> MyStream
stanzaAsStream rs =
  let vvt = rs
  in 
  -- MyStream (Text.unpack $ decodeUtf8 s) [ WithPos {..}
  MyStream rs $ parenthesize [ WithPos {..}
             | y <- [ 0 .. V.length vvt       - 1 ]
             , x <- [ 0 .. V.length (vvt ! y) - 1 ]
             , let startPos = SourcePos "" (mkPos $ y + 1) (mkPos $ x + 1)
                   endPos   = SourcePos "" (mkPos $ y + 1) (mkPos $ x + 1) -- same
                   rawToken = vvt ! y ! x
                   tokenLength = 1
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1 & \r -> Debug.trace (show r) r
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1 & Debug.trace <$> show <*> id  -- same as above line, but with reader applicative
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1  -- without debugging
                   tokenVal = toToken rawToken
             , tokenVal `notElem` [ Empty, Checkbox ]
             ]
  where
    parenthesize :: [WithPos MyToken] -> [WithPos MyToken]
    parenthesize mys =
      tail . concat $ zipWith insertParen (withSOF:mys) (mys ++ [withEOF])
    withEOF = WithPos eofPos eofPos 1 EOF
    eofPos = SourcePos "" pos1 pos1
    withSOF = WithPos eofPos eofPos 1 SOF
    sofPos = SourcePos "" pos1 pos1
    insertParen a@WithPos {   endPos = aPos }
                b@WithPos { startPos = bPos }
      | aCol <  bCol =  a : replicate (bCol - aCol) goDp --- | foo | bar | -> | foo ( bar |
      | aCol >  bCol =  a : replicate (aCol - bCol) unDp --- |     | foo | 
      | otherwise    = [a]                               --- | bar |     | -> | foo ) bar |
      where
        aCol = unPos . sourceColumn $ aPos
        bCol = unPos . sourceColumn $ bPos
        goDp = b { tokenVal = GoDeeper }
        unDp = a { tokenVal = UnDeeper }
-- MyStream is the primary input for our Parsers below.
--

pToplevel :: Parser [Rule]
pToplevel = withDepth 0 $ do
  leftX  <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  myTraceM $ "topLevel: starting leftX is " ++ show leftX
  pRules <* eof

pRules :: Parser [Rule]
pRules = do
  wanted   <- many (try pRule)
  notarule <- optional pNotARule
  next <- ([] <$ eof) <|> pRules
  wantNotRules <- asks debug
  return $ wanted ++ next ++ if wantNotRules then maybeToList notarule else []

pNotARule :: Parser Rule
pNotARule = debugName "pNotARule" $ do
  myTraceM "pNotARule: starting"
  toreturn <- NotARule <$> many getTokenNonEOL <* optional dnl <* optional eof
  myTraceM "pNotARule: returning"
  return toreturn

-- the goal is tof return a list of Rule, which an be either regulative or constitutive:
pRule :: Parser Rule
pRule = do
  _ <- many dnl
  try (pRegRule <?> "regulative rule")
    <|> try (pTypeDefinition   <?> "ontology definition")
--  <|> try (pMeansRule <?> "nullary MEANS rule")
    <|> try (pConstitutiveRule <?> "constitutive rule")
    <|> try (pScenarioRule <?> "scenario rule")
    <|> try (pHornlike <?> "DECIDE ... IS ... Horn rule")
    <|> try (RuleGroup . Just <$> pRuleLabel <?> "standalone rule section heading")


pTypeDefinition :: Parser Rule
pTypeDefinition = debugName "pTypeDefinition" $ do
  (proto,g,u) <- permute $ (,,)
    <$$> defineLimb
    <|?> (Nothing, givenLimb)
    <|?> (Nothing, uponLimb)
  return $ proto { given = snd <$> g, upon = snd <$> u }
  where
    defineLimb = do
      _dtoken <- pToken Define
      name  <- pNameParens
      myTraceM $ "got name = " <> show name
      super <- optional pTypeSig
      myTraceM $ "got super = " <> show super
      _     <- optional dnl
      has   <- optional (id <$ pToken Has `indented1` some pTypeDefinition)
      myTraceM $ "got has = " <> show has
      enums <- optional pOneOf <* optional dnl
      myTraceM $ "got enums = " <> show enums
      return $ TypeDecl
        { name
        , super
        , has
        , enums
        , given = Nothing
        , upon = Nothing
        , rlabel  = noLabel
        , lsource = noLSource
        , srcref  = noSrcRef
        }

    givenLimb = debugName "pHornlike/givenLimb" $ Just <$> preambleParamText [Given]
    uponLimb  = debugName "pHornlike/uponLimb"  $ Just <$> preambleParamText [Upon]
--        X MEANS    Y
-- DECIDE X MEANS    Y
-- DEEM   X MEANS    Y
--          IS       Y
--          INCLUDES Y
--                     WHEN / IF
--                               GIVEN

pMeansRule :: Parser Rule
pMeansRule = debugName "pMeansRule" $ do
  leftY  <- lookAhead pYLocation
  leftX  <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing

  
  
  ((_d,d),gs,w,i,u,includes) <- permute $ (,,,,,)
    <$$> preambleParamText [Deem, Decide]
    <|?> ([], some $ preambleParamText [Given, Upon])
    <|?> ([], some $ preambleBoolStructR [When])
    <|?> ([], some $ preambleBoolStructR [If])
    <|?> ([], some $ preambleBoolStructR [Unless])
    <|?> ([], some $ preambleBoolStructP [Includes])

  -- let's extract the new term from the deem line
  let givens = concatMap (concatMap toList . toList . untypePT . snd) gs :: [Text.Text]
      dnew   = [ word | word <- concatMap toList $ toList (untypePT d), word `notElem` givens ]
  if length dnew /= 1
    then error "DEEM should identify exactly one term which was not previously found in the GIVEN line"
    else return $ Constitutive
         { name = dnew
         , keyword = Given
         , letbind = AA.Leaf $ RPParamText d
         , cond = addneg
                  (snd <$> mergePBRS (w<>i))
                  (snd <$> mergePBRS u)
         , given = nonEmpty $ foldMap toList (snd <$> gs)
         , rlabel = noLabel
         , lsource = noLSource
         , srcref = Just srcref
         }

pScenarioRule :: Parser Rule
pScenarioRule = debugName "pScenarioRule" $ do
  rlabel <- optional pRuleLabel
  leftY  <- lookAhead pYLocation -- this is the column where we expect IF/AND/OR etc.
  leftX  <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing
  (expects,givens) <- permute $ (,)
    <$$> some pExpect
    <|?> ([], pToken Given >> pGivens)
  return $ Scenario
    { scgiven = givens
    , expect  = expects
    , rlabel = rlabel, lsource = Nothing, srcref = Just srcref
    }

pExpect :: Parser HornClause
pExpect = debugName "pExpect" $ do
  _expect  <- pToken Expect
  expect   <- pRelationalPredicate
  whenpart <- optional pWhenPart
  _        <- dnl
  return $ HC
    { relPred = expect
    , relWhen = whenpart
    }
  where
    pWhenPart :: Parser HornBody
    pWhenPart = do
      _when   <- pToken When
      HBRP . AA.Leaf <$> pRelationalPredicate
      -- TODO: add support for more complex boolstructs of relational predicates
          
pGivens :: Parser [RelationalPredicate]
pGivens = debugName "pGiven" $ do
  some (pRelationalPredicate <* dnl)



pConstitutiveRule :: Parser Rule
pConstitutiveRule = debugName "pConstitutiveRule" $ do
  leftY              <- lookAhead pYLocation
  name               <- pNameParens
  leftX              <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.

  ( (copula, mletbind), whenifs, unlesses, givens ) <-
    withDepth leftX $ permutationsCon [Means,Includes] [When,If] [Unless] [Given]
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing

  return $ Constitutive
    { name = name
    , keyword = copula
    , letbind = mletbind
    , cond = addneg
             (snd <$> mergePBRS whenifs)
             (snd <$> mergePBRS unlesses)
    , given = nonEmpty $ foldMap toList (snd <$> givens)
    , rlabel = noLabel
    , lsource = noLSource
    , srcref = Just srcref
    }

pRegRule :: Parser Rule
pRegRule = debugName "pRegRule" $ do
  maybeLabel <- optional pRuleLabel
  tentative  <- (try pRegRuleSugary
                  <|> try pRegRuleNormal
                  <|> (pToken Fulfilled >> return RegFulfilled)
                  <|> (pToken Breach    >> return RegBreach)
                ) <* optional dnl
  return $ tentative { rlabel = maybeLabel }

-- "You MAY" has no explicit PARTY or EVERY keyword:
--
--  You MAY  BEFORE midnight
--       ->  eat a potato
--       IF  a potato is available
--
--  You MAY
--       ->  eat a potato
--   BEFORE  midnight
--       IF  a potato is available

pRegRuleSugary :: Parser Rule
pRegRuleSugary = debugName "pRegRuleSugary" $ do
  entityname         <- AA.Leaf . multiterm2pt <$> pNameParens            -- You
  leftX              <- lookAhead pXLocation
  let keynamewho = pure ((Party, entityname), Nothing)
  rulebody           <- withDepth leftX (permutationsReg keynamewho)
  -- TODO: refactor and converge the rest of this code block with Normal below
  henceLimb          <- optional $ pHenceLest Hence
  lestLimb           <- optional $ pHenceLest Lest
  let poscond = snd <$> mergePBRS (rbpbrs   rulebody)
  let negcond = snd <$> mergePBRS (rbpbrneg rulebody)
      toreturn = Regulative
                 { subj     = entityname
                 , keyword  = Party
                 , who      = Nothing
                 , cond     = (addneg poscond negcond)
                 , deontic  = (rbdeon rulebody)
                 , action   = (rbaction rulebody)
                 , temporal = (rbtemporal rulebody)
                 , hence    = henceLimb
                 , lest     = lestLimb
                 , rlabel   = Nothing -- rule label
                 , lsource  = Nothing -- legal source
                 , srcref   = Nothing -- internal SrcRef
                 , upon     = listToMaybe (snd <$> rbupon  rulebody)
                 , given    = (nonEmpty $ foldMap toList (snd <$> rbgiven rulebody))    -- given
                 , having   = (rbhaving rulebody)
                 }
  myTraceM $ "pRegRuleSugary: the positive preamble is " ++ show poscond
  myTraceM $ "pRegRuleSugary: the negative preamble is " ++ show negcond
  myTraceM $ "pRegRuleSugary: returning " ++ show toreturn
  return toreturn

-- EVERY   person
-- WHO     sings
--    AND  walks
-- MAY     eat a potato
-- BEFORE  midnight
-- IF      a potato is available
--    AND  the potato is not green

pRegRuleNormal :: Parser Rule
pRegRuleNormal = debugName "pRegRuleNormal" $ do
  let keynamewho = (,) <$> pActor [Every,Party,TokAll]
                   <*> optional (preambleBoolStructR [Who])
  rulebody <- permutationsReg keynamewho
  henceLimb                   <- optional $ pHenceLest Hence
  lestLimb                    <- optional $ pHenceLest Lest
  myTraceM $ "pRegRuleNormal: permutations returned rulebody " ++ show rulebody

  let poscond = snd <$> mergePBRS (rbpbrs   rulebody)
  let negcond = snd <$> mergePBRS (rbpbrneg rulebody)

  let toreturn = Regulative
                 { subj     = (snd $ rbkeyname rulebody)
                 , keyword  = (fst $ rbkeyname rulebody)
                 , who      = (snd <$> rbwho rulebody)
                 , cond     = (addneg poscond negcond)
                 , deontic  = (rbdeon rulebody)
                 , action   = (rbaction rulebody)
                 , temporal = (rbtemporal rulebody)
                 , hence    = henceLimb
                 , lest     = lestLimb
                 , rlabel   = Nothing -- rule label
                 , lsource  = Nothing -- legal source
                 , srcref   = Nothing -- internal SrcRef
                 , upon     = listToMaybe (snd <$> rbupon  rulebody)    -- given
                 , given    = (nonEmpty $ foldMap toList (snd <$> rbgiven rulebody))    -- given
                 , having   = (rbhaving rulebody)
                 }
  myTraceM $ "pRegRuleNormal: the positive preamble is " ++ show poscond
  myTraceM $ "pRegRuleNormal: the negative preamble is " ++ show negcond
  myTraceM $ "pRegRuleNormal: returning " ++ show toreturn
  -- let appendix = pbrs ++ nbrs ++ ebrs ++ defalias
  -- myTraceM $ "pRegRuleNormal: with appendix = " ++ show appendix
  -- return ( toreturn : appendix )
  return toreturn

-- this is probably going to need cleanup
addneg :: Maybe BoolStructR -> Maybe BoolStructR -> Maybe BoolStructR
addneg Nothing  Nothing   = Nothing
addneg Nothing  (Just n)  = Just $ AA.Not n
addneg (Just p) (Just n)  = Just $ AA.All Nothing [p, AA.Not n]
addneg (Just p) Nothing   = Just p

pHenceLest :: MyToken -> Parser Rule
pHenceLest henceLest = debugName ("pHenceLest-" ++ show henceLest) $ do
  id <$ pToken henceLest `indented1` (try pRegRule <|> RuleAlias <$> (pOtherVal <* dnl))


-- combine all the boolrules under the first preamble keyword
mergePBRS :: [(Preamble, BoolStructR)] -> Maybe (Preamble, BoolStructR)
mergePBRS [] = Nothing
mergePBRS [x] = Just x
mergePBRS xs         = Just (fst . head $ xs, AA.All Nothing (snd <$> xs))

pTemporal :: Parser (Maybe (TemporalConstraint Text.Text))
pTemporal = eventually <|> specifically <|> vaguely
  where
    eventually   = mkTC <$> pToken Eventually <*> pure 0 <*> pure ""
    specifically = mkTC <$> sometime          <*> pNumber <*> pOtherVal
    sometime     = choice $ map pToken [ Before, After, By, On ]
    vaguely      = Just . TemporalConstraint TVague 0 <$> pOtherVal

pPreamble :: [MyToken] -> Parser Preamble
pPreamble toks = choice (try . pToken <$> toks)

-- "PARTY Bob       AKA "Seller"
-- "EVERY Seller"
pActor :: [MyToken] -> Parser (Preamble, BoolStructP)
pActor keywords = debugName ("pActor " ++ show keywords) $ do
  -- add pConstitutiveRule here -- we could have "MEANS"
  preamble     <- pPreamble keywords
  entitytype   <- lookAhead pNameParens
  let boolEntity = AA.Leaf $ multiterm2pt entitytype
  omgARule <- pure <$> try pConstitutiveRule <|> (mempty <$ pNameParens)
  myTraceM $ "pActor: omgARule = " ++ show omgARule
  tell $ listToDL omgARule
  return (preamble, boolEntity)

-- Every man AND woman     AKA Adult
--       MEANS human
--         AND age >= 21
--  MUST WITHIN 200 years
--    -> die

-- support name-like expressions tagged with AKA, which means "also known as"
-- sometimes we want a plain Text.Text
pNameParens :: Parser RuleName
pNameParens = pMultiTermParens

-- sometimes we want a ParamText
pPTParens :: Parser ParamText
pPTParens = debugName "pPTParens" $ pAKA pParamText pt2multiterm

-- sometimes we want a multiterm
pMultiTermParens :: Parser MultiTerm
pMultiTermParens = debugName "pMultiTermParens" $ pAKA pMultiTerm id

-- utility function for the above
pAKA :: (Show a) => Parser a -> (a -> MultiTerm) -> Parser a
pAKA baseParser toMultiTerm = debugName "pAKA" $ do
  base <- baseParser
  let detail = toMultiTerm base
  leftY       <- lookAhead pYLocation
  leftX       <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  entityalias <- optional $ try (optional dnl *> pToken Aka *> some pOtherVal) -- ("MegaCorp")
  _           <- optional dnl
  -- myTraceM $ "pAKA: entityalias = " ++ show entityalias
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing
  let defalias = maybe mempty (\t -> singeltonDL (DefNameAlias t detail Nothing (Just srcref))) entityalias
  tell defalias
  return base
  

pDoAction ::  Parser BoolStructP
pDoAction = pToken Do >> pAction


pAction :: Parser BoolStructP
pAction = dBoolStructP


-- we create a permutation parser returning one or more RuleBodies, which we treat as monoidal,
-- though later we may object if there is more than one.

mkRBfromDT :: BoolStructP
           -> ((Preamble, BoolStructP )  -- every person
              ,Maybe (Preamble, BoolStructR)) -- who is red and blue
           -> (Deontic, Maybe (TemporalConstraint Text.Text))
           -> [(Preamble, BoolStructR)] -- positive  -- IF / WHEN
           -> [(Preamble, BoolStructR)] -- negative  -- UNLESS
           -> [(Preamble, ParamText )] -- upon  conditions
           -> [(Preamble, ParamText )] -- given conditions
           -> Maybe ParamText          -- having
           -> RuleBody
mkRBfromDT rba (rbkn,rbw) (rbd,rbt) rbpb rbpbneg rbu rbg rbh = RuleBody rba rbpb rbpbneg rbd rbt rbu rbg rbh rbkn rbw

mkRBfromDA :: (Deontic, BoolStructP)
           -> ((Preamble, BoolStructP ) -- every person or thing
              ,Maybe (Preamble, BoolStructR)) -- who is red and blue
           -> Maybe (TemporalConstraint Text.Text)
           -> [(Preamble, BoolStructR)] -- whenif
           -> [(Preamble, BoolStructR)] -- unless
           -> [(Preamble, ParamText )] -- upon  conditions
           -> [(Preamble, ParamText )] -- given conditions
           -> Maybe ParamText         -- having
           -> RuleBody
mkRBfromDA (rbd,rba) (rbkn,rbw) rbt rbpb rbpbneg rbu rbg rbh = RuleBody rba rbpb rbpbneg rbd rbt rbu rbg rbh rbkn rbw

-- bob's your uncle
-- MEANS
--    bob's your mother's brother
-- OR bob's your father's mother

permutationsCon :: [MyToken] -> [MyToken] -> [MyToken] -> [MyToken]
                           -- preamble = copula   (means,deem,decide)
                -> Parser (  (Preamble, BoolStructR)  -- body of horn clause
                          , [(Preamble, BoolStructR)] -- positive conditions (when,if)
                          , [(Preamble, BoolStructR)] -- negative conditions (unless)
                          , [(Preamble, ParamText)] -- given    (given params)
                          )
permutationsCon copula ifwhen l4unless l4given =
  debugName ("permutationsCon"
             <> ": copula="   <> show copula
             <> ", positive=" <> show ifwhen
             <> ", negative=" <> show l4unless
             <> ", given="    <> show l4given
            ) $ do
  permute $ (,,,)
    <$$>             preambleBoolStructR copula
    <|?> ([], some $ preambleBoolStructR ifwhen)
    <|?> ([], some $ preambleBoolStructR l4unless)
    <|?> ([], some $ preambleParamText l4given)

-- degustates
--     MEANS eats
--        OR drinks
--      WHEN weekend

preambleParamText :: [MyToken] -> Parser (Preamble, ParamText)
preambleParamText preambles = do
  preamble <- choice (try . pToken <$> preambles)
  paramtext <- pPTParens -- pPTParens is a bit awkward here because of the multiline possibility of a paramtext
  return (preamble, paramtext)

preambleRelPred :: [MyToken] -> Parser (Preamble, RelationalPredicate)
preambleRelPred preambles = do
  preamble <- choice (try . pToken <$> preambles)
  relpred  <- pRelationalPredicate
  return (preamble, relpred)

permutationsReg :: Parser ((Preamble, BoolStructP), Maybe (Preamble, BoolStructR))
                -> Parser RuleBody
permutationsReg keynamewho =
  debugName "permutationsReg" $ do
  try ( debugName "regulative permutation with deontic-temporal" $ permute ( mkRBfromDT
            <$$> pDoAction
            <||> keynamewho
            <||> try pDT
            <&&> whatnot
          ) )
  <|>
  try ( debugName "regulative permutation with deontic-action" $ permute ( mkRBfromDA
            <$$> try pDA
            <||> keynamewho
            <|?> (Nothing, pTemporal <* dnl)
            <&&> whatnot
          ) )
  where
    whatnot x = x
                <|?> ([], some $ preambleBoolStructR [When, If])   -- syntactic constraint, all the if/when need to be contiguous.
                <|?> ([], some $ preambleBoolStructR [Unless]) -- unless
                <|?> ([], some $ preambleParamText [Upon])   -- upon
                <|?> ([], some $ preambleParamText [Given])  -- given
                <|?> (Nothing, Just . snd <$> preambleParamText [Having])  -- having

    (<&&>) = flip ($) -- or we could import Data.Functor ((&))
    infixl 1 <&&>

-- the Deontic/temporal/action form
-- MAY EVENTUALLY
--  -> pay
pDT :: Parser (Deontic, Maybe (TemporalConstraint Text.Text))
pDT = debugName "pDT" $ do
  pd <- pDeontic
  pt <- optional pTemporal <* dnl
  return (pd, fromMaybe Nothing pt)

-- the Deontic/Action/Temporal form
pDA :: Parser (Deontic, BoolStructP)
pDA = debugName "pDA" $ do
  pd <- pDeontic
  pa <- pAction
  return (pd, pa)

preambleBoolStructP :: [MyToken] -> Parser (Preamble, BoolStructP)
preambleBoolStructP wanted = debugName ("preambleBoolStructP " <> show wanted)  $ do
  leftX     <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  condWord <- choice (try . pToken <$> wanted)
  myTraceM ("preambleBoolStructP: found: " ++ show condWord)
  ands <- withDepth leftX dBoolStructP -- (foo AND (bar OR baz), [constitutive and regulative sub-rules])
  return (condWord, ands)



-- a BoolStructR is the new ombibus type for the WHO and COND keywords,
-- being an AnyAll tree of RelationalPredicates.


preambleBoolStructR :: [MyToken] -> Parser (Preamble, BoolStructR)
preambleBoolStructR wanted = debugName ("preambleBoolStructR " <> show wanted)  $ do
  leftX     <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  condWord <- choice (try . pToken <$> wanted)
  myTraceM ("preambleBoolStructR: found: " ++ show condWord ++ " at depth " ++ show leftX)
  ands <- withDepth leftX pBoolStructR -- (foo AND (bar OR baz), [constitutive and regulative sub-rules])
  return (condWord, ands)

-- let's do a nested and/or tree for relational predicates, not just boolean predicate structures
pBoolStructR :: Parser BoolStructR
pBoolStructR = debugName "pBoolStructR" $ do
  (ands,unlesses) <- permute $ (,)
    <$$> Just <$> rpAndGroup
    <|?> (Nothing, Just <$> rpUnlessGroup)
  return $ fromJust $ addneg ands unlesses

rpUnlessGroup :: Parser BoolStructR
rpUnlessGroup = debugName "rpUnlessGroup" $ do
  leftX     <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  pToken Unless *> withDepth (leftX + 1) rpAndGroup

rpAndGroup :: Parser BoolStructR
rpAndGroup = debugName "rpAndGroup" $ do
    rpOrGroup1 <- rpOrGroup <* optional dnl
    rpOrGroupN <- many $ pToken And *> rpOrGroup
    let toreturn = if null rpOrGroupN
                   then rpOrGroup1
                   else AA.All Nothing (rpOrGroup1 : rpOrGroupN)
    return toreturn

rpOrGroup :: Parser BoolStructR
rpOrGroup = debugName "rpOrGroup" $ do
  depth <- asks callDepth
  elem1    <- withDepth (depth + 0) rpElement <* optional dnl
  elems    <- many $ pToken Or *> withDepth (depth+0) rpElement
  let toreturn = if null elems
                 then elem1
                 else AA.Any Nothing (elem1 : elems)
  return toreturn

-- i think we're going to need an rpUnlessGroup as well

rpElement :: Parser BoolStructR
rpElement = debugName "rpElement" $ do
  try (rpConstitutiveAsElement <$> tellIdFirst pConstitutiveRule)
    <|> do
    rpAtomicElement
  
rpAtomicElement :: Parser BoolStructR
rpAtomicElement = debugName "rpAtomicElement" $ do
  try rpNotElement
  <|> try rpNestedBool
  <|> rpLeafVal






rpConstitutiveAsElement :: Rule -> BoolStructR
rpConstitutiveAsElement = multiterm2bsr

rpNotElement :: Parser BoolStructR
rpNotElement = debugName "rpNotElement" $ do
  inner <- id <$ pToken MPNot `indented0` dBoolStructR
  return $ AA.Not inner

rpLeafVal :: Parser BoolStructR
rpLeafVal = debugName "rpLeafVal" $ do
  leafVal <- pRelationalPredicate
  myTraceM $ "rpLeafVal returning " ++ show leafVal
  return $ AA.Leaf leafVal



rpNestedBool :: Parser BoolStructR
rpNestedBool = debugName "rpNestedBool" $ do
  depth <- asks callDepth
  debugPrint $ "rpNestedBool lookahead looking for some pBoolConnector"
  (leftX,foundBool) <- lookAhead (rpLeafVal >> optional dnl >> (,) <$> lookAhead pXLocation <*> pBoolConnector)
  myTraceM $ "rpNestedBool lookahead matched " ++ show foundBool ++ " at location " ++ show leftX ++ "; testing if leftX " ++ show leftX ++ " > depth " ++ show depth
  guard (leftX > depth)
  myTraceM $ "rpNestedBool lookahead matched " ++ show foundBool ++ " at location " ++ show leftX ++ "; rewinding for dBoolStructR to capture."
  withDepth (leftX + 0) dBoolStructR
  
dBoolStructR :: Parser BoolStructR
dBoolStructR = debugName "dBoolStructR" $ do
  rpAndGroup






dBoolStructP ::  Parser BoolStructP
dBoolStructP = debugName "dBoolStructP" $ do
  pAndGroup -- walks AND eats OR drinks

pAndGroup ::  Parser BoolStructP
pAndGroup = debugName "pAndGroup" $ do
  orGroup1 <- pOrGroup
  orGroupN <- many $ pToken And *> pOrGroup
  let toreturn = if null orGroupN
                 then orGroup1
                 else AA.All Nothing (orGroup1 : orGroupN)
  return toreturn

pOrGroup ::  Parser BoolStructP
pOrGroup = debugName "pOrGroup" $ do
  depth <- asks callDepth
  elem1    <- withDepth (depth + 1) pElement
  elems    <- many $ pToken Or *> withDepth (depth+1) pElement
  let toreturn = if null elems
                 then elem1
                 else AA.Any Nothing (elem1 : elems)
  return toreturn

pAtomicElement ::  Parser BoolStructP
pAtomicElement = debugName "pAtomicElement" $ do
  try pNestedBool
    <|> pNotElement
    <|> pLeafVal

pElement :: Parser BoolStructP
pElement = debugName "pElement" $ do
        try (constitutiveAsElement <$> tellIdFirst pConstitutiveRule)
    <|> pAtomicElement

-- | Like `\m -> do a <- m; tell [a]; return a` but add the value before the child elements instead of after
tellIdFirst :: (Functor m) => WriterT (DList w) m w -> WriterT (DList w) m w
tellIdFirst = mapWriterT . fmap $ \(a, m) -> (a, singeltonDL a <> m)

-- Makes a leaf with just the name of a constitutive rule
constitutiveAsElement ::  Rule -> BoolStructP
constitutiveAsElement cr = AA.Leaf $ multiterm2pt $ name cr

pNotElement :: Parser BoolStructP
pNotElement = debugName "pNotElement" $ do
  depth <- asks callDepth
  inner <- pToken MPNot *> withDepth (depth+1) pElement
  return $ AA.Not inner

pLeafVal ::  Parser BoolStructP
pLeafVal = debugName "pLeafVal" $ do
  leafVal <- pParamText
  myTraceM $ "pLeafVal returning " ++ show leafVal
  return $ AA.Leaf leafVal

-- TODO: we should be able to get rid of pNestedBool and just use a recursive call into dBoolStructP without pre-checking for a pBoolConnector. Refactor when the test suite is a bit more comprehensive.

pNestedBool ::  Parser BoolStructP
pNestedBool = debugName "pNestedBool" $ do
  -- "foo AND bar" is a nestedBool; but just "foo" is a leafval.
  (leftX,foundBool) <- lookAhead (pLeafVal >> optional dnl >> (,) <$> lookAhead pXLocation <*> pBoolConnector)
  myTraceM $ "pNestedBool matched " ++ show foundBool ++ " at location " ++ show leftX
  withDepth leftX dBoolStructP

pBoolConnector :: Parser MyToken
pBoolConnector = debugName "pBoolConnector" $ do
  pToken And <|> pToken Or <|> pToken Unless <|> pToken MPNot

-- helper functions for parsing

anything :: Parser [WithPos MyToken]
anything = many anySingle


--              X   IS    your relative
-- MEANS   NOT  X   IS    estranged
--          OR  X   IS    dead

-- becomes prolog
-- yourRelative(X) :- \+ (estranged(X), dead(X)).

-- Hornlike "X is your relative"
--          Means
-- no given
-- no upon
-- clauses: [ HC2 { hHead = RPConstraint ["X"] RPis ["your uncle"]
--                  hBody = Just $ AA.Not ( AA.Any Nothing [ RPConstraint ["X"] RPis ["estranged"]
--                                                         , RPConstraint ["X"] RPis ["dead"] ] ) } ]
-- rlabel lsource srcref  

-- the informal version:
-- hHead = RPParamText "Bob's your uncle"
-- hBody = Just $ AA.Not ( AA.Any Nothing [ RPParamText ["Bob is estranged"]
--                                        , RPParamText ["Bob is dead"] ] )

pHornlike :: Parser Rule
pHornlike = debugName "pHornlike" $ do
  (rlabel, srcref) <- pSrcRef
  ((keyword, name, clauses), given, upon) <- permute $ (,,)
    <$$> try moreStructure <|> lessStructure
    <|?> (Nothing, fmap snd <$> optional givenLimb)
    <|?> (Nothing, fmap snd <$> optional uponLimb)
  return $ Hornlike { name
                    , keyword = fromMaybe Means keyword
                    , given, clauses, upon, rlabel, srcref
                    , lsource = noLSource }
  where
    -- this is actually kind of a meta-rule, because it really means
    -- assert(X :- (Y1, Y2)) :- body.
    
    whenMeansIf = choice [ pToken When, pToken Means, pToken If ]
    whenCase = debugName "whenCase" $ whenMeansIf *> (Just <$> pBoolStructR) <|> Nothing <$ pToken Otherwise

    -- DECIDE x IS y WHEN Z IS Q

    moreStructure = debugName "pHornlike/moreStructure" $ do
      keyword <- optional $ choice [ pToken Define, pToken Decide ]
      (((firstWord,rel),rhs),body) <- pNameParens
                                             `indentedTuple0` choice [ RPelem <$ pToken Includes
                                                                     , RPis   <$ pToken Is ]
                                             `indentedTuple0` pBoolStructR
                                             `indentedTuple0` optional whenCase
      let hhead = case rhs of
            AA.Leaf (RPParamText ((y,Nothing) :| [])) -> RPConstraint  firstWord rel (toList y)
            _                                         -> RPBoolStructR firstWord rel rhs
      return (keyword, firstWord, [HC2 hhead (fromMaybe Nothing body)])

    lessStructure = debugName "pHornlike/lessStructure" $ do
      keyword <- optional $ choice [ pToken Define, pToken Decide ]
      (firstWord,body) <- pNameParens `indentedTuple0` whenCase
      return (keyword, firstWord, [HC2 (RPParamText (multiterm2pt firstWord)) body])


    givenLimb = debugName "pHornlike/givenLimb" $ preambleParamText [Given]
    uponLimb  = debugName "pHornlike/uponLimb"  $ preambleParamText [Upon]
      
  

pHornClause2 :: Parser HornClause2
pHornClause2 = do
  hhead <- pHornHead2
  _when <- pToken When
  hbody <- pHornBody2
  return $ HC2 hhead (Just hbody)

pHornHead2 :: Parser RelationalPredicate
pHornHead2 = pRelationalPredicate

pHornBody2 :: Parser BoolStructR
pHornBody2 = pBoolStructR

