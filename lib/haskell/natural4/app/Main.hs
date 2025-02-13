{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Main (main) where

import AnyAll.BoolStruct (alwaysLabeled)
import AnyAll.SVGLadder (defaultAAVConfig)
import Control.Arrow ((>>>))
import Control.Monad (liftM, unless, when)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as ByteString (ByteString, writeFile)
import Data.ByteString.Lazy.UTF8 (toString)
import Data.Either (lefts, rights)
import Data.Foldable qualified as DF
import Data.HashMap.Strict qualified as Map
import Data.List (intercalate, isPrefixOf, partition, sortOn)
import Data.String.Interpolate (i, __i)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Data.Time.Clock (getCurrentTime)
import Data.Time.ISO8601 (formatISO8601Millis)
import LS qualified as SFL4
import LS.DataFlow (dataFlowAsDot)
import LS.Interpreter
  ( expandClauses,
    getAndOrTree,
    l4interpret,
    onlyTheItems,
  )
import LS.NLP.NLG
  ( allLangs,
    expandRulesForNLG,
    langEng,
    myNLGEnv,
    nlg,
    printLangs,
  )
import LS.XPile.CoreL4
  ( sfl4ToASP,
    sfl4ToBabyl4,
    sfl4ToCorel4,
    sfl4ToDMN,
    sfl4ToEpilog,
  )
import LS.XPile.Edn.L4ToEdn qualified as Edn
import LS.XPile.ExportTypes
  ( rulesToHaskellTp,
    rulesToJsonSchema,
    rulesToPrologTp,
    rulesToUISchema,
  )
import LS.XPile.GFTrees (gftrees)
import LS.XPile.IntroBase (toBase)
import LS.XPile.IntroBasic (toBasic)
import LS.XPile.IntroLog (toLog)
import LS.XPile.IntroReader (defaultReaderEnv, toReader)
import LS.XPile.IntroShoehorn (toShoehorn)
import LS.XPile.IntroTrivial (toTrivial)
import LS.XPile.JSONRanges (asJSONRanges)
import LS.XPile.Logging
  ( XPileLogW,
    fmapE,
    mutter,
    pShowNoColorS,
    xpLog,
  )
import LS.XPile.LogicalEnglish (toLE)
import LS.XPile.Markdown (bsMarkdown)
import LS.XPile.MathLang (toMathLangGen, toMathLangMw)
import LS.XPile.Maude qualified as Maude
import LS.XPile.NaturalLanguage (toNatLang)
import LS.XPile.Org (toOrg)
import LS.XPile.Petri (toPetri)
import LS.XPile.Prolog (rulesToProlog, rulesToSCasp)
import LS.XPile.Purescript (translate2PS)
import LS.XPile.SVG qualified as AAS
import LS.XPile.Typescript (asTypescript)
import LS.XPile.Uppaal qualified as Uppaal
import LS.XPile.VueJSON
  ( checklist,
    groundrules,
    itemRPToItemJSON,
    toVueRules,
  )
import Options.Generic (unwrapRecord)
import System.Directory
  ( createDirectoryIfMissing,
    createFileLink,
    renameFile,
  )
import System.FilePath ((-<.>), (</>))
import System.IO.Unsafe (unsafeInterleaveIO)
import Text.Pretty.Simple (pPrint, pShowNoColor)
import Text.Regex.PCRE.Heavy qualified as PCRE
import Text.XML.HXT.Core qualified as HXT


myTraceM :: String -> IO ()
myTraceM = SFL4.myTraceM

main :: IO ()
main = do
  opts     <- unwrapRecord "mp"
  rc       <- SFL4.getConfig opts
--  putStrLn "main: doing dumpRules"
  rules    <- SFL4.dumpRules opts
  let l4i  = l4interpret SFL4.defaultInterpreterOptions rules
  iso8601  <- now8601

  let toworkdir   = not $ null $ SFL4.workdir opts
      workuuid    = SFL4.workdir opts </> SFL4.uuiddir opts

  -- Bits that have to do with natural language processing and generation
  nlgLangs <- unsafeInterleaveIO allLangs               -- [TODO] Edsko is not a fan and has a whole talk about why we should not use this.
  strLangs <- unsafeInterleaveIO $ printLangs allLangs
  (engE,engErr) <- xpLog <$> langEng
  -- [NOTE] the Production Haskell book gives better ways to integrate Logging with IO
  case engE of
    Left err -> putStrLn $ unlines $ "natural4: encountered error when obtaining langEng" : err
    Right eng -> do
      (nlgEnv, nlgEnvErr)  <- unsafeInterleaveIO $ xpLog <$> myNLGEnv l4i eng -- Only load the NLG environment if we need it.
      (allNLGEnv, allNLGEnvErr) <- unsafeInterleaveIO do
        xps <- traverse (myNLGEnv l4i) nlgLangs
        return (xpLog $ sequenceA xps)

    -- codepath that depends on nlgEnv succeeding
      case nlgEnv of
        Left  err     -> putStrLn $ unlines $ "natural4: encountered error while obtaining myNLGEnv" : err
        Right nlgEnvR -> do

          when (SFL4.toChecklist rc) do
            let (checkls, checklsErr) = xpLog $ checklist nlgEnvR rc rules
            pPrint checkls

          when (SFL4.tocheckl  opts) do -- this is deliberately placed here because the nlg stuff is slow to run, so let's leave it for last -- [TODO] move this to below, or eliminate this entirely
            let (asCheckl, asChecklErr) = xpLog $ checklist nlgEnvR rc rules
                tochecklFN              =  workuuid </> "checkl"
            mywritefile2 True tochecklFN   iso8601 "txt" (show asCheckl) asChecklErr

          when (SFL4.togftrees opts) do
            let (togftreesFN,    (asGftrees, asGftreesErr)) = (workuuid </> "gftrees"
                                                              , xpLog $ gftrees nlgEnvR rules)
            mywritefile2 True togftreesFN iso8601 "gftrees" (pShowNoColorS asGftrees) asGftreesErr

          let allNLGEnvErrors = mconcat $ lefts allNLGEnv
          unless (null allNLGEnvErrors) do
            putStrLn "natural4: encountered error while obtaining allNLGEnv"
            DF.traverse_ putStrLn allNLGEnvErrors

          let allNLGEnvR = rights allNLGEnv

          when (SFL4.tomd      opts) do
            let (tomarkdownFN, asMD)     = (workuuid </> "md",  bsMarkdown allNLGEnvR rules)
            mywritefile True tomarkdownFN iso8601 "md" =<< asMD

          -- some transpiler targets are a bit slow to run so we offer a way to call them specifically
          -- natural4-exe --workdir workdir --only md inputfile.csv
          -- will produce only the workdir output file
            when (toworkdir && not (null $ SFL4.uuiddir opts) && not (null $ SFL4.only opts)) do
              when (SFL4.only opts `elem` ["md", "tomd"]) $ mywritefile True tomarkdownFN iso8601 "md" =<< asMD

          when (SFL4.topurs    opts) do
            let (topursFN,    (asPursstr, asPursErr)) =
                  (workuuid </> "purs"
                  , xpLog $ mutter "* main calling translate2PS" >>
                    fmapE (<> ("\n\n" <> "allLang = [\"" <> strLangs <> "\"]")) (translate2PS allNLGEnvR nlgEnvR rules)
                  )

            mywritefile2 True topursFN     iso8601 "purs" (commentIfError "-- ! -- " asPursstr) (engErr <> allNLGEnvErr <> asPursErr)



          when (SFL4.toNLG rc && null (SFL4.only opts)) do
            DF.for_ allNLGEnvR \env -> do
                      -- using expandRulesForNLG for demo purposes here
                     -- I think it's better suited for questions, not full NLG
                      -- because everything is so nested, not a good reading experience. Original is better, where it's split in different rules.
                      naturalLangSents <- nlg env `traverse` expandRulesForNLG env rules
                      DF.for_ naturalLangSents $ putStrLn . Text.unpack

  -- end of the section that deals with NLG

  let (toprologFN,  asProlog)                 = (workuuid </> "prolog",   rulesToProlog rules)
      (toprologTpFN,asPrologTp)               = (workuuid </> "prologTp", rulesToPrologTp rules)
      (tohaskellTpFN,asHaskellTp)             = (workuuid </> "haskellTp", rulesToHaskellTp rules)
      (tojsonTpFN,  asJsonTp)                 = (workuuid </> "jsonTp",   rulesToJsonSchema rules)
      (tojsonUIFN,  asJsonUI)                 = (workuuid </> "jsonUI",   rulesToUISchema rules)
      (toscaspFN,   asSCasp)                  = (workuuid </> "scasp",    rulesToSCasp rules)
      (topetriFN,   (asPetri, asPetriErr))    = (workuuid </> "petri",    xpLog $ toPetri rules)
      (toaasvgFN,   asaasvg)                  = (workuuid </> "aasvg",    AAS.asAAsvg defaultAAVConfig l4i rules)
      (tocorel4FN,  (asCoreL4, asCoreL4Err))  = (workuuid </> "corel4",   xpLog (sfl4ToCorel4 rules))
      (tobabyl4FN,  asBabyL4)                 = (workuuid </> "babyl4",   sfl4ToBabyl4 l4i)
      (toaspFN,     (asASP, asASPErr))        = (workuuid </> "asp",      xpLog $ sfl4ToASP rules)
      (toepilogFN,  (asEpilog, asEpilogErr))  = (workuuid </> "epilog",   xpLog $ sfl4ToEpilog rules)
      (todmnFN,     asDMN)                    = (workuuid </> "dmn",      sfl4ToDMN rules)
      (tojsonFN,    asJSONstr)                = (workuuid </> "json",     toString $ encodePretty   (alwaysLabeled   $ onlyTheItems l4i))
      (tovuejsonFN, asVueJSONrules)           = (workuuid </> "vuejson",  fmap xpLog <$> toVueRules rules)

      (toIntro1FN,  asTrivial)                   = (workuuid </> "intro1",   toTrivial l4i)
      (toIntro2FN,  asBasic)                     = (workuuid </> "intro2",   toBasic   l4i)
      (toIntro3FN,  asReader)                    = (workuuid </> "intro3",   toReader  l4i defaultReaderEnv)
      (toIntro4FN,  (asLog, asLogErr))           = (workuuid </> "intro4",   xpLog $ toLog l4i defaultReaderEnv)
      (toIntro5FN,  (asShoehorn, asShoehornErr)) = (workuuid </> "intro5",   toShoehorn l4i defaultReaderEnv)
      (toIntro6FN,  (asBase,     asBaseErr))     = (workuuid </> "intro6",   toBase l4i defaultReaderEnv)

      (toMathLangGenFN,  (asMathLangGen,     asMathLangGenErr))     = (workuuid </> "mathlangGen",   toMathLangGen l4i ) 
      -- will upstream a generic xpiler + app env in the future, 
      -- and have `toMathLangGen` take that as one of its inputs

      (toMathLangMwTSFN,  (asMathLangMwTS,     asMathLangMwTSErr))     = (workuuid </> "mathlangTS",   toMathLangMw l4i defaultReaderEnv)

      (tojsrFN,     (asJSRpretty, asJSRerr))  = (workuuid </> "jsonranges",  xpLog $ asJSONRanges l4i)
      (totsFN,      (asTSpretty, asTSerr))    = (workuuid </> "ts",       xpLog $ asTypescript l4i)
      (togroundsFN, asGrounds)                = (workuuid </> "grounds",  show $ groundrules rc rules)
      (toOrgFN,     asOrg)                    = (workuuid </> "org",      toOrg l4i rules)
      (toDFGFN,     (asDFG, asDFGerr))        = (workuuid </> "dataflow", xpLog $ dataFlowAsDot l4i)

      (toLEFN, asLE)                          = (workuuid </> "logical_english",         toLE rules)
      (toNL_FN,     asNatLang)                = (workuuid </> "natlang",  toNatLang l4i)
      (toMaudeFN,   asMaude)                  = (workuuid </> "maude", Maude.rules2maudeStr rules)
      (toEdnFN, asEdn)                        = (workuuid </> "edn", Edn.l4rulesToEdnStr rules)
      (tonativeFN,  asNative)  = (workuuid </> "native",   unlines
                                   [ "-- original rules:\n"
                                   , TL.unpack (pShowNoColor rules)

                                   , "-- variable-substitution expanded AnyAll rules\n"
                                   , TL.unpack (pShowNoColor $ [ r { SFL4.clauses = expandClauses l4i 1 (SFL4.clauses r) }
                                                               | r@SFL4.Hornlike{} <- rules
                                                               ])

                                   , "\n\n-- class hierarchy:\n"
                                   , TL.unpack (pShowNoColor (SFL4.classtable l4i))

                                   , "\n\n-- symbol table:\n"
                                   , TL.unpack (pShowNoColor (SFL4.scopetable l4i))

                                   , "-- getAndOrTrees"
                                   , unlines $ (\r -> "\n-- " <> show (SFL4.ruleLabelName r) <> "\n" <>
                                                 TL.unpack (pShowNoColor $ getAndOrTree l4i 1 r)) <$> rules

                                   , "-- traverse toList of the getAndOrTrees"
                                   , unlines $ TL.unpack . pShowNoColor . traverse DF.toList . getAndOrTree l4i 1 <$> rules

                                   , "-- onlyTheItems"
                                   , TL.unpack $ pShowNoColor (onlyTheItems l4i)

                                   , "-- ItemsByRule"
                                   , TL.unpack $ pShowNoColor (SFL4.itemsByRule l4i rules)

                                   ])




  -- if --workdir is specified, and there are no --only, then we run all the things
  -- however, we can flag specific exclusions by adding the --tomd option which, counterintuitively, disables tomd
  when (toworkdir && not (null $ SFL4.uuiddir opts) && null (SFL4.only opts)) do

    when (SFL4.tonative  opts) $ mywritefile2 True toDFGFN     iso8601 "dot"  asDFG asDFGerr
    when (SFL4.tologicalenglish      opts) $ mywritefile True toLEFN      iso8601 "le"  asLE
    when (SFL4.tonative  opts) $ mywritefile True toOrgFN      iso8601 "org"  asOrg
    when (SFL4.tonative  opts) $ mywritefile True tonativeFN   iso8601 "hs"   asNative
    when (      SFL4.tocorel4  opts) $ mywritefile2 True tocorel4FN   iso8601 "l4"   (commentIfError "--" asCoreL4) asCoreL4Err
    unless (SFL4.tocorel4  opts) $ putStrLn "natural4: skipping corel4"
    when (      SFL4.tobabyl4  opts) $ mywritefile True tobabyl4FN   iso8601 "l4"   asBabyL4
    unless (SFL4.tobabyl4  opts) $ putStrLn "natural4: skipping babyl4"
    unless (SFL4.toasp     opts) $ putStrLn "natural4: skipping asp"
    when (SFL4.toasp     opts) $ putStrLn "natural4: will output asASP"
    when (SFL4.toasp     opts) $ mywritefile2 True toaspFN     iso8601 "lp"      (commentIfError "%%" asASP)    asASPErr
    when (SFL4.toepilog  opts) $ mywritefile2 True toepilogFN  iso8601 "lp"      (commentIfError "%%" asEpilog) asEpilogErr
    when (SFL4.todmn     opts) $ mywritefileDMN True todmnFN   iso8601 "dmn"  asDMN
    when (SFL4.tojson    opts) $ mywritefile True tojsonFN     iso8601 "json" asJSONstr

    when (SFL4.tointro  opts) do
      mywritefile  True toIntro1FN   iso8601 "txt"  asTrivial
      mywritefile  True toIntro2FN   iso8601 "txt"  asBasic
      mywritefile  True toIntro3FN   iso8601 "txt"  asReader
      mywritefile2 True toIntro4FN   iso8601 "txt"  asLog        asLogErr
      mywritefile2 True toIntro5FN   iso8601 "txt"  asShoehorn   asShoehornErr
      mywritefile2 True toIntro6FN   iso8601 "txt"  asBase       asBaseErr

    when (SFL4.tomathlangmw opts) do
      mywritefile2 True toMathLangMwTSFN   iso8601 "ts"  asMathLangMwTS       asMathLangMwTSErr

    -- temporarily use .txt
    when (SFL4.togenmathlang opts) do
      mywritefile2 True toMathLangGenFN   iso8601 "txt"  asMathLangGen       asMathLangGenErr


    when (SFL4.tovuejson opts) do
      -- [TODO] this is terrible. we should have a way to represent this inside of a data structure that gets prettyprinted. We should not be outputting raw JSON fragments.
      let toWriteVue =  [ ( case out' of
                              Right _ -> [__i|
                                SFL4.mt2text #{rname}:
                              |]
                              Left  _ -> "" -- this little section is inelegant
                              -- If   error, dump // "!! error"
                              -- Else dump out' <> ', \n"
                            <> commentIfError "// !! error" out' <> ", \n"
                          , err)
                        | (rname, (out, err)) <- asVueJSONrules
                        , let out' = toString . encodePretty . itemRPToItemJSON <$> out
                        ]

          vuePrefix = -- "# this is vuePrefix from natural4/app/Main.hs\n\n" <>
                      "{"
          vueSuffix = "}"
                      -- <> "\n\n# this is vueSuffix from natural4/app/Main.hs"

          jsonProhibitsComments :: String -> String
          jsonProhibitsComments = unlines . filter (not . ("//" `isPrefixOf`)) . lines

          -- [TODO] Terrible hack to make it a legal json, to remove the last trailing comma
          removeLastComma :: String -> String
          removeLastComma unlined
            | length lined > 3 = -- only if there's a valid json in there
              unlines $ take (length lined - 3) lined <> ["}"] <> drop (length lined - 2) lined
            | otherwise = unlined
            where lined = lines unlined

      mywritefile2 True tovuejsonFN iso8601 "vuejson"
        (removeLastComma $ jsonProhibitsComments $
           intercalate "\n" [vuePrefix, foldMap fst toWriteVue, vueSuffix])
        (foldMap snd toWriteVue)

    when (SFL4.toprolog  opts) $ mywritefile  True toprologFN   iso8601 "pl"   asProlog
    when (SFL4.toprologTp opts) $ mywritefile  True toprologTpFN  iso8601 "pl" asPrologTp
    when (SFL4.tohaskellTp opts) $ mywritefile True tohaskellTpFN  iso8601 "hs" asHaskellTp
    when (SFL4.tojsonTp opts)  $ mywritefile  True tojsonTpFN   iso8601 "json" asJsonTp
    when (SFL4.tojsonUI opts)  $ mywritefile  True tojsonUIFN   iso8601 "json" asJsonUI
    when (SFL4.toscasp   opts) $ mywritefile  True toscaspFN    iso8601 "pl"   asSCasp
    when (SFL4.topetri   opts) $ mywritefile2 True topetriFN    iso8601 "dot"  (commentIfError "//" asPetri) asPetriErr
    when (SFL4.tojsr     opts) $ mywritefile2 True tojsrFN      iso8601 "json" (show asJSRpretty) asJSRerr
    when (SFL4.tots      opts) $ mywritefile2 True totsFN       iso8601 "ts"   (show asTSpretty) asTSerr
    when (SFL4.tonl      opts) $ mywritefile  True toNL_FN      iso8601 "txt"  asNatLang
    when (SFL4.togrounds opts) $ mywritefile  True togroundsFN  iso8601 "txt"  asGrounds
    when (SFL4.tomaude   opts) $ mywritefile  True toMaudeFN iso8601 "natural4" asMaude
    when (SFL4.toedn     opts) $ mywritefile  True toEdnFN iso8601 "edn" asEdn
    when (SFL4.toaasvg   opts) do
      let dname = toaasvgFN </> iso8601
      if null asaasvg
        then do
        createDirectoryIfMissing True dname
        appendFile (dname </> "index" -<.> "html") "<!-- this file intentionally left blank -->"
        else DF.sequenceA_
             [ do
               mywritefile False dname (fname<>"-tiny")   ext (show svgtiny)
               mywritefile False dname (fname<>"-full")   ext (show svgfull)
               mywritefile False dname (fname<>"-anyall") "hs"   [i|#{pShowNoColor hsAnyAllTree}|]
               mywritefile False dname (fname<>"-anyall") "json" [i|#{encodePretty hsAnyAllTree}|]
               mywritefile False dname (fname<>"-qtree")  "hs"   [i|#{pShowNoColor hsQtree}|]
               mywritefile False dname (fname<>"-qjson")  "json" [i|#{encodePretty hsQtree}|]
               let fnamext = fname -<.> ext
                   displayTxt = Text.unpack $ SFL4.mt2text n
               appendFile (dname </> "index" -<.> "html")
                  [__i|
                    <li>
                      <a target="aasvg" href="#{fnamext}">
                        #{displayTxt}
                      </a>
                    </li>
                  |]
                -- "<li> " <> "<a target=\"aasvg\" href=\"" <> fnamext <> "\">" <> displayTxt <> "</a></li>\n"
           | (n,(svgtiny,svgfull,hsAnyAllTree,hsQtree)) <- sortOn (fmap SFL4.mtexpr2text . fst) $ Map.toList asaasvg
           , let (fname, ext) = (take 127 (snakeScrub (SFL4.mtexpr2text <$> n)), "svg")
           ]
      myMkLink iso8601 $ toaasvgFN </> "LATEST"

    putStrLn "natural4: output to workdir done"

  -- when workdir is not specified, --only will dump to STDOUT
  unless toworkdir do
    when (SFL4.only opts == "petri")  $
      putStrLn $ commentIfError "//" asPetri
    when (SFL4.only opts == "aatree") $
      DF.for_ rules $ pPrint . getAndOrTree l4i 1

    when (SFL4.asJSON rc) $ putStrLn asJSONstr

    when (SFL4.toBabyL4 rc) $ putStrLn $ commentIfError "--" asCoreL4

    when (SFL4.toUppaal rc) do
      pPrint $ Uppaal.toL4TA rules
      putStrLn $ Uppaal.taSysToString $ Uppaal.toL4TA rules

    when (SFL4.toGrounds rc) do
      pPrint $ groundrules rc rules

    when (SFL4.toProlog rc) $ pPrint asProlog
    when (SFL4.toSCasp  rc) $ pPrint asSCasp

    when (SFL4.only opts == "" && SFL4.workdir opts == "") $ pPrint rules
    when (SFL4.only opts == "native")  $ pPrint rules
    when (SFL4.only opts == "classes") $ pPrint $ SFL4.classtable l4i
    when (SFL4.only opts == "symtab")  $ pPrint $ SFL4.scopetable l4i

    when (SFL4.only opts == "maude") $
      putStrLn $ Maude.rules2maudeStr rules

now8601 :: IO String
now8601 = formatISO8601Millis <$> getCurrentTime

writeBSfile :: Bool -> FilePath -> FilePath -> String -> ByteString.ByteString -> IO ()
writeBSfile doLink dirname filename ext s = do
  createDirectoryIfMissing True dirname
  let mypath = dirname </> filename -<.> ext
      mylink = dirname </> "LATEST" -<.> ext
  ByteString.writeFile mypath s
  when doLink $ myMkLink (filename -<.> ext) mylink

-- | output only "stdout" to outfile
mywritefile :: Bool -> FilePath -> FilePath -> String -> String -> IO ()
mywritefile doLink dirname filename ext s = do
  createDirectoryIfMissing True dirname
  let mypath = dirname </> filename -<.> ext
      mylink = dirname </> "LATEST" -<.> ext
  writeFile mypath s
  when doLink $ myMkLink (filename -<.> ext) mylink

-- | output both "stdout" to outfile and "stderr" to outfile.err.
-- Note that if the "s" argument is itself an Either, we need to process a little bit to dump the Lefts as comments
-- and the Rights as actual desired output.
mywritefile2 :: Bool -> FilePath -> FilePath -> String -> String -> [String] -> IO ()
mywritefile2 doLink dirname filename ext s e = do
  createDirectoryIfMissing True dirname
  let mypath1    = dirname </> filename -<.> ext
      mypath2    = dirname </> filename -<.> if ext == "org" then "err" else "org"
      mylink     = dirname </> "LATEST" -<.> ext
  writeFile mypath2 (intercalate "\n" e)
  writeFile mypath1 s
  when doLink $ myMkLink (filename -<.> ext) mylink


mywritefileDMN :: Bool -> FilePath -> FilePath -> String -> HXT.IOSLA (HXT.XIOState ()) HXT.XmlTree HXT.XmlTree -> IO ()
mywritefileDMN doLink dirname filename ext xmltree = do
  createDirectoryIfMissing True dirname
  let mypath = dirname </> filename -<.> ext
      mylink = dirname </> "LATEST" -<.> ext
  HXT.runX ( xmltree HXT.>>> HXT.writeDocument [ HXT.withIndent HXT.yes ] mypath )
  when doLink $ myMkLink (filename -<.> ext) mylink

myMkLink :: FilePath -> FilePath -> IO ()
myMkLink filename mylink = do
  let mylink_tmp = [i|#{mylink}-tmp|]
  createFileLink filename mylink_tmp
  renameFile mylink_tmp mylink

snakeScrub :: [Text.Text] -> String
snakeScrub =
  Text.intercalate "-"
    >>> PCRE.gsub [PCRE.re|[^a-zA-Z0-9_\-]|\s+|] ("" :: Text.Text)
    >>> Text.unpack
    -- >>> partition (`elem` ['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "_-")
    -- >>> fst

-- | if the return value of an xpLog is a Left, dump to output file with the error message commented; otherwise dump the regular output.
commentIfError :: String -> Either XPileLogW String -> String
commentIfError commentPrefix = either (foldMap prependCommentPrefix) id
  -- Disjunction elimination, prepending the comment prefix to each line before
  -- concating when eliminating the error log (ie XPileLogW) to String.
  where
    prependCommentPrefix str = [i|#{commentPrefix} #{str}|]
