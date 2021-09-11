{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE TypeOperators     #-}

module Main where

import AnyAll
import qualified Data.Map.Strict        as Map
import qualified Data.Text.Lazy         as TL
import qualified Data.ByteString.Lazy as B
import           Control.Monad (forM_, when, guard)
import System.Environment
import Data.Maybe

import Data.Aeson
import Data.Aeson.Types (parseMaybe)
import Options.Generic

data Opts = Opts { demo :: Bool }
  deriving (Generic, Show)
instance ParseRecord Opts

-- consume JSON containing
-- - an AnyAll Item
-- - a Marking showing user input to date and defaults

main :: IO ()
main = do
  opts <- getRecord "anyall"
  when (demo opts) $ maindemo
  guard (not $ demo opts)
  mycontents <- B.getContents
  let myinput = (decode mycontents) :: Maybe Object
      jsonin = fromJust myinput
  guard $ isJust myinput
  let poos = flip parseMaybe jsonin $ \obj -> do
        poo <- obj .: "poo"
        return (poo <> poo :: TL.Text)
  putStrLn $ maybe "unable to parse input for poo text" show poos
  
maindemo :: IO ()
maindemo = do
  forM_
    [ Map.empty
    , Map.fromList [("walk",  Left $ Just True)
                   ,("run",   Left $ Just True)
                   ,("eat",   Left $ Just True)
                   ,("drink", Left $ Just False)]
    , Map.fromList [("walk",  Left $ Just True)
                   ,("run",   Left $ Just False)
                   ,("eat",   Left $ Just True)
                   ,("drink", Left $ Just False)]
    , Map.fromList [("walk",  Right $ Just True)
                   ,("run",   Right $ Just True)
                   ,("eat",   Right $ Just True)
                   ,("drink", Left  $ Just False)]
    , Map.fromList [("walk",  Right $ Just True)
                   ,("run",   Left  $ Just False)
                   ,("eat",   Right $ Just True)
                   ,("drink", Right $ Just True)]
    , Map.fromList [("walk",  Right $ Just True)
                   ,("run",   Right $ Just False  )
                   ,("eat",   Right $ Just True)
                   ,("drink", Left  $ Just True)]
    ] $ ppQTree (AnyAll.All (Pre "all of")
                 [ Leaf "walk"
                 , Leaf "run"
                 , AnyAll.Any (Pre "either")
                   [ Leaf "eat"
                   , Leaf "drink" ] ])
  putStrLn "* LEGEND"
  putStrLn ""
  putStrLn "  <    >  View: UI should display this node or subtree."
  putStrLn "                Typically this marks either past user input or a computed value."
  putStrLn "  [    ]  Ask:  UI should ask user for input."
  putStrLn "                Without this input, we cannot make a hard decision."
  putStrLn "  (    )  Hide: UI can hide subtree or display it in a faded, grayed-out way."
  putStrLn "                This subtree has been made irrelevant by other input."
  putStrLn ""
  putStrLn "   YES    user input True"
  putStrLn "    NO    user input False"
  putStrLn "     ?    user input Unknown"
  putStrLn ""
  putStrLn "   yes    default True"
  putStrLn "    no    default False"
  putStrLn "          default Unknown"
  putStrLn ""
  putStrLn "  Hard means we ignore defaults and consider user input only."
  putStrLn "  Soft means we consider defaults as well to arrive at the answer."
