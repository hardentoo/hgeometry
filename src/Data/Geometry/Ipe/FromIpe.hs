{-# LANGUAGE OverloadedStrings #-}
module Data.Geometry.Ipe.FromIpe where

import           Control.Lens hiding (Simple)
import           Data.Ext
import           Data.Geometry.Ipe.Reader
import           Data.Geometry.Ipe.Types
import           Data.Geometry.LineSegment
import qualified Data.Geometry.PolyLine as PolyLine
import           Data.Geometry.Polygon
import           Data.Geometry.Properties
import qualified Data.Seq2 as S2
import qualified Data.List.NonEmpty as NonEmpty

--------------------------------------------------------------------------------
-- $setup
-- >>> :{
-- import           Data.Geometry.Ipe.Attributes
--
-- let testPath :: Path Int
--     testPath = Path . S2.l1Singleton  . PolyLineSegment . PolyLine.fromPoints . map ext
--              $ [ origin, point2 10 10, point2 200 100 ]
--
--     testPathAttrs :: IpeAttributes Path Int
--     testPathAttrs = attr SStroke (IpeColor (Named "red"))

--     testObject :: IpeObject Int
--     testObject = IpePath (testPath :+ testPathAttrs)
-- :}


-- | Try to convert a path into a line segment, fails if the path is not a line
-- segment or a polyline with more than two points.
--
--
_asLineSegment :: Prism' (Path r) (LineSegment 2 () r)
_asLineSegment = prism' seg2path path2seg
  where
    seg2path   = review _asPolyLine . PolyLine.fromLineSegment
    path2seg p = PolyLine.asLineSegment' =<< preview _asPolyLine p

-- | Convert to a polyline. Ignores all non-polyline parts
--
-- >>> testPath ^? _asPolyLine
-- Just (PolyLine {_points = Seq2 (Point2 [0,0] :+ ()) (fromList [Point2 [10,10] :+ ()]) (Point2 [200,100] :+ ())})
_asPolyLine :: Prism' (Path r) (PolyLine.PolyLine 2 () r)
_asPolyLine = prism' poly2path path2poly
  where
    poly2path = Path . S2.l1Singleton  . PolyLineSegment
    path2poly = preview (pathSegments.traverse._PolyLineSegment)
    -- TODO: Check that the path actually is a polyline, rather
    -- than ignoring everything that does not fit

-- | Convert to a simple polygon
_asSimplePolygon :: Prism' (Path r) (Polygon Simple () r)
_asSimplePolygon = prism' polygonToPath path2poly
  where
    path2poly p = pathToPolygon p >>= either pure (const Nothing)

-- | Convert to a multipolygon
_asMultiPolygon :: Prism' (Path r) (MultiPolygon () r)
_asMultiPolygon = prism' polygonToPath path2poly
  where
    path2poly p = pathToPolygon p >>= either (const Nothing) pure

polygonToPath                      :: Polygon t () r -> Path r
polygonToPath pg@(SimplePolygon _) = Path . S2.l1Singleton . PolygonPath $ pg
polygonToPath (MultiPolygon vs hs) = Path . S2.viewL1FromNonEmpty . fmap PolygonPath
                                   $ SimplePolygon vs NonEmpty.:| hs


pathToPolygon   :: Path r -> Maybe (Either (SimplePolygon () r) (MultiPolygon () r))
pathToPolygon p = case p^..pathSegments.traverse._PolygonPath of
                    []                   -> Nothing
                    [pg]                 -> Just . Left  $ pg
                    SimplePolygon vs: hs -> Just . Right $ MultiPolygon vs hs



-- | use the first prism to select the ipe object to depicle with, and the second
-- how to select the geometry object from there on. Then we can select the geometry
-- object, directly with its attributes here.
--
-- >>> testObject ^? _withAttrs _IpePath _asPolyLine
-- Just (PolyLine {_points = Seq2 (Point2 [0,0] :+ ()) (fromList [Point2 [10,10] :+ ()]) (Point2 [200,100] :+ ())} :+ Attrs {_unAttrs = {GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Just (IpeColor (Named "red"))}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}, GAttr {_getAttr = Nothing}}})
_withAttrs       :: Prism' (IpeObject r) (i r :+ IpeAttributes i r) -> Prism' (i r) g
                 -> Prism' (IpeObject r) (g :+ IpeAttributes i r)
_withAttrs po pg = prism' g2o o2g
  where
    g2o    = review po . over core (review pg)
    o2g o  = preview po o >>= \(i :+ ats) -> (:+ ats) <$> preview pg i





-- instance HasDefaultIpeObject Path where
--   defaultIpeObject' = _IpePath


-- class HasDefaultFromIpe g where
--   type DefaultFromIpe g :: * -> *
--   defaultIpeObject :: proxy g -> Prism' (IpeObject r) (DefaultFromIpe g r :+ IpeAttributes (DefaultFromIpe g) r)
--   defaultFromIpe   :: proxy g -> Prism' (DefaultFromIpe g (NumType g)) g


class HasDefaultFromIpe g where
  type DefaultFromIpe g :: * -> *
  defaultFromIpe :: (r ~ NumType g)
                 => Prism' (IpeObject r) (g :+ IpeAttributes (DefaultFromIpe g) r)

-- instance HasDefaultFromIpe (Point 2 r) where
--   type DefaultFromIpe (Point 2 r) = IpeSymbol
--   defaultFromIpe = _withAttrs _IpeUse symbolPoint


instance HasDefaultFromIpe (LineSegment 2 () r) where
  type DefaultFromIpe (LineSegment 2 () r) = Path
  defaultFromIpe = _withAttrs _IpePath _asLineSegment

instance HasDefaultFromIpe (PolyLine.PolyLine 2 () r) where
  type DefaultFromIpe (PolyLine.PolyLine 2 () r) = Path
  defaultFromIpe = _withAttrs _IpePath _asPolyLine


instance HasDefaultFromIpe (SimplePolygon () r) where
  type DefaultFromIpe (SimplePolygon () r) = Path
  defaultFromIpe = _withAttrs _IpePath _asSimplePolygon

instance HasDefaultFromIpe (MultiPolygon () r) where
  type DefaultFromIpe (MultiPolygon () r) = Path
  defaultFromIpe = _withAttrs _IpePath _asMultiPolygon


-- | Read all g's from some ipe page(s).
readAll :: (HasDefaultFromIpe g, r ~ NumType g, Foldable f)
        => f (IpePage r) -> [g :+ IpeAttributes (DefaultFromIpe g) r]
readAll = foldMap (^..content.traverse.defaultFromIpe)


-- | Convenience function from reading all g's from an ipe file. If there
-- is an error reading or parsing the file the error is "thrown away".
readAllFrom    :: (HasDefaultFromIpe g, r ~ NumType g, Coordinate r, Eq r)
               => FilePath -> IO [g :+ IpeAttributes (DefaultFromIpe g) r]
readAllFrom fp = readAll <$> readSinglePageFile fp

