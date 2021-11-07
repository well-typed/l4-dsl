{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE TypeFamilies      #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE NamedFieldPuns #-}

module L4.Lib where

-- import qualified Data.Tree      as Tree
import qualified Data.Text.Lazy as Text
-- import Data.Text.Lazy.Encoding (decodeUtf8)
import Text.Megaparsec
import qualified Data.Set           as Set
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString)
import qualified Data.Csv as Cassava
import qualified Data.Vector as V
import Generic.Data (Generic)
import Data.Vector ((!), (!?))
import Data.Maybe (fromMaybe, catMaybes)
import Text.Pretty.Simple (pPrint)
import qualified AnyAll as AA
import qualified Text.PrettyPrint.Boxes as Box
import           Text.PrettyPrint.Boxes hiding ((<>))
import System.Environment (lookupEnv)
import qualified Data.ByteString.Lazy as BS
import qualified Data.List.Split as DLS
import Text.Parser.Permutation
import Debug.Trace
import Data.Aeson.Encode.Pretty
import Data.List.NonEmpty (NonEmpty ((:|)))

import L4.Types
import L4.Error ( errorBundlePrettyCustom )
import L4.NLG (nlg)
import Control.Monad.Reader (asks, local)
import Control.Monad.Writer.Lazy

-- our task: to parse an input CSV into a collection of Rules.
-- example "real-world" input can be found at https://docs.google.com/spreadsheets/d/1qMGwFhgPYLm-bmoN2es2orGkTaTN382pG2z3RjZ_s-4/edit

getConfig :: IO RunConfig
getConfig = do
  mpd <- lookupEnv "MP_DEBUG"
  mpj <- lookupEnv "MP_JSON"
  mpn <- lookupEnv "MP_NLG"
  return RC
        { debug = maybe False (read :: String -> Bool) mpd
        , callDepth = 0
        , parseCallStack = []
        , sourceURL = "STDIN"
        , asJSON = maybe False (read :: String -> Bool) mpj
        , toNLG = maybe False (read :: String -> Bool) mpn
        }

someFunc :: IO ()
someFunc = do
  runConfig <- getConfig
  myinput <- BS.getContents
  runExample runConfig myinput

-- printf debugging infrastructure

whenDebug :: Parser () -> Parser ()
whenDebug act = do
  isDebug <- asks debug
  when isDebug act

myTraceM :: String -> Parser ()
myTraceM x = whenDebug $ do
  callDepth <- asks nestLevel
  traceM $ indentShow callDepth <> x
  where
    indentShow depth = concat $ replicate depth "| "

debugPrint :: String -> Parser ()
debugPrint str = whenDebug $ do
  lookingAt <- lookAhead (getToken :: Parser MyToken)
  depth <- asks callDepth
  myTraceM $ "/ " <> str <> " running. depth=" <> show depth <> "; looking at: " <> show lookingAt

-- force debug=true for this subpath
alwaysdebugName :: Show a => String -> Parser a -> Parser a
alwaysdebugName name p = local (\rc -> rc { debug = True }) $ debugName name p

debugName :: Show a => String -> Parser a -> Parser a
debugName name p = do
  debugPrint name
  res <- local (increaseNestLevel name) p
  myTraceM $ "\\ " <> name <> " has returned " <> show res
  return res

-- | withDepth n p sets the depth to n for parser p
withDepth :: Depth -> Parser a -> Parser a
withDepth n = local (\st -> st {callDepth= n})

