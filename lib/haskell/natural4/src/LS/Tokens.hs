{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ViewPatterns #-}

{-|
This module provides token-level parsers, (though the tokens themselves are defined in BasicTypes).

This module also provides a family of SLParser combinators ("Same Line").
-}

module LS.Tokens (module LS.Tokens, module Control.Monad.Reader) where

import Control.Applicative (Alternative, liftA2)
import Control.Monad
  ( MonadPlus,
    replicateM_,
    void,
    when,
  )
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (ReaderT, runReaderT),
    asks,
    local,
  )
import Control.Monad.Writer.Lazy
  ( MonadTrans (lift),
    WriterT (..),
    censor,
    mapWriterT,
  )
import Data.Functor.Identity (Identity)
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isNothing)
import Data.Monoid (Sum (..))
import Data.Set qualified as Set
import Data.String.Interpolate (i)
import Data.Text qualified as Text
import Data.Void (Void)
import Debug.Trace (traceM)
import LS.Error (onelineErrorMsg)
import LS.Rule
  ( Parser,
    Rule,
    RuleLabel,
    pGetTokenPos,
    pTokenMatch,
    pXLocation,
    pYLocation,
    whenDebug,
  )
import LS.Types
  ( DList,
    Deontic (..),
    HasToken (..),
    MTExpr (..),
    MultiTerm,
    MyStream (MyStream, unMyStream),
    MyToken
      ( A_An,
        EOL,
        GoDeeper,
        Is,
        May,
        Must,
        Other,
        RuleMarker,
        Shant,
        TNumber,
        TokAnd,
        TokEQ,
        TokFalse,
        TokGT,
        TokGTE,
        TokIn,
        TokLT,
        TokLTE,
        TokNotIn,
        TokOr,
        TokProduct,
        TokSum,
        TokMinus,
        TokDivide,
        TokModulo,
        TokTrue,
        UnDeeper
      ),
    RunConfig (debug, parseCallStack, sourceURL),
    SrcRef (SrcRef),
    WithPos (WithPos, pos, tokenVal),
    increaseNestLevel,
    nestLevel,
    singeltonDL,
  )
import Text.Megaparsec
  ( MonadParsec
      ( eof,
        lookAhead,
        notFollowedBy,
        token,
        try,
        updateParserState
      ),
    ParseError,
    Parsec,
    ParsecT,
    SourcePos (sourceColumn, sourceLine),
    State (State, stateInput),
    Stream,
    between,
    choice,
    count,
    many,
    optional,
    some,
    unPos,
    (<?>),
    (<|>),
  )
import Text.Megaparsec.Debug (dbg)
import Text.Megaparsec.Internal qualified as MPInternal

-- "discard newline", a reference to GNU Make
dnl :: Parser MyToken
-- -- dnl = many $ pToken EOL
dnl = pToken EOL
-- dnl = some $ pToken EOL

pDeontic :: Parser Deontic
pDeontic = (pToken Must  >> pure DMust)
           <|> (pToken May   >> pure DMay)
           <|> (pToken Shant >> pure DShant)

-- | parse a number.
pNumber :: Parser Double
pNumber = token test Set.empty <?> "number"
  where
    test WithPos {tokenVal = TNumber n} = Just n
    test _ = Nothing

-- pure the text inside an Other value. This implicitly serves to test for Other, similar to a pToken test.
pOtherVal :: Parser Text.Text
pOtherVal = token test Set.empty <?> "Other text"
  where
    test WithPos {tokenVal = Other t} = Just t
    test _ = Nothing

getToken :: Parser MyToken
getToken = token test Set.empty <?> "any token"
  where
    test WithPos {tokenVal = tok} = Just tok

