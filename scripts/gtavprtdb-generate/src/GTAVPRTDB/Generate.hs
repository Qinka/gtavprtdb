{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards  #-}

module GTAVPRTDB.Generate where

import           Control.Monad.Random
import           Data.Int
import           Data.List.Split
import qualified Data.Map             as M
import qualified Data.Vector          as V
import           GTAVPRTDB.Binary
import           GTAVPRTDB.MkPlate
import           Linear.V2            (V2 (..))
import           OpenCV


data Seed = Seed { sPlateNumber :: String
                 , sPlateBgIdx  :: Int
                 , sOffset      :: [Float]
                 }
            deriving Show

generateSeedViaParameter :: IO Seed
generateSeedViaParameter = generateSeed
                           <$> generateOffsetA
                           <*> generateOffsetB
                           <*> generateScale
                           <*> generateMoveX
                           <*> generateMoveY
                           <*> generatePlateI
                           <*> generateString
  where generateString = take 8 <$> getRandoms >>=
          return . map (\i -> fontList !! mod i 37)
        generatePlateI = (`mod` 5) <$> getRandom
        generateOffsetA = nonLinearTrans1 90    <$> getRandomR (-90,90)
        generateOffsetB = nonLinearTrans1 90    <$> getRandomR (-90,90)
        generateScale   = nonLinearTrans2 1 2 <$> getRandomR (0.4,2)
        generateMoveX   = nonLinearTrans3 480 <$> getRandomR (-480,480)
        generateMoveY   = nonLinearTrans3 268 <$> getRandomR (-268,268)
        nonLinearTrans1 base a = a ^ 5 / base ^ 4
        nonLinearTrans2 b1 b2 a = nonLinearTrans3 (b2 - b1) (a - b1) + b1
        nonLinearTrans3 base a = a ^ 3 / base ^ 2
        nonLinearTrans4 base a = a ^ 5 / base ^ 4

generateSeed :: Float  -- ^ angle a
             -> Float  -- ^ angle b
             -> Float  -- ^ scale \gamma
             -> Float  -- ^ m x
             -> Float  -- ^ m y
             -> Int    -- ^ index
             -> String -- ^ plate
             -> Seed
generateSeed a b g x y i p = Seed p i $ check a b g x y
  where check a b s dx dy =
          let preIs = a <= 45 && a >= (-45)
                      && b <= 45 && b >= (-45)
                      && s <= 1.45 && s >= 0.65
              off = generateOffset a b s
              move = map (\(V2 x y) -> V2 (dx + x) (dy + y)) off
              is = and . map (\(V2 x y) -> x < 960 && x >= 0 && y < 536 && y >= 0) . perspectiveTransformKeyPoints
              move' = concat $ map (\(V2 x y) -> [x,y]) move
          in (if is move && preIs then 1 else 0) : move'



generateImgWithSeed :: (M.Map Char CharImg)
                    -> [PlateImg 3]
                    -> RecordImg 3
                    -> Seed
                    -> IO (RecordImg 3,V.Vector Int16)
generateImgWithSeed maps platebgs bg Seed{..} =
  let is:o    = sOffset
      mask    = if sPlateBgIdx `elem` [1,2] then yellowMask else blueMask
      plate   = mkPlate maps mask sPlateNumber (platebgs !! sPlateBgIdx)
      off     = map (\(a:b:_) -> V2 a b) $ chunksOf 2 o
      ptPlate = perspectiveTransformPlate off plate
      record  = addPlateToBG bg ptPlate
      ls      = concat $ map (\(V2 a b) -> round <$> [a,b]) $ perspectiveTransformKeyPoints off
  in return (record,V.fromList (round is:ls))


generateImg :: FilePath
            -> [FilePath]
            -> IO ([RecordImg 3],[V.Vector Int16])
generateImg fp bgFiles = do
  maps  <- loadFonts fp
  platebgs <- mapM (\i -> loadPlateImg $ fp ++ "plate0" ++ show i ++ ".jpg") [1..5]
  bgs <- mapM loadBg bgFiles
  unzip <$> mapM (create maps platebgs) bgs
  where create maps platebgs bg = generateSeedViaParameter  >>= generateImgWithSeed maps platebgs bg
        loadBg :: String -> IO (RecordImg 3)
        loadBg n = loadAnyImg ImreadUnchanged  $ fp ++ '/' : n


generateOffset :: Float -- ^ alpha |/  (for z-x axis) \in [-45,45]
               -> Float -- ^ beta  _/_ (for z-y axis) \in [-45,45]
               -> Float -- ^ gamma \in [0.65,1.45]
               -> PointOffset Float
generateOffset a' b' g' = [ V2 dLTX dLTY
                          , V2 dRTX dRTY
                          , V2 dLBX dLBY
                          , V2 dRBX dRBY
                          ]
  where o al = - sin al
        f al =   sin al
        h = 256 * 0.5
        v = 168 * 0.5
            -- x y
        dLTX = h * (f a + 0.2 * o b - g)
        dLTY = v * (0.2 * o a + f b - g)
        dRTX = h * (o a + 0.2 * f b + g)
        dRTY = v * (0.2 * f a + f b - g)
        dLBX = h * (f a + 0.2 * f b - g)
        dLBY = v * (0.2 * f a + o b + g)
        dRBX = h * (o a + 0.2 * o b + g)
        dRBY = v * (0.2 * o a + o b + g)
        a = a' / 180 * pi
        b = b' / 180 * pi
        g = g' - 1