runExample :: RunConfig -> ByteString -> IO ()
runExample rc str = forM_ (exampleStreams str) $ \stream ->
    case runMyParser id rc pRule "dummy" stream of
      Left bundle -> putStr (errorBundlePrettyCustom bundle)
      -- Left bundle -> putStr (errorBundlePretty bundle)
      -- Left bundle -> pPrint bundle
      Right ([], []) -> return ()
      Right (xs, xs') -> do
        when (asJSON rc) $
          putStrLn $ toString $ encodePretty (xs ++ xs')
        when (toNLG rc) $ do
          naturalLangSents <- mapM nlg xs
          mapM_ (putStrLn . Text.unpack) naturalLangSents
        unless (asJSON rc) $
          pPrint $ xs ++ xs'

exampleStream :: ByteString -> MyStream
exampleStream s = case getStanzas (asCSV s) of
                    Left errstr -> error errstr
                    Right rawsts -> stanzaAsStream s (head rawsts)

exampleStreams :: ByteString -> [MyStream]
exampleStreams s = case getStanzas (asCSV s) of
                    Left errstr -> error errstr
                    Right rawsts -> stanzaAsStream s <$> rawsts

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
      return $ trimComment False . V.toList <$> vvt
    trimComment _       []                           = V.empty
    trimComment True  (_x:xs)                        = V.cons "" $ trimComment True xs
    trimComment False (x:xs) | Text.take 2 (Text.dropWhile (== ' ') x)
                               `elem` Text.words "// -- ##"
                                                     = trimComment True (x:xs) -- a bit baroque, why not just short-circuit here?
    trimComment False (x:xs)                         = V.cons x $ trimComment False xs

getStanzas :: Monad m => m RawStanza -> m [RawStanza]
getStanzas esa = do
  rs <- esa
  let chunks = getChunks $ Location rs (0,0) ((0,0),(V.length (rs ! (V.length rs - 1)) - 1, V.length rs - 1))
      toreturn = extractRange <$> glueChunks chunks
  -- traceM ("getStanzas: extracted range " ++ (Text.unpack $ pShow toreturn))
  return toreturn

-- because sometimes a chunk followed by another chunk is really part of the same chunk.
-- so we glue contiguous chunks together.
glueChunks :: [Location] -> [Location]
glueChunks (a:b:z) =
  let (( lxa,lya),(_rxa,rya)) = range a
      ((_lxb,lyb),( rxb,ryb)) = range b
  in
    if rya + 1 == lyb
    then glueChunks $ a { range = ((lxa, lya),(rxb,ryb)) } : z
    else a : glueChunks (b : z)
glueChunks x = x

-- highlight each chunk using range attribute.
-- method: cheat and use Data.List.Split's splitWhen to chunk on paragraphs separated by newlines
getChunks :: Location -> [Location]
getChunks loc@(Location rs (_cx,_cy) ((_lx,_ly),(_rx,ry))) =
  let listChunks = (DLS.split . DLS.keepDelimsR . DLS.whenElt) (\i -> V.all Text.null $ rs ! i) [ 0 .. ry ]
      wantedChunks = [ rows
                     | rows <- listChunks
                     , any (\row ->
                               V.any (`elem` magicKeywords)
                               (rs ! row)
                           ) rows
                       ||
                       all (\row -> V.all Text.null (rs ! row))
                       rows
                     ]
      toreturn = setRange loc <$> filter (not . null) wantedChunks
  in -- trace ("getChunks: input = " ++ show [ 0 .. ry ])
     -- trace ("getChunks: listChunks = " ++ show listChunks)
     -- trace ("getChunks: wantedChunks = " ++ show wantedChunks)
     -- trace ("getChunks: returning " ++ show (length toreturn) ++ " stanzas: " ++ show toreturn)
     toreturn

-- is the cursor on a line that has nothing in it?
blankLine :: Location -> Bool
blankLine loc = all Text.null $ currentLine loc

extractRange :: Location -> RawStanza
extractRange (Location rawStanza _cursor ((lx,ly),(rx,ry))) =
  let slicey = -- trace ("extractRange: given rawStanza " ++ show rawStanza)
               -- trace ("extractRange: trying to slice " ++ show xy)
               -- trace ("extractRange: trying to slice y " ++ show (ly, ry-ly+1))
               V.slice ly (ry-ly+1) rawStanza
      slicex = -- trace ("extractRange: got slice y " ++ show slicey)
               -- trace ("extractRange: trying to slice x " ++ show (lx, rx-lx+1))
               V.slice lx (rx-lx+1) <$> slicey
  in -- trace ("extractRange: got slice x " ++ show slicex)
     slicex

setRange :: Location -> [Int] -> Location
setRange loc@(Location _rawStanza _c ((_lx,_ly),(_rx,_ry))) ys =
  let cursorToEndLine  = moveTo loc (0,       last ys)
      lineLen = lineLength cursorToEndLine - 1
      cursorToEndRange = moveTo loc (lineLen, last ys)
  in -- trace ("setRange: loc = " ++ show loc)
     -- trace ("setRange: ys = " ++ show ys)
     loc { cursor =  (0,head ys)
         , range  = ((0,head ys),cursor cursorToEndRange) }

data Location = Location
                { rawStanza :: RawStanza
                , cursor    :: (Int,Int)
                , range     :: ((Int,Int),(Int,Int))
                } deriving (Eq, Show)
data Direction = N | E | S | W deriving (Eq, Show)
type Distance = Int

matches :: Location -> Direction -> Distance -> (Text.Text -> Bool) -> [Text.Text]
matches loc dir dis f = getCurrentCell <$> searchIn loc dir dis f

searchIn :: Location -> Direction -> Distance -> (Text.Text -> Bool) -> [Location]
searchIn loc dir dis f = filter (f . getCurrentCell) $ getRange loc dir dis

getRange :: Location -> Direction -> Distance -> [Location]
getRange loc dir dis = [ move loc dir n | n <- [ 1 .. dis ] ]

toEOL :: Location -> [Location]
toEOL loc = [ move loc E n | n <- [ 1 .. lineRemaining loc ] ]

currentLine :: Location -> [Text.Text]
currentLine loc = getCurrentCell <$> toEOL (lineStart loc)

lineStart :: Location -> Location
lineStart loc = loc { cursor = (0, curY loc) }

lineRemaining :: Location -> Distance
lineRemaining loc = lineLength loc - curX loc - 1

lineLength :: Location -> Distance
lineLength loc = let (_cx, cy) = cursor loc in V.length (rawStanza loc ! cy)

curX, curY :: Location -> Int
curX (Location _ (cx,_) _) = cx
curY (Location _ (_,cy) _) = cy

moveTo :: Location -> (Int,Int) -> Location
moveTo loc c = loc { cursor = c }

move :: Location -> Direction -> Distance -> Location
move loc dir dis = do
  let (cx, cy) = cursor loc
      newCursor = case dir of
                    E -> (cx + dis, cy + 000)
                    S -> (cx + 000, cy + dis)
                    W -> (cx - dis, cy + 000)
                    N -> (cx + 000, cy - dis)
  loc { cursor = newCursor }

getCurrentCell :: Location -> Text.Text
getCurrentCell loc = fromMaybe "" (vvlookup (rawStanza loc) (cursor loc))

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

stanzaAsStream :: ByteString -> RawStanza -> MyStream
stanzaAsStream _s rs = do
  let vvt = rs
  -- MyStream (Text.unpack $ decodeUtf8 s) [ WithPos {..}
  MyStream rs [ WithPos {..}
             | y <- [ 0 .. V.length vvt - 1 ]
             , x <- [ 0 .. V.length (vvt ! y) + 0 ] -- we append a fake ";" token at the end of each line to represent EOL
             , let startPos = SourcePos "" (mkPos $ y + 1) (mkPos $ x + 1)
                   endPos   = SourcePos "" (mkPos $ y + 1) (mkPos $ x + 1) -- same
                   rawToken = if x == V.length (vvt ! y) then ";" else vvt ! y ! x
                   tokenLength = 1
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1 & \r -> Debug.trace (show r) r
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1 & Debug.trace <$> show <*> id  -- same as above line, but with reader applicative
                  --  tokenLength = fromIntegral $ Text.length rawToken + 1  -- without debugging
                   tokenVal = toToken rawToken
             , tokenVal `notElem` [ Empty, Checkbox ]
             ]

-- deriving (Eq, Ord, Show)

--
-- MyStream is the primary input for our Parsers below.
--

-- the goal is tof return a list of Rule, which an be either regulative or constitutive:
pRule :: Parser [Rule]
pRule = withDepth 1 $ do
  _ <- optional dnl
  try ((:[]) <$> pRegRule <?> "regulative rule")
    <|> try ((:[]) <$> pConstitutiveRule <?> "constitutive rule")
    <|> ((:[]) <$ pToken Define `indented0` pTypeDefinition   <?> "ontology definition")
    <|> (eof >> return [])

pTypeSig :: Parser TypeSig
pTypeSig = debugName "pTypeSig" $ do
  _           <- pToken TypeSeparator <|> pToken Is
  simpletype <|> inlineenum
  where
    simpletype = do
      cardinality <- optional $ choice [ TOne      <$ pToken One
                                       , TOne      <$ pToken A_An
                                       , TOptional <$ pToken Optional
                                       , TList0    <$ pToken List0
                                       , TList1    <$ pToken List1 ]
      base        <- pOtherVal <* dnl
      return $ SimpleType (fromMaybe TOne cardinality) base
    inlineenum = do
      InlineEnum TOne <$> pOneOf

pOneOf :: Parser ParamText
pOneOf = id <$ pToken OneOf `indented0` pParamText

pTypeDefinition :: Parser Rule
pTypeDefinition = debugName "pTypeDefinition" $ do
  name  <- pOtherVal
  myTraceM $ "got name = " <> Text.unpack name
  super <- optional pTypeSig
  myTraceM $ "got super = " <> show super
  _     <- optional dnl
  has   <- optional (id <$ pToken Has `indented1` many ( (,) <$> pOtherVal <*> pTypeSig))
  myTraceM $ "got has = " <> show has
  enums <- optional pOneOf
  myTraceM $ "got enums = " <> show enums

  return $ TypeDecl
    { name
    , super
    , has
    , enums
    , rlabel  = noLabel
    , lsource = noLSource
    , srcref  = noSrcRef
    }

pConstitutiveRule :: Parser Rule
pConstitutiveRule = debugName "pConstitutiveRule" $ do
  leftY              <- lookAhead pYLocation
  (name,namealias)   <- pNameParens
  leftX              <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing
  let defalias = maybe mempty (\t -> singeltonDL (DefNameAlias t name Nothing (Just srcref))) namealias
  tell defalias

  ( (_meansis, posp), unlesses, givens ) <-
    withDepth leftX $ permutationsCon [Means,Is,Includes,When] [Unless] [Given] -- maybe this given needs to be Having, think about replacing it later.

  let (_unless, negp) = mergePBRS posp -- WIP, complete the refactoring!
      givenpts = snd <$> givens

  return $ Constitutive name (addneg posp negp) givenpts noLabel noLSource noSrcRef

pRegRule :: Parser Rule
pRegRule = debugName "pRegRule" $
  (try pRegRuleSugary
    <|> try pRegRuleNormal
    <|> (pToken Fulfilled >> return RegFulfilled)
    <|> (pToken Breach    >> return RegBreach)
  ) <* optional dnl

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
  entitytype         <- pOtherVal
  leftX              <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.

  rulebody           <- withDepth leftX (permutationsReg [When,If] [Unless] [Upon] [Given] [Having])
  -- TODO: refactor and converge the rest of this code block with Normal below
  henceLimb          <- optional $ pHenceLest Hence
  lestLimb           <- optional $ pHenceLest Lest
  let poscond = mergePBRS (rbpbrs   rulebody)
  let negcond = mergePBRS (rbpbrneg rulebody)
      toreturn = Regulative
                 entitytype
                 Nothing
                 (addneg poscond negcond)
                 (rbdeon rulebody)
                 (rbaction rulebody)
                 (rbtemporal rulebody)
                 henceLimb
                 lestLimb
                 Nothing -- rule label
                 Nothing -- legal source
                 Nothing -- internal SrcRef
                 (snd <$> rbupon  rulebody)    -- given
                 (snd <$> rbgiven rulebody)    -- given
                 (rbhaving rulebody)
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
  leftX              <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  (_party_every, entitytype, _entityalias)   <- try (pActor Party) <|> pActor Every
  -- (Who, (BoolStruct,[Rule]))
  whoBool                     <- optional (withDepth leftX (preambleBoolRules [Who]))
  -- the below are going to be permutables
  myTraceM $ "pRegRuleNormal: preambleBoolRules returned " ++ show whoBool
  rulebody <- permutationsReg [When, If] [Unless] [Upon] [Given] [Having]
  henceLimb                   <- optional $ pHenceLest Hence
  lestLimb                    <- optional $ pHenceLest Lest
  myTraceM $ "pRegRuleNormal: permutations returned rulebody " ++ show rulebody

  -- qualifying conditions generally; we merge all positive groups (When, If) and negative groups (Unless)
  let poscond = mergePBRS (rbpbrs   rulebody)
  let negcond = mergePBRS (rbpbrneg rulebody)

  let toreturn = Regulative
                 entitytype
                 (snd <$> whoBool)
                 (addneg poscond negcond)
                 (rbdeon rulebody)
                 (rbaction rulebody)
                 (rbtemporal rulebody)
                 henceLimb
                 lestLimb
                 Nothing -- rule label
                 Nothing -- legal source
                 Nothing -- internal SrcRef
                 (snd <$> rbupon  rulebody)    -- given
                 (snd <$> rbgiven rulebody)    -- given
                 (rbhaving rulebody)
  myTraceM $ "pRegRuleNormal: the positive preamble is " ++ show poscond
  myTraceM $ "pRegRuleNormal: the negative preamble is " ++ show negcond
  myTraceM $ "pRegRuleNormal: returning " ++ show toreturn
  -- let appendix = pbrs ++ nbrs ++ ebrs ++ defalias
  -- myTraceM $ "pRegRuleNormal: with appendix = " ++ show appendix
  -- return ( toreturn : appendix )
  return toreturn

-- this is probably going to need cleanup
addneg :: Maybe BoolStructP -> Maybe BoolStructP -> Maybe BoolStructP
addneg Nothing  Nothing   = Nothing
addneg Nothing  (Just n)  = Just $ AA.Not n
addneg (Just p) (Just n)  = Just $ AA.All [p, AA.Not n]
addneg (Just p) Nothing   = Just p

pHenceLest :: MyToken -> Parser Rule
pHenceLest henceLest = debugName ("pHenceLest-" ++ show henceLest) $ do
  id <$ pToken henceLest `indented1` pRegRule

-- combine all the boolrules under the first preamble keyword
mergePBRS :: [(Preamble, BoolRulesP)] -> Maybe (Preamble, BoolRulesP)
mergePBRS [] = Nothing
mergePBRS ((w, br) : xs) = Just (w, AA.All $ br : (snd <$> xs))

pTemporal :: Parser (Maybe (TemporalConstraint Text.Text))
pTemporal = eventually <|> specifically
  where
    eventually   = mkTC <$> pToken Eventually <*> pure ""
    specifically = mkTC <$> sometime          <*> pOtherVal
    sometime     = choice $ map pToken [ Before, After, By, On ]

-- "PARTY Bob       (the "Seller")
-- "EVERY Seller"
pActor :: MyToken -> Parser (MyToken, Text.Text, Maybe Text.Text)
pActor party = debugName ("pActor " ++ show party) $ do
  leftY       <- lookAhead pYLocation
  leftX       <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  -- add pConstitutiveRule here -- we could have "MEANS"
  _           <- pToken party
  (entitytype, entityalias)   <- lookAhead pNameParens
  omgARule <- pure <$> try pConstitutiveRule <|> (mempty <$ pNameParens)
  myTraceM $ "pActor: omgARule = " ++ show omgARule
  srcurl <- asks sourceURL
  let srcref = SrcRef srcurl srcurl leftX leftY Nothing
  let defalias = maybe mempty (\t -> singeltonDL (DefNameAlias t entitytype Nothing (Just srcref))) entityalias
  tell $ defalias <> listToDL omgARule
  return (party, entitytype, entityalias)

-- two tokens of the form | some thing | ("A Thing") | ; |
pNameParens :: Parser (Text.Text, Maybe Text.Text)
pNameParens = debugName "pNameParens" $ do
  entitytype  <- pOtherVal
  entityalias <- optional pOtherVal -- TODO: add test here to see if the pOtherVal has the form    ("xxx")
  _ <- dnl
  return (entitytype, entityalias)

pDoAction ::  Parser BoolStructP
pDoAction = pToken Do >> pAction

-- everything in p2 must be at least the same depth as p1
indented :: Int -> Parser (a -> b) -> Parser a -> Parser b
indented d p1 p2 = do
  leftX <- lookAhead pXLocation
  f     <- p1
  y     <- withDepth (leftX + d) p2
  return $ f y

indented0 :: Parser (a -> b) -> Parser a -> Parser b
indented0 = indented 0
infixl 4 `indented0`

indented1 :: Parser (a -> b) -> Parser a -> Parser b
indented1 = indented 1
infixl 4 `indented1`

pAction :: Parser BoolRulesP
pAction = dBoolRules

pParamText :: Parser ParamText
pParamText = debugName "pParamText" $ do
  (:|) <$> (pKeyValues <* dnl <?> "paramText head") `indented0` pParams

  -- === flex for
  --     (myhead, therest) <- (pKeyValues <* dnl) `indented0` pParams
  --     return $ myhead :| therest

type KVsPair = NonEmpty Text.Text -- so really there are multiple Values

pParams :: Parser [KVsPair]
pParams = many $ pKeyValues <* dnl    -- head (name+,)*

pKeyValues :: Parser KVsPair
pKeyValues = debugName "pKeyValues" $ (:|) <$> pOtherVal `indented1` many pOtherVal

-- we create a permutation parser returning one or more RuleBodies, which we treat as monoidal,
-- though later we may object if there is more than one.

mkRBfromDT :: BoolStructP
           -> [(Preamble, BoolRulesP)] -- positive  -- IF / WHEN
           -> [(Preamble, BoolRulesP)] -- negative  -- UNLESS
           -> [(Preamble, BoolRulesP)] -- upon  conditions
           -> [(Preamble, BoolRulesP)] -- given conditions
           -> Maybe ParamText               -- having
           -> (Deontic, Maybe (TemporalConstraint Text.Text))
           -> RuleBody
mkRBfromDT rba rbpb rbpbneg rbu rbg rbh (rbd,rbt) = RuleBody rba rbpb rbpbneg rbd rbt rbu rbg rbh

mkRBfromDA :: (Deontic, BoolStructP)
           -> [(Preamble, BoolRulesP)]
           -> [(Preamble, BoolRulesP)]
           -> [(Preamble, BoolRulesP)] -- upon  conditions
           -> [(Preamble, BoolRulesP)] -- given conditions
           -> Maybe ParamText         -- having
           -> Maybe (TemporalConstraint Text.Text)
           -> RuleBody
mkRBfromDA (rbd,rba) rbpb rbpbneg rbu rbg rbh rbt = RuleBody rba rbpb rbpbneg rbd rbt rbu rbg rbh

permutationsCon :: [MyToken] -> [MyToken] -> [MyToken]
                -> Parser ( (Preamble, BoolRulesP)   -- positive
                          , [(Preamble, BoolRulesP)] -- unless
                          , [(Preamble, BoolRulesP)]  -- given
                          )
permutationsCon ifwhen l4unless l4given =
  debugName ("permutationsCon positive=" <> show ifwhen
             <> ", negative=" <> show l4unless
             <> ", given=" <> show l4given
            ) $ do
  try ( debugName "constitutive permutation" $ permute ( (,,)
            <$$> preambleBoolRules ifwhen
            <|?> ([], some $ preambleBoolRules l4unless)
            <|?> ([], some $ preambleBoolRules l4given)  -- given
          ) )

permutationsReg :: [MyToken] -> [MyToken] -> [MyToken] -> [MyToken] -> [MyToken] -> Parser RuleBody
permutationsReg ifwhen l4unless l4upon l4given l4having =
  debugName ("permutationsReg positive=" <> show ifwhen
             <> ", negative=" <> show l4unless
             <> ", upon=" <> show l4upon
             <> ", given=" <> show l4given
             <> ", having=" <> show l4having
            ) $ do
  try ( debugName "regulative permutation with deontic-temporal" $ permute ( mkRBfromDT
            <$$> pDoAction
            <|?> ([], some $ preambleBoolRules ifwhen)   -- syntactic constraint, all the if/when need to be contiguous.
            <|?> ([], some $ preambleBoolRules l4unless) -- unless
            <|?> ([], some $ preambleBoolRules l4upon)   -- upon
            <|?> ([], some $ preambleBoolRules l4given)  -- given
            <|?> (Nothing, choice (try . pToken <$> l4having) >> Just <$> pParamText)  -- having
            <||> try pDT
          ) )
  <|>
  try ( debugName "regulative permutation with deontic-action" $ permute ( mkRBfromDA
            <$$> try pDA
            <|?> ([], some $ preambleBoolRules ifwhen) -- syntactic constraint, all the if/when need to be contiguous.
            <|?> ([], some $ preambleBoolRules l4unless) -- syntactic constraint, all the if/when need to be contiguous.
            <|?> ([], some $ preambleBoolRules l4upon)   -- upon
            <|?> ([], some $ preambleBoolRules l4given)  -- given
            <|?> (Nothing, choice (try . pToken <$> l4having) >> Just <$> pParamText)  -- having
            <|?> (Nothing, pTemporal <* dnl)
          ) )


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

preambleBoolRules :: [MyToken] -> Parser (Preamble, BoolRulesP)
preambleBoolRules wanted = debugName ("preambleBoolRules " <> show wanted)  $ do
  leftX     <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  condWord <- choice (try . pToken <$> wanted)
  myTraceM ("preambleBoolRules: found: " ++ show condWord)
  ands <- withDepth leftX dBoolRules -- (foo AND (bar OR baz), [constitutive and regulative sub-rules])
  return (condWord, ands)

dBoolRules ::  Parser BoolRulesP
dBoolRules = debugName "dBoolRules" $ do
  pAndGroup -- walks AND eats OR drinks

pAndGroup ::  Parser BoolRulesP
pAndGroup = debugName "pAndGroup" $ do
  orGroup1 <- pOrGroup
  orGroupN <- many $ pToken And *> pOrGroup
  let toreturn = if null orGroupN
                 then orGroup1
                 else AA.All (orGroup1 : orGroupN)
  return toreturn

pOrGroup ::  Parser BoolRulesP
pOrGroup = debugName "pOrGroup" $ do
  depth <- asks callDepth
  elem1    <- withDepth (depth + 1) pElement
  elems    <- many $ pToken Or *> withDepth (depth+1) pElement
  let toreturn = if null elems
                 then elem1
                 else AA.Any  (elem1 : elems)
  return toreturn

pElement ::  Parser BoolRulesP
pElement = debugName "pElement" $ do
  -- think about importing Control.Applicative.Combinators so we get the `try` for free
  try pNestedBool
    <|> pNotElement
    <|> try (constitutiveAsElement <$> tellIdFirst pConstitutiveRule)
    <|> pLeafVal

-- | Like `\m -> do a <- m; tell [a]; return a` but add the value before the child elements instead of after
tellIdFirst :: (Functor m) => WriterT (DList w) m w -> WriterT (DList w) m w
tellIdFirst = mapWriterT . fmap $ \(a, m) -> (a, singeltonDL a <> m)

-- Makes a leaf with just the name of a constitutive rule
constitutiveAsElement ::  Rule -> BoolRulesP
constitutiveAsElement cr = AA.Leaf (text2pt $ name cr)
-- constitutiveAsElement _ = error "constitutiveAsElement: cannot convert an empty list of rules to a BoolRules structure!"

pNotElement :: Parser BoolRulesP
pNotElement = debugName "pNotElement" $ do
  inner <- pToken MPNot *> pElement
  return $ AA.Not inner

pLeafVal ::  Parser BoolRulesP
pLeafVal = debugName "pLeafVal" $ do
  leafVal <- pParamText
  myTraceM $ "pLeafVal returning " ++ show leafVal
  return $ AA.Leaf leafVal

-- should be possible to merge pLeafVal with pNestedBool.

pNestedBool ::  Parser BoolRulesP
pNestedBool = debugName "pNestedBool" $ do
  -- "foo AND bar" is a nestedBool; but just "foo" is a leafval.
  foundBool <- lookAhead (pLeafVal >> pBoolConnector)
  myTraceM $ "pNestedBool matched " ++ show foundBool
  dBoolRules

pBoolConnector :: Parser MyToken
pBoolConnector = debugName "pBoolConnector" $ do
  pToken And <|> pToken Or <|> pToken Unless

-- helper functions for parsing

anything :: Parser [WithPos MyToken]
anything = many anySingle

-- "discard newline", a reference to GNU Make
dnl :: Parser [MyToken]
dnl = some $ pToken EOL

pDeontic :: Parser Deontic
pDeontic = (pToken Must  >> return DMust)
           <|> (pToken May   >> return DMay)
           <|> (pToken Shant >> return DShant)

-- return the text inside an Other value. This implicitly serves to test for Other, similar to a pToken test.
pOtherVal :: Parser Text.Text
pOtherVal = token test Set.empty <?> "Other text"
  where
    test (WithPos _ _ _ (Other t)) = Just t
    test _ = Nothing

getToken :: Parser MyToken
getToken = token test Set.empty <?> "any token"
  where
    test (WithPos _ _ _ tok) = Just tok


-- pInt :: Parser Int
-- pInt = token test Set.empty <?> "integer"
--   where
--     test (WithPos _ _ _ (Int n)) = Just n
--     test _ = Nothing

-- pSum :: Parser (Int, Int)
-- pSum = do
--   a <- pInt
--   _ <- pToken Plus
--   b <- pInt
--   return (a, b)

-- egStream :: String -> MyStream
-- egStream x = MyStream x (parseMyStream x)