getWithPos :: Parser String
getWithPos = token showpos Set.empty <?> "any token"
  where
    -- test wp@WithPos {tokenVal = tok}
    --   | tok `elem` [GoDeeper, UnDeeper, EOL] = showpos wp
    --   | otherwise                            = showpos wp
    showpos wp =
      let poswp = pos wp in
      Just [i|#{unPos $ sourceLine $ poswp}_#{unPos $ sourceColumn $ poswp}:#{tokenVal wp}|]
      -- show (unPos $ sourceLine   $ pos wp) ++ "_" ++
      -- show (unPos $ sourceColumn $ pos wp) ++ ":" ++
      -- show (tokenVal wp)
    -- _showtok wp = Just $ show $ tokenVal wp

tokenViewColumnSize :: Int
tokenViewColumnSize = 15

myTraceM :: String -> Parser ()
myTraceM x = whenDebug do
  nestDepth <- asks nestLevel
  lookingAt <- lookAhead getWithPos <|> ("EOF" <$ eof)
  traceM $ leftPad lookingAt tokenViewColumnSize <> indentShow nestDepth <> x
  where
    indentShow depth = mconcat $ replicate depth "| "
    leftPad str n = take n $ str <> repeat ' '

getTokenNonDeep :: Parser MyToken
getTokenNonDeep =
  token test Set.empty <?> "any token except GoDeeper / UnDeeper"
  where
    test WithPos {tokenVal = tok}
      | tok `elem` [GoDeeper, UnDeeper] = Nothing
      | otherwise = Just tok

getTokenNonEOL :: Parser MyToken
getTokenNonEOL = token test Set.empty <?> "any token except EOL"
  where
    test WithPos {tokenVal = tok} = case tok of
      EOL -> Nothing
      _ -> Just tok

-- pInt :: Parser Int
-- pInt = token test Set.empty <?> "integer"
--   where
--     test (WithPos _ _ (Int n)) = Just n
--     test _ = Nothing

-- pSum :: Parser (Int, Int)
-- pSum = do
--   a <- pInt
--   _ <- pToken Plus
--   b <- pInt
--   pure (a, b)

-- egStream :: String -> MyStream
-- egStream x = MyStream x (parseMyStream x)

pSrcRef :: Parser (Maybe RuleLabel, Maybe SrcRef)
pSrcRef = debugName "pSrcRef" do
  rlabel' <- optional pRuleLabel
  leftY  <- lookAhead pYLocation -- this is the column where we expect IF/AND/OR etc.
  leftX  <- lookAhead pXLocation -- this is the column where we expect IF/AND/OR etc.
  srcurl <- asks sourceURL
  pure (rlabel', Just $ SrcRef srcurl srcurl leftX leftY Nothing)

myEOL :: Parser ()
myEOL = void (pToken EOL) <|> eof <|> notFollowedBy (choice [ pToken GoDeeper, pToken UnDeeper ])

pRuleLabel :: Parser RuleLabel
pRuleLabel = debugName "pRuleLabel" . pretendEmpty . someUndeepersOrEOL $ do
  (RuleMarker i sym, actualLabel) <- (,)
                                     $>| pTokenMatch isRuleMarker (pure $ RuleMarker 1 "§")
                                    --  |>| pOtherVal
                                     |*| (Text.unwords <$> manyLiftSL pOtherVal)
                                     -- <*  (someUndeepers <|> liftSL myEOL) -- effectively, we push a GoDeeper into the stream so we can pretend we started afresh. a pushback list is what we want: https://www.metalevel.at/prolog/dcg

  pure (sym, i, actualLabel)
  where
    isRuleMarker (RuleMarker _ _) = True
    isRuleMarker _                = False

refillDeepers :: Int -> Parser ()
refillDeepers n = do
  -- traceM $ "refillDeepers: " ++ show n
  replicateM_ n $ pToken GoDeeper

-- | push back a token into the stream.
pushBackToken :: WithPos MyToken -> Parser ()
pushBackToken tok =
  updateParserState
    \s@State {stateInput} -> s{stateInput = pushTokenStream tok stateInput}

pushTokenStream :: WithPos MyToken -> MyStream -> MyStream
pushTokenStream tok str@MyStream {unMyStream} =
  str {unMyStream = tok : unMyStream}

-- | This is like `(someUndeepers <|> liftSL myEOL)`, but doesn't consume too many undeepers
-- We should probably invent a new operator (something like "|<?$") to clean this up a bit.
-- Followup: we have a new operator |<<| that calls upToNUndeepers, but doesn't handle the EOL

someUndeepersOrEOL :: SLParser a -> Parser a
someUndeepersOrEOL p = do
  (x, n) <- runSL p
  ((), m) <- runSL $ upToNUndeepers n <|> liftSL myEOL
  let remaining = n + m
  eof <|> do
    pos <- lookAhead pGetTokenPos
    replicateM_ remaining $ pushBackToken $ GoDeeper <$ pos
  pure x

-- calls upToNUndeepers and continues. Usage: ... |<<| () ...
(|<<|) :: SLParser a -> () -> SLParser a
p1 |<<| _ = mkSL do
  (result, n) <- runSL p1
  (_, u) <- runSL $ upToNUndeepers n
  let remaining = n + u
  debugPrint [i||<<| consumed #{-1*u} of #{n} undeepers; #{remaining} remain|]
  eof <|> do
    pos <- lookAhead pGetTokenPos
    replicateM_ remaining $ pushBackToken (GoDeeper <$ pos)
  pure (result, remaining)

infixl 4 |<<|

liftedDBG :: Show a => String -> Parser a -> Parser a
liftedDBG = mapWhenDebug . liftRawPFun . dbg

mapWhenDebug :: (Parser a -> Parser a) -> Parser a -> Parser a
mapWhenDebug f p = do
  isDebug <- asks debug
  if isDebug
    then f p
    else p

type RawParser a = Parsec Void MyStream (a, DList Rule)

liftRawPFun :: (RawParser a -> RawParser a) -> Parser a -> Parser a
liftRawPFun f = WriterT . ReaderT . (\x -> f . runReaderT x) . runWriterT

printErrors :: String -> RunConfig -> Parser a -> Parser a
printErrors dname r = runOnErrors \cnsmp err s res -> do
  let consumption :: String = case cnsmp of
        MPInternal.Consumed -> "Consumed"
        MPInternal.NotConsumed -> "Unconsumed"
  let magicRunParser p = MPInternal.unParser (runReaderT (runWriterT p) r) s
                           (\_ _ _ -> traceM "cok" >> res)
                           (\_ _ -> traceM "cerr" >> res)
                           (\_ _ _ -> res)
                           \_ _ -> traceM "eerr" >> res
  magicRunParser . myTraceM $
    [i|\\ !#{consumption} Error: #{dname}: #{onelineErrorMsg err}|]

debugNameP :: Show a => String -> Parser a -> Parser a
debugNameP dname p = do -- label dname $
  -- debugPrint dname
  myTraceM [i|/ #{dname}|]
  r <- asks id
  res <- printErrors dname r $ local (increaseNestLevel dname) $ liftedDBG dname p
  myTraceM [i|\\ #{dname} has pureed #{show res}|]
  pure res

debugNameSL :: Show a => String -> SLParser a -> SLParser a
debugNameSL dname = mkSL . debugNameP dname . runSL

slPretendEmpty :: IsParser f => f a -> f a
slPretendEmpty = mapParser pretendEmpty

class IsParser f where
  debugName :: Show a => String -> f a -> f a
  debugPrint :: String -> f ()
  mapParser :: (forall x. Parser x -> Parser x) -> f a -> f a

instance IsParser Parser where
  debugName = debugNameP
  debugPrint = debugPrintP
  mapParser x = x

instance IsParser SLParser where
  debugName = debugNameSL
  debugPrint = debugPrintSL
  mapParser f = mkSL . f . runSL

debugPrintP :: String -> Parser ()
debugPrintP str = -- whenDebug do
--  lookingAt <- lookAhead getToken <|> (EOF <$ eof)
--  leftX     <- lookAhead pXLocation
  myTraceM [i|> #{str}|]
    -- <> "; currently at " ++ show leftX
    -- <> "; looking at: " <> show lookingAt

debugPrintSL :: String -> SLParser ()
debugPrintSL = SLParser . lift . debugPrint

-- force debug=true for this subpath
alwaysdebugName :: Show a => String -> Parser a -> Parser a
alwaysdebugName dname p = local (\rc -> rc { debug = True }) $ debugName dname p

-- * the new MultiTerm is made of MTExpr
pMTExpr :: Parser MTExpr
pMTExpr =
  choice [ try $ MTI <$> isIntegral pNumber
         , try $ MTF <$> pNumber
         , MTB <$> pBoolean
         , MTT <$> pOtherVal
         ]
  where
    isIntegral pn = do
      x <- pn
      if (fromIntegral (floor x :: Int) :: Double) == x
        then pure $ floor x
        else fail "not an integer"

-- | parse a TRUE or FALSE to an MTEXpr. But see also `getMarkings` in Interpreter.hs.
pBoolean :: Parser Bool
pBoolean = True  <$ choice [pToken TokTrue,  try $ pText (Text.words "True true Yes yes ja"  ) TokTrue  ] <|>
           False <$ choice [pToken TokFalse, try $ pText (Text.words "False false No no nein") TokFalse ]

-- | if the next token parses with pOtherVal to one of the desired text strings, upgrade to a given token; otherwise fail.
pText :: [Text.Text] -> MyToken -> Parser MyToken
pText ts tok = do
  p <- pOtherVal
  if p `elem` ts
    then pure tok
    else fail [i|pText: got #{p} which doesn't match input text #{ts}|]

-- | parse a multiterm
pMultiTerm :: Parser MultiTerm
pMultiTerm = debugName "pMultiTerm calling someDeep choice" $ someDeep pMTExpr

-- | sameline parser for multiterm
slMultiTerm :: SLParser MultiTerm
slMultiTerm = debugNameSL "slMultiTerm" $ someLiftSL pMTExpr

-- | sameline: foo foo bar bar
--   nextline: foo foo
--             bar bar
-- if we wanted to try to be super clever we could remain in the SL context the whole time and limit the <|> bit to the dnl newline vs the ) ( vs the samedepth

(|&|) = sameOrNextLine
sameOrNextLine :: (Show a, Show b) => SLParser a -> SLParser b -> Parser (a, b)
sameOrNextLine pa pb =
  try (debugName "sameOrNextLine: trying next line" $ (,) >*| (pa <* liftSL (optional dnl)) |^| (liftSL (optional dnl) *> pb) |<$ undeepers)
  <|> debugName "sameOrNextLine: trying same line" ((,) >*| pa |*| pb |<$ undeepers)

-- [TODO] -- are the undeepers above disruptive? we may want a version of the above which stays in SLParser context the whole way through.

-- | one or more P, monotonically moving to the right, pureed in a list.
-- if you don't want moving to the right, but want the things all to fall at the same indentation level, just use `some` or `many`.
someDeep :: (Show a) => Parser a -> Parser [a]
someDeep p = debugName "someDeep"
  ( (:)
    <$> debugName "someDeep first part calls base directly" p
    <*> ( debugName "someDeep second part recurses with someIndentation" (try $ someIndentation $ someDeep p)
        <|> (debugPrint "someDeep no luck, pureing []" >> pure [])) )

-- zero or more P, monotonically moving to the right, pureed in a list
manyDeep :: (Show a) => Parser a -> Parser [a]
manyDeep p =
  debugName "manyDeep"
  (debugName "manyDeep calling someDeep" (try $ someDeep p)
    <|>
    (debugPrint "someDeep failed, manyDeep defaulting to pure []" >> pure [])
  )

someDeepThen :: (Show a, Show b) => Parser a -> Parser b -> Parser ([a],b)
someDeepThen p1 p2 = someIndentation $ manyDeepThen p1 p2

someDeepThenMaybe :: (Show a, Show b) => Parser a -> Parser b -> Parser ([a],Maybe b)
someDeepThenMaybe p1 p2 = someIndentation $ manyDeepThenMaybe p1 p2

-- continuation:
-- what if you want to match something like
-- foo foo foo foo foo (bar)
manyDeepThen :: (Show a, Show b) => Parser a -> Parser b -> Parser ([a],b)
manyDeepThen p1 p2 = debugName "manyDeepThen" do
  p <- try $ debugName "manyDeepThen/initial" p1
  (lhs, rhs) <- donext
  pure (p:lhs, rhs)
  where
    donext = debugName "manyDeepThen/going inner" (try $ someIndentation $ manyDeepThen p1 p2)
             <|> debugName "manyDeepThen/donext-rhs" base
    base = debugName "manyDeepThen/base" do
      rhs <- try (manyIndentation p2)
      pure ([], rhs)

manyDeepThenMaybe :: (Show a, Show b) => Parser a -> Parser b -> Parser ([a],Maybe b)
manyDeepThenMaybe p1 p2 = debugName "manyDeepThenMaybe" do
  p <- try $ debugName "manyDeepThenMaybe/initial" p1
  (lhs, rhs) <- donext
  pure (p:lhs, rhs)
  where
    donext = debugName "going inner" (try $ someIndentation $ manyDeepThenMaybe p1 p2)
             <|> debugName "going rhs" base
    base = debugName "manyDeepThenMaybe/base" do
      rhs <- optional $ try (manyIndentation p2)
      pure ([], rhs)

{- ABOUT THE SAMELINE COMBINATORS
   We need combinators for compound expressions on the same line.

   Example: "foo IS bar AND baz IS quux"
   contains (foo IS bar)   -- a RelationalPredicate
            (baz IS quux)  -- another RelationalPredicate
   and then they are joined by "AND" to form a BoolStructR

   The constructor is something like (And [ RPConstraint ["foo"] RPis ["bar"]
                                          , RPConstraint ["baz"] RPis ["quux"] ])

   In a simple world, where we don't have GoDeepers and UnDeepers to think about, an applicative-style constructor would be something like
     RPConstraint <$> pMultiTerm <*> tok2rel <*> pMultiTerm

   But this doesn't work, because the pMultiTerm is implemented using a `someDeep` which expects to tidy up its UnDeepers at the end:
     (f(o(o))) IS (b(a(r)))

   (Let's pretend that ~foo~ is itself a subexpression spread across multiple columns, so "f,o,o" in the CSV.)

   If the sub-expressions were broken across multiple lines that would be fine --
   the foo and the baz would be at the same indentation level because after bar we would get a bunch of UnDeepers.
     (f(o(o)))
     IS
     (b(a(r)))

   But when we're dealing with expressions that are on the same line, what we need instead is to be able to match
     (fo(o(o(  IS (b(a(r)))))))

   ... pending all the UnDeepers to the end!

   (BTW in the above we use '(' as a shorthand for GoDeeper, and ')' as a shorthand for UnDeeper.)

   A naive pSomething parser naturally wants to be tidy and close all the parens it had opened:
   it will try to match UnDeepers at the end of its parsing.

   But we need to be able to override that: we want to tell these base parsers "don't worry about closing the parens,
   don't try to match UnDeepers. Just keep track of how many UnDeepers need to be matched, and tell us, and we will
   promise to match them for you when we get to the end of the outer compound expression."

   So we introduce a family of combinators to support the above. Instead of a ~Parser a~ we deal with a ~Parser (a, Int)~
   where the Int keeps track of how many open parens (GoDeepers) we have encountered, and therefore how many close
   parens (UnDeepers) we will need to close when we get to the end of the line

   The way to solve this using the sameline combinator is something like
      RPConstraint
        $*| dMultiTerm
        |>| tok2rel
        |*< dMultiTerm
      where dMultiTerm = someLiftSL pMTExpr, which lifts a plain parser into the fancy combinator, slapping a "some" alongside.

   We lift a Parser a into a Parser (a, Int) where the Int records the number of UnDeepers needed to be consumed at the end.

   At the end, the combinators (|*<) and (|$<) are responsible for consuming, or "undeepering", those UnDeepers.
   The idea of "UnDeeper" corresponds with "moving to the left", which is why we see the character '<' at the right of the sigil.

   To get parsers into the combinator, we can lift by using a fish operator liftSL -- but this is usually only used in helper functions.

   The more conventional way to build a parser chain is to use applicative style, and that's why we have combinators that
   - get the chain started  :: ($>|) and ($*|)
   - keep the chain running :: (|>|) and (|*|)
   - end the chain          :: (|><) and (|*<) ... also |<$ if you want to control that manually

   In the type definition table below we refer to `Parser (a,Int)` as "fancy" and `Parser a` as "plain".

   What do the characters mean? Generally:
   - $ means a function, typically a data constructor, which consumes one or more arguments to pure a value
   - > means an argument to that constructor, typically a plain parser that pures the value needed by the constructor
   - | means a fancified curry coming from the left, that is part of the chain; or pureing a fancified curry to the right
   - * means an argument to the constructor which itself has been fancified
   - < means this combinator is responsible for consuming undeepers

   Together, the first character represents the left argument, the second the right, and the third the output.
   Then you can basically hook them up by playing dominos, ahem, by checking that the types are consistent.

   Some examples follow below. To see the SLParser combinators in use, see ParamText,
   where the p* Parsers tend to wrap the sl* SLParsers.
-}

-- | A parser that has some pending GoDeepers to be consumed at the end.
newtype SLParser a = SLParser {runSLParser_ :: WriterT (Sum Int) Parser a}
  deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadParsec Void MyStream, MonadReader RunConfig, MonadFail)
  -- deriving (Functor, Applicative, Alternative, Monad, MonadPlus, MonadWriter (Sum Int))

runSL :: SLParser a -> Parser (a, Int)
runSL = fmap (fmap getSum) . runWriterT . runSLParser_

mkSL :: Parser (a, Int) -> SLParser a
mkSL = SLParser . WriterT . fmap (fmap Sum)

-- lift a simple parser into the SLparser context
-- | Lift a plain parser to an SLParser with no pending godeepers.
liftSL :: Parser a -> SLParser a
liftSL = SLParser . lift

slDeeper :: SLParser ()
slDeeper = mkSL $ ((), 1) <$ pToken GoDeeper
-- slDeeper = SLParser $ lift (pToken GoDeeper) >> tell (Sum 1)

slUnDeeper :: SLParser ()
slUnDeeper = mkSL $ ((), -1) <$ pToken UnDeeper

censorSL :: (Int -> Int) -> SLParser a -> SLParser a
censorSL f = SLParser . censor (Sum . f . getSum) . runSLParser_

-- * the "cell-crossing" combinators consume GoDeepers that arise between the arguments.
(+>|)  :: Show a           =>          (a -> b) ->        Int  -> SLParser (a -> b)  -- ^ start with an initial count of expected UnDeepers
($>|)  :: Show a           =>          (a -> b) ->   Parser a  -> SLParser b  -- ^ start using plain plain
($*|)  :: Show a           =>          (a -> b) -> SLParser a  -> SLParser b  -- ^ start using fancy fancy

(>>|)  :: Show a           =>          (a -> b) ->   Parser a  -> SLParser b  -- ^ same as $>| but optionally indented
(>*|)  :: Show a           =>          (a -> b) -> SLParser a  -> SLParser b  -- ^ same as $*| but optionally indented

-- * continue
(|>|)  :: Show a           => SLParser (a -> b) ->   Parser a  -> SLParser b  -- ^ continue    fancy plain
(|*|)  :: Show a           => SLParser (a -> b) -> SLParser a  -> SLParser b  -- ^ continue    fancy fancy
(|-|)  ::                     SLParser (a -> b) ->   Parser a  -> SLParser b  -- ^ continue    fancy plain without consuming any GoDeepers
(|=|)  ::                     SLParser (a -> b) -> SLParser a  -> SLParser b  -- ^ continue    fancy fancy without consuming any GoDeepers
($>>)  :: Show a           =>   Parser  a       ->                SLParser a  -- ^ consume any GoDeepers, then parse -- plain
(|>>)  :: Show a           => SLParser  a       ->                SLParser a  -- ^ consume any GoDeepers, then parse -- fancy
(|<|)  :: Show a           => SLParser (a -> b) ->   Parser a  -> SLParser b  -- ^ consume any UnDeepers, then parse -- plain
(|^|)  :: Show a           => SLParser (a -> b) -> SLParser a  -> SLParser b  -- ^ consume any GoDeepers or UnDeepers, then parse -- fancy
(|<*)  :: Show a           => SLParser (a -> b) -> SLParser a  -> SLParser b  -- ^ consume any UnDeepers, then parse -- fancy
(|<>)  :: Show a           => SLParser (a -> b) ->   Parser a  -> SLParser b  -- ^ consume any UnDeepers, then parse, then consume GoDeepers

(|&|)  ::(Show a, Show b)  => SLParser  a       -> SLParser b  ->   Parser (a,b) -- ^ standalone fancy fancy on same or next line

-- * greedy match of LHS until RHS; and if there is overlap between LHS and RHS, keep backtracking LHS to be less greedy until RHS succeeds. pure both lhs and rhs
(+?|)  :: Show a           =>   Parser a        -> SLParser b  -> SLParser ([a],b)  -- force the LHS to be nongreedy before matching the right.
(*?|)  :: Show a           =>   Parser a        -> SLParser b  -> SLParser ([a],b)  -- plain nongreedy kleene star
(|+?)  :: Show a           => SLParser a        -> SLParser b  -> SLParser ([a],b)  -- fancy nongreedy kleene plus
(|*?)  :: Show a           => SLParser a        -> SLParser b  -> SLParser ([a],b)  -- fancy nongreedy kleene star
(/+=),(/+?=)  :: Show a    =>   Parser a        -> SLParser b  -> SLParser ([a],b)  -- lookahead, greedy and nongreedy
(/*=),(/*?=)  :: Show a    =>   Parser a        -> SLParser b  -> SLParser ([a],b)  -- lookahead, greedy and nongreedy

($+/)  :: (Show a, Show b) =>          (a -> b -> c) -> SLParser (a, b) -> SLParser c  -- uncurry two args to the initial constructor
(/+/)  :: (Show a, Show b) => SLParser (a -> b -> c) -> SLParser (a, b) -> SLParser c  -- uncurry two args as part of the chain
($>/)  :: (Show a, Show b) =>          (a -> b -> c) -> SLParser (a, b) -> SLParser c  -- same as $+/ but consume godeepers first
(|>/)  :: (Show a, Show b) => SLParser (a -> b -> c) -> SLParser (a, b) -> SLParser c  -- same as /+/ but consume godeepers first

-- * terminal
(|*<)  :: Show a           => SLParser (a -> b) -> SLParser a       ->    Parser b       -- end         fancy fancy
(|><)  :: Show a           => SLParser (a -> b) ->   Parser a       ->    Parser b       -- end         fancy plain
(|<$)  ::                     SLParser  a       -> (Int->Parser ()) ->    Parser a       -- end         fancy plain manual undeeper -- used for undeepers
(|--)  ::                     SLParser  a       -> (Int->Parser ()) ->  SLParser a       -- end         tell a function (usually debugPrint) how deep we are
(->|)  ::                     SLParser  a       -> Int              ->  SLParser a       -- must consume at least this many GoDeepers before proceeding

(>><)  :: Show a           =>   Parser       a                      ->    Parser a       -- consume, parse, undeeper
(>><) = manyIndentation


--
(|?|)  :: Show a => SLParser a ->          SLParser (Maybe a) -- optional for an SLParser
(|?|) p = debugNameSL "|?| optional something" do
  try (do
          out <- (|>>) p
          pure $ Just out)
    <|> pure Nothing

-- we have convenience combinators for some, many, and optional.
someSL          :: Show a => SLParser a ->       SLParser [a] -- some
manySL          :: Show a => SLParser a ->       SLParser [a] -- many
manyLiftSL      :: Show a =>   Parser a ->       SLParser [a] -- many
someLiftSL      :: Show a =>   Parser a ->       SLParser [a] -- some
someSLPlain     :: Show a =>   Parser a ->         Parser [a] -- some plain
manySLPlain     :: Show a =>   Parser a ->         Parser [a] -- some plain
liftSLOptional  :: Show a =>   Parser a -> SLParser (Maybe a) -- optional

{- so, how do these things work in action? here are some examples: -}

-- typical usage:
_fourIs :: Parser (MyToken,MyToken,MyToken,MyToken)
_fourIs = debugName "fourIs" $
  (,,,)
    $>| pT
    |>| pT
    |>| pT
    |>< pT
  where pT = debugName "Is/An" $ pToken Is <|> pToken A_An

-- instead of ending with a |>< you can keep it going and end with an explicit undeepers.
_threeIs :: Parser (MyToken, (MyToken,MyToken) ,MyToken)
_threeIs = debugName "threeIs" $
  (,,)
    $>| pT
    |*| pTT
    |>| pT
    |<$ undeepers
  where pT  = debugName "Is" $ pToken Is
        pTT = debugNameSL "(pT,pT)" $ (,) $>| pT |>| pT
        --- because the final sigil in the chain ends with a |, pTT is suitable for use with a * in the parent expression

_twoIsSomeAn :: Parser (MyToken,[MyToken],MyToken)
_twoIsSomeAn = debugName "twoIsSomeAn" $
  (,,)
    $*| pT
    |*| pAn
    |*< pT
  where pT  = liftSL $ pToken Is
        pAn = someLiftSL $ pToken A_An

-- implementation of the combinators
manyLiftSL x    = manySL $ liftSL x            -- usage: manyLiftSL pOtherVal   is       many pOtherVal
someLiftSL x    = someSL $ liftSL x            -- usage: someLiftSL pOtherVal   is       some pOtherVal
liftSLOptional p =         liftSL (optional p) -- usage: liftSLOptional pOtherVal   is   optional pOtherval

someSLPlain x = someLiftSL x |<$ undeepers     -- some pOtherVal and then undeepers
manySLPlain x = manyLiftSL x |<$ undeepers     -- many pOtherVal and then undeepers


-- | sl version of `some`, which consumes some deepers between each step
someSL p = debugNameSL "someSL" $ (:) <$> p <*> many (try $ some slDeeper *> p)
-- someSL p = debugNameSL "|:| some" do
--   p1 <- debugNameSL "|:| base parser" p
--   ps <- try deeper <|> nomore
--   pure (p1:ps)
--   where
--     deeper = debugName "|:| deeper" do
--       _ <- debugName "|:| some GoDeeper" $ some slDeeper
--       someSL p
--     nomore = debugName "|:| noMore" $ pure []
-- infixl 4 |:|

-- manySL :: Show a => SLParser a -> SLParser [a]
-- | sl version of `many`, which consumes some deepers between each step
manySL p = debugNameSL "|.| manyLike" do
  try (someSL p) <|> pure []

f $>| p2 = do
  r <- liftSL $ debugName "$>|" p2
  pure $ f r
infixl 4 $>|

f +>| n = do
  mkSL $ pure (f, n)
infixl 4 +>|

f >>| p2 = do
  r <- debugNameSL ">>|" $ ($>>) p2
  pure (f r)
infixl 4 >>|

f $*| p2 = do
  f <$>  debugNameSL "$*|" p2
infixl 4 $*|

f >*| p2 = f $*| (|>>) p2
infixl 4 >*|

p1 |>| p2 = do
  l <- p1
  r <- debugNameSL "|>| calling $>> to consume goDeeper" $ ($>>) p2
  pure $ l r
infixl 4 |>|

p1 |*| p2 = p1 <*> (|>>) p2
infixl 4 |*|

p1 |-| p2 = p1 |=| liftSL p2
infixl 4 |-|, |=|

p1 |=| p2 = p1 <*> p2

-- | one or more of the LHS as needed to also match RHS; similar to manyTill
-- (p1)+?(p2)
p1 +?| p2 = do
  l     <- liftSL $ optional p1
  when (isNothing l) slDeeper
  (r,x) <- p1 *?| p2
  pure (maybe r (:r) l,x)

-- | (p1)+(?=p2) greedy lookahead, some
p1 /+= p2 = do
  l     <- liftSL $ optional p1
  when (isNothing l) slDeeper
  (r,x) <- p1 /*= p2
  pure (maybe r (:r) l, x)

-- | (p1)*(?=p2) positive greedy lookahead, many
p1 /*= p2 = try (do
                    x   <- censorSL (const 0) $ try (lookAhead p2)
                    (debugPrint "/*= lookAhead succeeded, recursing greedily" >> try (p1 /+= p2))
                      <|>
                      (debugPrint "/*= lookAhead succeeded, greedy recursion failed (no p1); pureing p2." >> pure ([],x))
                )
             <|> (debugPrint "/*= lookAhead failed, delegating to plain /+=" >> try (p1 /+= p2))

-- | (p1)+?(?=p2) nongreedy lookahead, some
p1 /+?= p2 = do
  l      <- liftSL $ optional p1
  when (isNothing l) slDeeper
  (r,x)  <- p1 /*?= p2
  pure (maybe r (:r) l, x)

-- | (p1)*?(?=p2) nongreedy lookahead, many
p1 /*?= p2 = try (do
                    x   <- censorSL (const 0) $ try (lookAhead p2)
                    debugPrint "/*?= lookAhead succeeded, nongreedy, so pureing p2." >> pure ([],x)
                 )
             <|> (debugPrint "/*= lookAhead failed, delegating to plain /+?=" >> try (p1 /+?= p2))

infixl 5 +?|, *?|, |+?, |*? , /+=, /*=, /+?=, /*?=
p1 *?| p2 =  try (do
                     x'   <- p2
                     pure ([],x'))
             <|> (p1 +?| p2)

-- the above is very similar to
-- λ: runParser (chunk "f" *> (Text.Megaparsec.some $ chunk "o") *> (Text.Parser.Combinators.manyTill (chunk "b") (lookAhead $ chunk "bar")) <* chunk "barqux" <* Text.Megaparsec.eof) "" "foobbbbbbarqux"

-- <interactive>:32:1: warning: [-Wtype-defaults]
--     • Defaulting the following constraints to type ‘()’
--         (Show e0) arising from a use of ‘print’ at <interactive>:32:1-196
--         (Ord e0) arising from a use of ‘it’ at <interactive>:32:1-196
--     • In a stmt of an interactive GHCi command: print it
-- Right ["b","b","b","b","b"]

p1 |+? p2 = do
  l     <- p1 <* slDeeper
  (r,x) <- p1 |*? p2
  pure (l:r,x)

p1 |*? p2 = try (do
                    x'   <- p2
                    pure ([],x'))
            <|> (p1 |+? p2)

f $+/ p = uncurry f <$> p
infixl 4 $+/

p1 /+/ p2 = do
  (uncurry <$> p1 <*> p2)
    |-- \n -> debugPrint [i|/+/ pending #{n} UnDeepers|]
infixl 4 /+/

p1 $>/ p2 = debugPrintSL "$>/" >> p1 $+/ (|>>) p2

p1 |>/ p2 = debugPrintSL "|>/" >> p1 /+/ (|>>) p2
infixl 4 $>/, |>/

p1 |>< p2 = p1 |>| p2 |<$ undeepers
infixl 4 |><

p1 |*< p2 = p1 |*| p2 |<$ undeepers
infixl 4 |*<

p1 |<$ p2 = do
  (result, n) <- runSL p1
  p2 n
  pure result
infixl 4 |<$

p1 |-- p2 = mkSL do
  (result, n) <- runSL p1
  p2 n
  pure (result, n)
infixl 4 |--

l ->| n = do
  debugPrint [i|->| trying to consume #{n} GoDeepers|]
  f <- l
  _ <- godeeper n
  debugPrint "->| success"
  pure f

infixl 4 ->|

howDeep :: SLParser Int
howDeep = mkSL do
  (_, n) <- runSL $ pure ()
  pure (n,n)

-- | Complete an SL parser and consume any outstanding UnDeepers
finishSL :: SLParser a -> Parser a
finishSL p = p |<$ undeepers

-- | Like `someUndeepers`, but only consumes up to n UnDeepers
upToNUndeepers :: Int -> SLParser ()
upToNUndeepers 0 = debugName "upToNUndeepers(0)/done" $ pure ()
upToNUndeepers n = debugName [i|upToNUndeepers(#{n})/undeeper|] do
  (slUnDeeper *> upToNUndeepers (n-1))
    <|> debugPrint [i|upToNUndeepers: remaining: #{n}|]

-- consume all the UnDeepers that have been stacked off to the right
-- which is to say, inside the snd of the Parser (_,Int)

undeepers :: Int -> Parser ()
undeepers n
  | n < 0 =
      debugName "undeepers" $ fail "undeepers: negative number of undeepers"
  | otherwise = debugName "undeepers" do
      debugPrint [i|sameLine/undeepers: reached end of line; now need to clear #{n} UnDeepers|]
      count n $ pToken UnDeeper
      debugPrint "sameLine: success!"

godeeper :: Int -> SLParser ()
godeeper n = mkSL $ debugName [i|godeeper #{n}|] do
  count n $ pToken GoDeeper
  debugPrint "matched!"
  pure ((), n)

manyUndeepers :: SLParser ()
manyUndeepers = debugNameSL "manyUndeepers" do
  (slUnDeeper >> manyUndeepers) <|> pure ()

someUndeepers :: SLParser ()
someUndeepers = debugNameSL "someUndeepers" do
  slUnDeeper
  manyUndeepers

-- | consume any GoDeepers, then parse -- plain
($>>) = (|>>) . liftSL
infixl 4 $>>

-- | consume any GoDeepers, then parse -- fancy
(|>>) p = do
  try recurse <|> base
  where
    base = debugName "|>>/base" do
      out <- p
      debugPrint [i||>>/base got #{show out}|]
      pure out
    recurse = debugName "|>>/recurse" do
      slDeeper >> (|>>) p
infixl 4 |>>

-- consume zero or more undeepers then parse the thing on the right.
-- performs backtracking to support multiple levels
-- plain
p1 |<| p2 = debugPrintSL "|<|" >> p1 |<* liftSL p2
infixl 4 |<|

p1 |<> p2 = debugPrintSL "|<>" >> p1 |<* ($>>) p2
infixl 4 |<>

p1 |^| p2 = do
  debugPrintSL "|^|"
  l <- p1
  _  <- debugName "|^| deeps" $ some slDeeper <|> many slUnDeeper
  l <$> p2
infixl 4 |^|

-- fancy
p1 |<* p2 = do
  debugPrint "|<* starting"
  l <- p1
  r <- debugName "|<*/parent" $ try goleft <|> base
  pure $ l r
  where
    base = debugName "|<*/base" p2
    goleft = do
      debugPrint "|<*/recurse"
      uds <- some slUnDeeper
      out <- p2
      debugPrint [i||<*/recurse matched #{length uds} UnDeepers|]
      pure out
infixl 4 |<*

-- indent at least 1 tab from current location
someIndentation :: Show a => Parser a -> Parser a
someIndentation p = debugName "someIndentation" $
  myindented $ manyIndentation p

someIndentation' :: Parser a -> Parser a
someIndentation' = myindented' . manyIndentation'

-- 0 or more tabs indented from current location
manyIndentation :: Show a => Parser a -> Parser a
manyIndentation p =
  try (debugName "manyIndentation/leaf?" p)
  <|>
  debugName "manyIndentation/deeper; calling someIndentation" (try $ someIndentation p)

manyIndentation' :: Parser a -> Parser a
manyIndentation' p =
  try p
  <|>
  try (someIndentation' p)

myindented :: (Show a) => Parser a -> Parser a
myindented = between
             (debugName "myindented-GoDeeper" $ pToken GoDeeper)
             (debugName "myindented-UnDeeper" $ pToken UnDeeper)

myindented' :: Parser a -> Parser a
myindented' = between
             (debugName "myindented: consuming GoDeeper" $ pToken GoDeeper)
             (debugName "myindented: consuming UnDeeper" $ pToken UnDeeper)

myoutdented :: (Show a) => Parser a -> Parser a
myoutdented = between
              (debugName "outdented: consuming UnDeeper" $ pToken UnDeeper)
              (debugName "outdented: consuming GoDeeper" $ pToken GoDeeper)
  --
-- maybe move this to indented.hs
--

-- everything in p2 must be at least the same depth as p1
indented :: (Show a, Show b) => Int -> Parser (a -> b) -> Parser a -> Parser b
indented d p1 p2 = do
  f     <- p1
  y     <- case d of
    0 -> manyIndentation p2
    _ -> someIndentation p2
  pure $ f y

indentedTuple :: (Show a, Show b) => Int -> Parser a -> Parser b -> Parser (a,b)
indentedTuple d p1 = indented d $ (,) <$> p1

-- pure one or more items at the same depth.
-- the interesting thing about this function is the *absence* of someIndentation/manyIndentation
sameDepth, sameMany :: (Show a) => Parser a -> Parser [a]
sameDepth p = debugName "sameDepth" $ some p
sameMany  p = debugName "sameMany"  $ many p

indentedTuple0, indentedTuple1 :: (Show a, Show b) => Parser a -> Parser b -> Parser (a,b)
indentedTuple0 = indentedTuple 0
infixr 4 `indentedTuple0`

indentedTuple1 = indentedTuple 1
infixr 4 `indentedTuple1`

indented0, indented1 :: (Show a, Show b) => Parser (a -> b) -> Parser a -> Parser b
indented0 = indented 0
infixl 4 `indented0`

indented1 = indented 1
infixl 4 `indented1`

-- while an "indent2" is easy enough -- Constructor <$> pOne `indentChain` pTwo
-- an indent3 isn't as easy as just stacking on another      `indentChain` pThree
-- you have to do it this way instead.
indent3 :: (Show a, Show b, Show c, Show d) => (a -> b -> c -> d) -> Parser a -> Parser b -> Parser c -> Parser d
indent3 f p1 p2 p3 = debugName "indent3" do
  p1' <- p1
  someIndentation $ liftA2 (f p1') p2 $ someIndentation p3

-- [TODO] deprecate these in favour of slparser or something even better. this is janky.
optIndentedTuple :: (Show a, Show b) => Parser a -> Parser b -> Parser (a, Maybe b)
optIndentedTuple p1 p2 = debugName "optIndentedTuple" do
  (,) <$> p1 `optIndented` p2

optIndented :: (Show a, Show b) => Parser (Maybe a -> b) -> Parser a -> Parser b
optIndented p1 p2 = debugName "optIndented" do
  f <- p1
  y <- optional $ someIndentation p2
  pure $ f y
infixl 4 `optIndented`

-- let's do us a combinator that does the same as `indentedTuple0` but in applicative style
indentChain :: Parser (a -> b) -> Parser a -> Parser b
indentChain p1 p2 = p1 <*> someIndentation' p2
infixl 4 `indentChain`

showStack :: Parser String
showStack = do
  callStack <- asks parseCallStack
  pure $ intercalate " > " $ reverse callStack

pAnyText :: Parser Text.Text
pAnyText = tok2text <|> pOtherVal

tok2text :: Parser Text.Text
tok2text = choice
    [ "IS"     <$ pToken Is
    , "&&"     <$ pToken TokAnd
    , "||"     <$ pToken TokOr
    , "SUM"    <$ pToken TokSum
    , "PRODUCT"<$ pToken TokProduct
    , "MINUS"  <$ pToken TokMinus
    , "DIVIDE" <$ pToken TokDivide
    , "Modulo" <$ pToken TokModulo
    , "=="     <$ pToken TokEQ
    , "<"      <$ pToken TokLT
    , "<="     <$ pToken TokLTE
    , ">"      <$ pToken TokGT
    , ">="     <$ pToken TokGTE
    , "IN"     <$ pToken TokIn
    , "NOT IN" <$ pToken TokNotIn
    ]

-- | Like `\m -> do a <- m; tell [a]; pure a` but add the value before the child elements instead of after.
--
-- This supports the defintion of inline sub-rules using MEANS.
tellIdFirst :: (Functor m) => WriterT (DList w) m w -> WriterT (DList w) m w
tellIdFirst = mapWriterT . fmap $ \(a, m) -> (a, singeltonDL a <> m)

pToken :: MyToken -> Parser MyToken
pToken c = pTokenMatch (== c) $ pure c

-- | Parse tokens that are not MyToken
pTokenish :: HasToken a => a -> Parser a
pTokenish c = c <$ pTokenMatch (== tok) (pure tok)
  where
    tok = tokenOf c

pTokenAnyDepth :: MyToken -> Parser MyToken
pTokenAnyDepth c = pTokenMatch (== c) $ pure c

pTokenOneOf :: NonEmpty MyToken -> Parser MyToken
pTokenOneOf cs = pTokenMatch (`elem` cs) cs

pretendEmpty :: Parser a -> Parser a
pretendEmpty = liftRawPFun iPretendEmpty

-- | Like 'try' but allows backtracking on success as well (as long as no later step consumes tokens before the branching).
iPretendEmpty :: (Stream s, Ord e) => Parsec e s a -> Parsec e s a
iPretendEmpty pt = MPInternal.ParsecT \s _ _ eok eerr ->
  let eerr' err _ = eerr err s
  in MPInternal.unParser pt s eok eerr' eok eerr'

runOnErrors ::
  (forall b. MPInternal.Consumption -> ParseError MyStream Void -> State MyStream Void -> Identity b -> Identity b) ->
  Parser a ->
  Parser a
runOnErrors f = liftRawPFun $ iRunOnErrors f

iRunOnErrors ::
  (Stream s, Ord e, Monad m) =>
  (forall b. MPInternal.Consumption -> ParseError s e -> State s e -> m b -> m b) ->
  ParsecT e s m a ->
  ParsecT e s m a
iRunOnErrors f pt = MPInternal.ParsecT \s cok cerr eok eerr ->
  let cerr' err s' = f MPInternal.Consumed err s' (cerr err s')
      eerr' err s' = f MPInternal.NotConsumed err s' (eerr err s')
  in MPInternal.unParser pt s cok cerr' eok eerr'
