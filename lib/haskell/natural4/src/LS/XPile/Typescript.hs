{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NamedFieldPuns #-}
module LS.XPile.Typescript where

-- | the job of this module is to output valid typescript class definitions, decision functions, and variable instances.

-- consider: https://hackage.haskell.org/package/aeson-typescript
-- not suitable because L4 allows users to define their own types which are not known to Haskell's type system.

import Prettyprinter

import AnyAll
import LS.PrettyPrinter 
import L4.Syntax as CoreL4

import LS.Types as SFL4
import L4.Annotation
import LS.Interpreter

import Data.Functor ( (<&>) )

import Data.Tuple (swap)
import qualified Data.Map as Map
import qualified Data.Text as T
import Data.Maybe (catMaybes, fromMaybe, isJust)
import qualified Data.List.NonEmpty as NE
import Data.Graph.Inductive
import Data.Graph.Inductive.Query.DFS


asTypescript :: [SFL4.Rule] -> Doc ann
asTypescript rs =
  let clstable  = classHierarchy rs
      scopetabs = symbolTable rs
  in
    vsep [ tsClasses clstable
         , jsInstances scopetabs
         ]

tsClasses :: ClsTab -> Doc ann
tsClasses ct@(CT ch) =
  vsep [ "class" <+> snake_case [className] <>
         case clsParent ct className of
           Nothing       -> mempty
           (Just parent) -> " extends" <+> pretty parent
         -- attributes of the class are shown as decls
         <+> lbrace <> Prettyprinter.line
         <> indent 2 ( vsep [ snake_case [attrname] <>
                              case attrType children attrname of
                                Just t -> " :" <+> prettySimpleType snake_inner t
                                Nothing -> ""
                              <> semi
                          | attrname <- getCTkeys children
                          -- [TODO] finish out the attribute definition -- particularly tricky if it's a DECIDE
                          ] )
         <> Prettyprinter.line <> rbrace <> Prettyprinter.line
       | className <- reverse $ topsorted ct
       , (Just (ctype, children)) <- [Map.lookup className ch]
       ]

-- the classes need to be topologically sorted because typescript is picky about that
type MyClassName = EntityType

topsorted :: ClsTab -> [MyClassName]
topsorted ct =
  [ cn
  | n <- topsort asGraph
  , (Just cn) <- [Map.lookup n idToType]
  ]
  where
    allTypes = allClasses ct -- ++ allSymTypes stabs [TODO] if it turns out there are hidden classnames lurking in the symbol table
    allClasses :: ClsTab -> [MyClassName]
    allClasses = getCTkeys
    -- first let's assign integer identifiers to each type found in the class hierarchy
    typeToID = Map.fromList (zip allTypes [1..])
    idToType = Map.fromList $ swap <$> Map.toList typeToID
    asGraph :: Gr MyClassName ()
    asGraph =
      -- there are a couple different kinds of dependencies...
      let child2parent = getInheritances ct       -- child depends on parent
          class2attrtypes = [ (cn, ut)            -- class depends on attribute types
                            | cn <- getCTkeys ct
                            , ts <- getAttrTypesIn ct cn
                            , Right ut <- [getUnderlyingType ts]
                            ]
      in mkGraph (Map.toList idToType) (myEdges (child2parent ++ class2attrtypes))
    myEdges :: [(MyClassName, MyClassName)] -> [(Int, Int, ())]
    myEdges abab = [ (aid, bid, ())
                   | (a,b) <- abab
                   , (Just aid) <- [Map.lookup a typeToID]
                   , (Just bid) <- [Map.lookup b typeToID]
                   ]
-- todo: var GLOBALS = [ ... ]

jsInstances :: ScopeTabs -> Doc ann
jsInstances sctabs =
  vsep [ "//" <+> scopenameStr scopename <+> "scope" <> Prettyprinter.line
         <> vsep [ "const" <+> snake_case mt <+> prettyMaybeType snake_inner (getSymType symtype) <+> equals <+> nest 2 value <> Prettyprinter.line
                 | (mt, (symtype, vals)) <- Map.toList symtab'
                 , value <- case vals of
                              -- what we should do is gather all the paramtexts and join them in a single dictionary,
                              -- rather than assume that all the HC2 are paramtexts.
                              HC2 { hHead = RPParamText {} } : _ -> [lbrace <> Prettyprinter.line <> asValuePT vals <> Prettyprinter.line <>
                                                                     rbrace <> Prettyprinter.line]
                              _                                  -> asValue <$> vals
                 ]
         <> Prettyprinter.line
         <> "const GLOBALS" <+> equals <+> list [ snake_case mt | mt <- Map.keys symtab' ] <> semi
         <> Prettyprinter.line
       | (scopename , symtab') <- Map.toList sctabs
       ]
  where
    scopenameStr [] = "globals"
    scopenameStr x  = snake_case x

asValue :: HornClause2 -> Doc ann
asValue hc2@(HC2 { hHead = RPMT        _ })               = "value" <+> colon <+> dquotes (pretty (hHead hc2))
asValue hc2@(HC2 { hHead = RPConstraint  mt1 rprel mt2 }) = snake_case mt1 <+> colon <+> dquotes (snake_case mt2)
asValue hc2@(HC2 { hHead = RPBoolStructR mt1 rprel bsr }) = snake_case mt1 <+> colon <+> "(some => lambda)"
asValue hc2@(HC2 { hHead = RPParamText pt })              = pretty (PT4 pt)

asValuePT :: [HornClause2] -> Doc ann
asValuePT hc2s = vsep [ pretty (PT4 pt) <> comma
                      | HC2 { hHead = RPParamText pt } <- hc2s ]
                 
