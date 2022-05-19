{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}

-- usage:
-- (base) ┌─[mengwong@solo-8] - [~/src/smucclaw/dsl/lib/haskell/anyall] - [2022-05-18 12:38:04]
-- └─[255] <git:(ladder 88053e0✱✈) > cat out/example-or.json | stack run -- --only svg | perl -ple 's/\.00+//g' > out/example4.svg

-- | A visualization inspired by Ladder Logic and by Layman Allen (1978).

module AnyAll.SVGLadder where

import Data.List (foldl')

import AnyAll.Types hiding ((<>))

import Data.String
import Graphics.Svg
import qualified Data.Text as T
import qualified Data.Text.Lazy       as TL
import qualified Data.Map as Map
import Data.Tree
import Debug.Trace

type Height = Double
type Width  = Double
data BBox = BBox
  { bbw :: Width
  , bbh :: Height
  , bblm, bbtm, bbrm, bbbm :: Width -- left, top, right, bottom margins
  }
  deriving (Eq, Show)

-- | default bounding box
defaultBBox = BBox
  { bbw = 0
  , bbh = 0
  , bblm = 0
  , bbtm = 0
  , bbrm = 0
  , bbbm = 0
  }

-- | how compact should the output be?
data Scale = Tiny  -- @ ---o---
           | Small -- @ --- [1.1] ---
           | Full  -- @ --- the first item ---
           deriving (Show, Eq)

-- | how is a particular widget to be laid out?
data Direction = LR -- ^ left-to-right
               | TB -- ^ top-to-bottom
               deriving (Show, Eq)

data AAVConfig = AAVConfig
  { cscale       :: Scale
  , cdirection   :: Direction
  , cgetMark     :: Marking TL.Text
  }
  deriving (Show, Eq)

defaultAAVConfig :: AAVConfig
defaultAAVConfig = AAVConfig
  { cscale = Tiny
  , cdirection = LR
  , cgetMark = Marking Map.empty
  }

data AAVScale = AAVScale
  { sbw :: Width  -- ^ box width
  , sbh :: Height -- ^ box height
  , slm :: Width  -- ^ left margin
  , stm :: Width  -- ^ top margin
  , srm :: Width  -- ^ right margin
  , sbm :: Width  -- ^ bottom margin
  , slrv :: Width  -- ^ LR: vertical   gap between elements
  , slrh :: Width  -- ^ LR: horizontal gap between elements
  , stbv :: Width  -- ^ TB: vertical   gap between elements
  , stbh :: Width  -- ^ TB: horizontal gap between elements
  } deriving (Show, Eq)

getScale :: Scale -> AAVScale -- sbw sbh slm stm srm sbm slrv slrh stbv stbh
getScale Full      = AAVScale    120  44  22  20  22  20  10   10    10   10
getScale Small     = AAVScale     44  30  11  14  11  14   7    7     7    7
getScale Tiny      = AAVScale      8   8   6  10   6  10   5    5     5    5

getColors True = ("none", "none", "black")
getColors False = ("none", "lightgrey", "white")

type ItemStyle = Maybe Bool

(<<-*) :: Show a => AttrTag -> a -> Attribute
(<<-*) tag a = bindAttr tag (T.pack (show a))

tpsa a = T.pack $ show a

infix 4 <<-*

makeSvg' :: AAVConfig -> (BBox, Element) -> Element
makeSvg' c = makeSvg

makeSvg :: (BBox, Element) -> Element
makeSvg (_bbx, geom) =
     doctype
  <> with (svg11_ geom) [Version_ <<- "1.1" ]


data LineHeight = NoLine | HalfLine | FullLine
  deriving (Eq, Show)

q2svg :: AAVConfig -> QTree TL.Text -> Element
q2svg c qt = snd $ q2svg' c qt

q2svg' :: AAVConfig -> QTree TL.Text -> (BBox, Element)
q2svg' c qt@(Node q childqs) = drawItem c False qt 

drawItem, drawItemTiny, drawItemFull :: AAVConfig
                                     -> Bool
                                     -> QTree TL.Text
                                     -> (BBox, Element)
drawItem c negContext qt
  | cscale c == Tiny = drawItemTiny c negContext qt
  | otherwise        = drawItemFull c negContext qt

-- | item drawing proceeds in the following stages:
-- - construct all children -- just the boxes, no port connectors yet. if the children are themselves complex, we trust in the bounding boxes returned.
-- - for each child, position horizontally, centered or left/right aligned appropriately.
-- - position children vertically. usually this means spreading them out, with a gap between them. we do this by adding a topmargin to each bounding box
-- - flatten all the children into a single element. attach input and output horizontal lines to ports.
-- - return adjusted bounding box to caller.

data HAlignment = HLeft | HCenter | HRight
  deriving (Eq, Show)

data VAlignment = VTop | VMiddle | VBottom
  deriving (Eq, Show)

drawItemTiny c negContext qt@(Node (Q _sv ao@(Simply _txt) pp m) childqs) = drawLeaf     c      negContext qt
drawItemTiny c negContext qt@(Node (Q _sv ao@(Neg)         pp m) childqs) = drawItemTiny c (not negContext) (head childqs)
drawItemTiny c negContext qt                                              = drawItemFull c      negContext   qt      -- [TODO]
drawItemFull c negContext qt@(Node (Q  sv ao               pp m) childqs) =
  -- in a LR layout, each of the ORs gets a row below.
  -- we max up the bounding boxes and return that as our own bounding box.
  let (boxStroke, boxFill, textFill) = getColors True
  in case ao of
       Or -> let drawnChildren = vCombineOr c $ vStack c $ hAlign c HCenter $ drawItemFull c negContext <$> childqs
                 childLineLength = (bbh . fst $ drawnChildren)
                 y1 = (boxHeight / 2)
                 x2 = (bbw . fst $ drawnChildren) + leftMargin
             in (,) defaultBBox { bbw = leftMargin + rightMargin + (bbw.fst $ drawnChildren)
                                , bbh = (bbh.fst $ drawnChildren) + boxHeight + lrVgap }
                ( text_ [ X_  <<-* leftMargin + (bbw.fst $ drawnChildren) / 2 , Y_      <<-* (boxHeight / 2) , Text_anchor_ <<- "middle" , Dominant_baseline_ <<- "central" , Fill_ <<- textFill ] (fromString $ TL.unpack $ topText pp)
                  <> move (leftMargin, boxHeight) (snd drawnChildren)

                  <> line_ [ X1_ <<-* 0,          Y1_ <<-* y1, X2_ <<-* leftMargin,       Y2_ <<-* y1                   , Stroke_ <<- "red" ]   -- left horizontal
                  <> line_ [ X1_ <<-* leftMargin, Y1_ <<-* y1, X2_ <<-* leftMargin,       Y2_ <<-* y1 + childLineLength , Stroke_ <<- "black" ] -- left vertical
                  
                  <> line_ [ X1_ <<-* x2,         Y1_ <<-* y1, X2_ <<-* x2 + rightMargin, Y2_ <<-* y1                   , Stroke_ <<- "red" ]   -- right horizontal
                  <> line_ [ X1_ <<-* x2,         Y1_ <<-* y1, X2_ <<-* x2,               Y2_ <<-* y1 + childLineLength , Stroke_ <<- "black" ] -- right vertical
                )
       And -> let drawnChildren = hCombineAnd c $ hStack c $ vAlign c VMiddle $ drawItemFull c negContext <$> childqs
              in (,) defaultBBox { bbw = leftMargin + rightMargin + (bbw.fst $ drawnChildren) -- the toptext will move this a bit later
                                 , bbh = bbh.fst $ drawnChildren }
                 (snd drawnChildren)
       Simply _txt -> drawLeaf     c      negContext   qt
       Neg         -> drawItemFull c (not negContext) (head childqs)
     
    where
      myScale     = getScale (cscale c)
      boxWidth    = sbw myScale; boxHeight = sbh myScale; leftMargin  = slm myScale; rightMargin = srm myScale; lrVgap = slrv myScale; lrHgap = slrh myScale
      
      topText (Just (Pre x      )) = x
      topText (Just (PrePost x _)) = x
      topText Nothing              = ""

      -- if we used the diagrams package all of this would be calculated automatically for us.
      hAlign :: AAVConfig -> HAlignment -> [(BBox, Element)] -> [(BBox,Element)]
      hAlign c alignment elems =
        let mx = maximum $ bbw . fst <$> elems
        in hD alignment mx <$> elems
        where hD :: HAlignment -> Width -> (BBox, Element) -> (BBox, Element)
              hD HCenter mx (bb,x) = (bb { bblm = (mx - bbw bb) / 2, bbrm = (mx - bbw bb) / 2 }, x)
              hD HLeft   mx (bb,x) = (bb { bblm = 0,                 bbrm = (mx - bbw bb) / 1 }, x)
              hD HRight  mx (bb,x) = (bb { bblm = (mx - bbw bb) / 1, bbrm = 0                 }, x)
        
      vAlign :: AAVConfig -> VAlignment -> [(BBox, Element)] -> [(BBox,Element)]
      vAlign c alignment elems =
        let mx = maximum $ bbh . fst <$> elems
        in vA alignment mx <$> elems
        where vA :: VAlignment -> Width -> (BBox, Element) -> (BBox, Element)
              vA VMiddle  mx (bb,x) = (bb { bbtm = (mx - bbh bb) / 2, bbbm = (mx - bbh bb) / 2 }, x)
              vA VTop     mx (bb,x) = (bb { bbtm = 0,                 bbbm = (mx - bbh bb) / 1 }, x)
              vA VBottom  mx (bb,x) = (bb { bbtm = (mx - bbh bb) / 1, bbbm = 0                 }, x)

      -- prepare to stack a bunch of elements vertically by adding a lrVgap to each element's top margin
      vStack, hStack :: AAVConfig -> [(BBox, Element)] -> [(BBox,Element)]
      vStack c = fmap (vD c)
        where vD :: AAVConfig -> (BBox, Element) -> (BBox, Element)
              vD c (bb,x) = (bb { bbtm = lrVgap }, x)
      -- prepare to stack a bunch of elements horizontally by lining them up left to right, by adding a lrHgap to each element's left margin.
      -- bit questionable whether this Stack function is really necessary or if it's better done inside addLines.
      hStack c = fmap (hS c)
        where hS :: AAVConfig -> (BBox, Element) -> (BBox, Element)
              hS c (bb,x) = (bb { bbtm = lrVgap }, x)

      vCombineOr :: AAVConfig -> [(BBox, Element)] -> (BBox, Element)
      vCombineOr c elems =
        let layout = case cdirection c of
              LR -> vlayout
              TB -> error "hlayout not yet implemented"
            (childbbox, children) = foldl' layout (defaultBBox,mempty) elems
        in (childbbox { bbw = bbw childbbox + leftMargin + rightMargin }, children)
        where
          vlayout :: (BBox, Element) -> (BBox, Element) -> (BBox, Element)
          vlayout (bbold,old) (bbnew,new) =
            (defaultBBox { bbh = bbh bbold + bbh bbnew + lrVgap
                         , bbw = max (bbw bbold) (bbw bbnew)
                         }
            , old
              <> path_ [ D_ <<- (mA 0 (- boxHeight / 2) <> (cR
                                                         (leftMargin) 0
                                                         (0)              (bbh bbold + bbtm bbnew + boxHeight)
                                                         (leftMargin + bblm bbnew) (bbh bbold + bbtm bbnew + boxHeight)
                                                       )
                                ), Stroke_ <<- "green", Fill_ <<- "none" ]
              <> ( move (0, bbh bbold + bbtm bbnew) $ (move (leftMargin + bblm bbnew, 0) new) <>
                (line_ [ X1_ <<-* 0               , Y1_ <<-* (0 + boxHeight / 2) , X2_ <<-* leftMargin + bblm bbnew, Y2_ <<-* (0 + boxHeight / 2) , Stroke_ <<- "blue", Stroke_width_ <<-* 2 ]
                 <>
                  (line_ [ X1_ <<-* leftMargin + bblm bbnew + bbw bbnew , Y1_ <<-* (0 + boxHeight / 2) , X2_ <<-* leftMargin + bblm bbnew + bbw bbnew + bbrm bbnew + rightMargin, Y2_ <<-* (0 + boxHeight / 2) , Stroke_ <<- "blue" ])
                )
              )
            )

      hCombineAnd :: AAVConfig -> [(BBox, Element)] -> (BBox, Element)
      hCombineAnd c elems =
        let layout = case cdirection c of
              LR -> hlayout
              TB -> error "vlayout not yet implemented"
            (childbbox, children) = foldl' layout (defaultBBox,mempty) elems
        in (childbbox { bbw = bbw childbbox + leftMargin + rightMargin }, children)
        where
          hlayout :: (BBox, Element) -> (BBox, Element) -> (BBox, Element)
          hlayout (bbold,old) (bbnew,new) =
            (defaultBBox { bbh = max (bbh bbold) (bbh bbnew)
                         , bbw = bblm bbold + bbw bbold + bbrm bbold + bblm bbnew + bbw bbnew + bbrm bbnew + lrVgap -- [TODO] should become lrHgap, need to add this to our default margin set
                         }
            , old
              <> line_ [ X1_ <<-* bblm bbold + bbw bbold + bbrm bbold,                       Y1_ <<-* boxHeight / 2
                       , X2_ <<-* bblm bbold + bbw bbold + bbrm bbold + lrVgap + bblm bbnew, Y2_ <<-* boxHeight / 2
                       , Stroke_ <<- "green", Fill_ <<- "none" ]
              <> move (bblm bbold + bbw bbold + bbrm bbold + lrVgap + bblm bbnew, 0) new
            )
      
drawLeaf :: AAVConfig
         -> Bool -- ^ are we in a Neg context? i.e. parent was Negging to us
         -> QTree TL.Text -- ^ the tree to draw
         -> (BBox, Element)
drawLeaf c negContext qt@(Node q childqs) =
  let (boxStroke, boxFill, textFill) = getColors confidence
      mytext = case andOr q of
        (Simply txt) -> fromString (TL.unpack txt)
        (Neg)        -> "neg..."
        (And)        -> "and..."
        (Or)         -> "or..."
      notLine = if negContext then const FullLine else id
      (leftline, rightline, topline, confidence) = case mark q of
        Default (Right (Just True))  -> (HalfLine,  notLine HalfLine, not negContext, True)
        Default (Right (Just False)) -> (FullLine,  notLine NoLine,       negContext, True)
        Default (Right Nothing     ) -> (  NoLine,  notLine NoLine,            False, True)
        Default (Left  (Just True))  -> (HalfLine,  notLine HalfLine, not negContext, False)
        Default (Left  (Just False)) -> (FullLine,  notLine NoLine,       negContext, False)
        Default (Left  Nothing     ) -> (  NoLine,  notLine NoLine,            False, False)
      boxContents = if cscale c == Tiny
                    then (circle_ [Cx_  <<-* (boxWidth  / 2) ,Cy_      <<-* (boxHeight / 2) , R_ <<-* (boxWidth / 3), Fill_ <<- textFill ] )
                    else   (text_ [ X_  <<-* (boxWidth  / 2) , Y_      <<-* (boxHeight / 2) , Text_anchor_ <<- "middle" , Dominant_baseline_ <<- "central" , Fill_ <<- textFill ] mytext)
  in
  (,) defaultBBox { bbw = boxWidth, bbh = boxHeight } $
     rect_ [ X_      <<-* 0 , Y_      <<-* 0 , Width_  <<-* boxWidth , Height_ <<-* boxHeight , Stroke_ <<-  boxStroke , Fill_   <<-  boxFill ]
  <> boxContents
  <> (if leftline  == HalfLine then line_ [ X1_ <<-* 0        , Y1_ <<-* 0, X2_ <<-* 0         , Y2_ <<-* boxHeight / 2 , Stroke_ <<- "black" ] else mempty)
  <> (if rightline == HalfLine then line_ [ X1_ <<-* boxWidth , Y1_ <<-* 0, X2_ <<-* boxWidth  , Y2_ <<-* boxHeight / 2 , Stroke_ <<- "black" ] else mempty)
  <> (if leftline  == FullLine then line_ [ X1_ <<-* 0        , Y1_ <<-* 0, X2_ <<-* 0         , Y2_ <<-* boxHeight     , Stroke_ <<- "black" ] else mempty)
  <> (if rightline == FullLine then line_ [ X1_ <<-* boxWidth , Y1_ <<-* 0, X2_ <<-* boxWidth  , Y2_ <<-* boxHeight     , Stroke_ <<- "black" ] else mempty)
  <> (if topline               then line_ [ X1_ <<-* 0        , Y1_ <<-* 0, X2_ <<-* boxWidth  , Y2_ <<-* 0             , Stroke_ <<- "black" ] else mempty)
  where
    boxHeight = sbh (getScale (cscale c))
    boxWidth  = sbw (getScale (cscale c))


  -- itemBox c 0 0 ao mark children False






type Boolean = Bool

itemBox :: AAVConfig
        -> Double          -- ^ x top left
        -> Double          -- ^ y top left
        -> AndOr TL.Text   -- ^ Item, recast as an AndOr Text for display
        -> Default Bool    -- ^ mark for the box
        -> [QTree TL.Text] -- ^ children
        -> Bool            -- ^ did we get here because we were contained by a Neg?
        -> (BBox, Element)
itemBox c x y Neg m cs amNot = itemBox c x y (andOr $ rootLabel $ head cs) m [] False
itemBox c x y (Simply t)  m cs amNot
  | cscale c  == Tiny  = (,) defaultBBox { bbw = 10, bbh = 10 } $ g_ [] ( rect_ [ X_ <<-* x, Y_ <<-* y, Width_ <<-* 10, Height_ <<-* 10, Stroke_ <<- "red", Fill_ <<- "green" ] )
-- [TODO] small
  | cscale c  `elem` [Full,Small]  = (,) (defaultBBox { bbw = fromIntegral $ TL.length t * 3, bbh = 25 }) $ g_ [] (
      rect_ [ X_ <<-* x      , Y_ <<-* y, Width_ <<-* 10, Height_ <<-* 10, Stroke_ <<- "red", Fill_ <<- "green" ]
        <> mempty ) -- some text
itemBox c x y andor m cs amNot = (,) (defaultBBox { bbw = fromIntegral $ 25, bbh = 25 }) $ g_ [] (
  rect_ [ X_ <<-* x      , Y_ <<-* y, Width_ <<-* 10, Height_ <<-* 10, Stroke_ <<- bs cs, Fill_ <<- bf cs ]
    <> mempty) -- some text
  
  -- [TODO]: for And and Or, recurse into children, and move them around, and update current bounding box.
  where cs = colorScheme c m amNot

data ColorScheme = ColorScheme
  { bs -- | box stroke
  , bf -- | box fill
  , tf -- | text fill
  , ll -- | left  "negation" line -- the marking is False
  , rl -- | right "negation" line -- we are drawing a Not element
  , tl -- | top "truth" line -- drawn if the value is true, or if the marking is false and the item is a Not
    :: T.Text
  }

-- | the color scheme depends on the marking
colorScheme :: AAVConfig
            -> Default Bool
            -> Boolean   -- | iff we got here via a Not, this value is True
            -> ColorScheme
colorScheme c m amNot = case m of
                          Default (Right (Just b@True )) -> ColorScheme "none" "none" "black" "none"  notLine (topLine b) -- user says true, or computed to true
                          Default (Right (Just b@False)) -> ColorScheme "none" "none" "black" "black" notLine (topLine b) -- user says false, or computed to false
                          Default (Right (Nothing     )) -> ColorScheme "none" "none" "black" "black" notLine "none"      -- user says explicitly they don't know
                          Default (Left  (Just b@True )) -> ColorScheme "none" "grey" "white" "none"  notLine (topLine b) -- no user input, default is true
                          Default (Left  (Just b@False)) -> ColorScheme "none" "grey" "white" "black" notLine (topLine b) -- no user input, default is false
                          Default (Left  Nothing      )  -> ColorScheme "none" "grey" "white" "black" notLine "none"      -- no user input, no default
  where
    notLine   = if amNot                   then "black" else "none"
    topLine b = if          amNot && not b then "black"
                else if not amNot &&     b then "black" else "none"
  

box :: AAVConfig -> Double -> Double -> Double -> Double -> Element
box c x y w h =
  rect_ [ X_ <<-* x, Y_ <<-* y, Width_ <<-* w, Height_ <<-* h
        , Fill_ <<- "none", Stroke_ <<- "black" ]

line :: (Double , Double) -> (Double, Double) -> Element
line (x1, y1) (x2, y2) =
  line_ [ X1_ <<-* x1, X2_ <<-* x2, Y1_ <<-* y1, Y2_ <<-* y2
        , Stroke_ <<- "grey" ]

item :: ToElement a => AAVConfig -> Double -> Double -> a -> Element
item c x y desc =
  let w = 20
  in
    g_ [] (  box c x y w w
          <> text_ [ X_ <<-* (x + w + 5), Y_ <<-* (y + w - 5) ] (toElement desc)  )

move :: (Double, Double) -> Element -> Element
move (x, y) geoms =
  with geoms [Transform_ <<- translate x y]

type OldBBox = (Width, Height)

renderChain :: AAVConfig -> [(OldBBox, Element)] -> Element
renderChain c [] = mempty
renderChain c [(_,g)] = g
renderChain c (((w,h),g):hgs) =
  g_ [] (  g
        <> line (10, 20) (10, h)
        <> move (0, h) (renderChain c hgs)  )

renderLeaf :: (ToElement a) => AAVConfig -> a -> (OldBBox, Element)
renderLeaf c desc =
  let height = 25
      geom = item c 0 0 desc
  in ((25,height), geom)

renderNot :: (ToElement a) => AAVConfig -> [Item a] -> (OldBBox, Element)
renderNot c children =
  let
      ((w,h), g) = renderItem c $ head children
      height = h

      geom :: Element
      geom = g_ [] ( line (-5, 5) (-10, 15)  --  /
                     <> line (10,0) (10,25)  --  |
                     <> move (00, 0) g )
  in ((w,height), geom)


renderSuffix :: (ToElement a) => AAVConfig -> Double -> Double -> a -> (OldBBox, Element)
renderSuffix c x y desc =
  let h = 20 -- h/w of imaginary box
      geom :: Element
      geom = g_ [] ( text_ [ X_ <<-* x, Y_ <<-* (y + h - 5) ] (toElement desc) )
  in ((25,h), geom)

renderAll :: (ToElement a) => AAVConfig -> Maybe (Label TL.Text) -> [Item a] -> (OldBBox, Element)
renderAll c Nothing childnodes = renderAll c allof childnodes
renderAll c (Just (Pre prefix)) childnodes =
  let
      hg = map (renderItem c) childnodes
      (hs, gs) = unzip hg

      width = 25
      height = sum (snd <$> hs) + 30

      geom :: Element
      geom = g_ [] (  item c 0 0 prefix
                   -- elbow connector
                   <> line (10, 20) (10, 25)
                   <> line (10, 25) (40, 25)
                   <> line (40, 25) (40, 30)
                   -- children translated by (30, 30)
                   <> move (30, 30) (renderChain c hg)  )
  in ((width,height), geom)
renderAll c (Just (PrePost prefix suffix)) childnodes =
  let hg = map (renderItem c) childnodes
      (hs, gs) = unzip hg

      ((fw, fh), fg) = renderSuffix c 0 0 suffix

      width = 25
      height = sum (snd <$> hs) + fh + 30

      geom :: Element
      geom = g_ [] (  item c 0 0 prefix
                   <> line (10, 20) (10, 25)
                   <> line (10, 25) (40, 25)
                   <> line (40, 25) (40, 30)
                   <> move (30, 30) (renderChain c hg)
                   <> move (40, 30 + sum (snd <$> hs)) fg  )
  in ((width,height), geom)

renderAny :: (ToElement a) => AAVConfig -> Maybe (Label TL.Text) -> [Item a] -> (OldBBox, Element)
renderAny c Nothing childnodes = renderAny c (Just (Pre "any of:")) childnodes
renderAny c (Just (Pre prefix)) childnodes =
  let hg = map (renderItem c) childnodes
      (hs, gs) = unzip hg

      width = 25
      height = sum (snd <$> hs) + 25

      geom :: Element
      geom = g_ [] (  item c 0 0 prefix
                   <> line (10, 20) (10, sum (init (snd <$> hs)) + 25 + 10)
                   <> move (30, 25) (go 0 hg)  )
                 where go y [] = mempty
                       go y (((w,h),g):hgs) =
                         g_ [] (  g
                               <> line (-20, 10) (0, 10)
                               <> move (0, h) (go (y+h) hgs)  )
  in ((width,height), geom)
renderAny c (Just (PrePost prefix suffix)) childnodes =
  let hg = map (renderItem c) childnodes
      (hs, gs) = unzip hg

      ((fw,fh), fg) = renderSuffix c 0 0 suffix

      width = 25
      height = sum (snd <$> hs) + fh + 25

      geom :: Element
      geom = g_ [] (  item c 0 0 prefix
                   <> line (10, 20) (10, sum (snd <$> init hs) + 25 + 10)
                   <> move (30, 25) (go 0 hg)
                   <> move (40, 25 + sum (snd <$> hs)) fg)
                 where go y [] = mempty
                       go y (((w,h),g):hgs) =
                         g_ [] (  g
                               <> line (-20, 10) (0, 10)
                               <> move (0, h) (go (y+h) hgs)  )
  in ((width, height), geom)


renderItem :: (ToElement a) => AAVConfig -> Item a -> (OldBBox, Element)
renderItem c (Leaf label)     = renderLeaf c label
renderItem c (Not       args) = renderNot c      [args]
renderItem c (All label args) = renderAll c label args
renderItem c (Any label args) = renderAny c label args

toy :: (OldBBox, Element)
toy = renderItem defaultAAVConfig $
  All (Just $ PrePost "You need all of" ("to survive." :: TL.Text))
      [ Leaf ("Item 1;" :: TL.Text)
      , Leaf "Item 2;"
      , Any (Just $ Pre "Item 3 which may be satisfied by any of:" )
            [ Leaf "3.a;"
            , Leaf "3.b; or"
            , Leaf "3.c;" ]
      , Leaf "Item 4; and"
      , All ( Just $ Pre "Item 5 which requires all of:" )
            [ Leaf "5.a;"
            , Leaf "5.b; and"
            , Leaf "5.c." ]
      ]
