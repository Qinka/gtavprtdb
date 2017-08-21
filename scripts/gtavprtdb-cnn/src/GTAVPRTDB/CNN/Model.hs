{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies    #-}


{- |
Module      : GTAVPRTDB.CNN.Model
Description : The example for using CNN to recognize vehicle's plate number.
Copyright   : (C) Johann Lee <me@qinka.pro> 2017
License     : GPL-3
Maintainer  : me@qinka.pro qinka@live.com
Stability   : experimental
Portability : unknown

The example for using CNN to recognize vehicle's plate number.
This module includes the model for the CNN.
-}


module GTAVPRTDB.CNN.Model
  ( KeyPointParameters(..)
  , KeyPointModel(..)
  , createKPModel
  ) where

import           Data.Int
import           Data.List.Split
import           Data.Maybe
import qualified Data.Vector            as V
import           GTAVPRTDB.Binary       (fromLabel)
import           GTAVPRTDB.CNN.Internal
import           GTAVPRTDB.CNN.Training
import           GTAVPRTDB.Types        (PointOffset (..))
import qualified TensorFlow.Core        as TF
import qualified TensorFlow.GenOps.Core as TF (less, sqrt, square, sum)
import qualified TensorFlow.Minimize    as TF
import qualified TensorFlow.Ops         as TF hiding (initializedVariable,
                                               zeroInitializedVariable)
import qualified TensorFlow.Variable    as TF

-- $keypoints
--
--

-- | convolution layout
kpConvLayer :: TF.MonadBuild m
            => (Int64,Int64) -- ^ ksize for maxpool
            -> (Int64,Int64) -- ^ stride for maxpool
            -> TF.Variable Float -- ^ weight, shape = [x,y,input_size,feature_size]
            -> TF.Variable Float -- ^ bias, shape = [feature_size]
            -> TF.Tensor t Float -- ^ input, shape = [w,h,f]
            -> m (TF.Tensor TF.Build Float) -- ^ output
kpConvLayer k s w b i = return pool
  where conv = TF.relu $ i `conv2D` TF.readValue w `TF.add`  TF.readValue b
        pool = maxPool k s conv

-- | full connected layout
kpFullLayer :: TF.MonadBuild m
            => TF.Variable Float -- ^ weight, shape = [x,y]
            -> TF.Variable Float -- ^ bias, shape = [y]
            -> TF.Tensor t Float -- ^ input, shape = [w,h,f]
            -> m (TF.Tensor TF.Build Float) -- ^ output
kpFullLayer w b i = return $ TF.relu $ i `TF.matMul` TF.readValue w `TF.add`  TF.readValue b

data KeyPointParameters
  = KeyPointParameters { kpConv1 :: ([Float],[Float]) -- ^ weight and bias for the first layer: convolution layer
                       , kpConv2 :: ([Float],[Float]) -- ^ weight and bias for the second layer: convolution layer
                       , kpFull3 :: ([Float],[Float]) -- ^ weight and bias for the third layer: full connection
                       , kpFull4 :: ([Float],[Float]) -- ^ weight and bias for the last layer: full connection
                       }
    deriving Show


-- | create parameters
--
--  first layer:  [conv] 6 x 6 x  3 x 32 [maxpool] 6 x 4 (960 x 536 -> 954 x 530 -> 159 x 133)
-- second layer:  [conv] 5 x 5 x 32 x 64 [maxpool] 4 x 8 (159 x 133 -> 154 x 128 ->  40 x 16)
--  third layer:  [weight] 40960 -> 4096 [bias] 4096
--   last layer:  [weigjt] 4096  -> 9    [bias] 9
createKPParameters :: Maybe KeyPointParameters -- ^ parameters
                   -> TF.Build [TF.Variable Float] -- ^ w1 b1 w2 b2 ...
createKPParameters Nothing = do
  let value x y = TF.initializedVariable =<< randomParam x y
  -- convolution layers
  w1 <- value  6 [  6,  6,  3, 32]
  b1 <- TF.zeroInitializedVariable [32]
  w2 <- value  5 [  5,  5, 32, 64]
  b2 <- TF.zeroInitializedVariable [64]
  -- full connection layers
  w3 <- value 40960 [40960,4096]
  b3 <- TF.zeroInitializedVariable [4096]
  w4 <- value 4096 [4096,9]
  b4 <- TF.zeroInitializedVariable [9]
  return [w1,b1,w2,b2,w3,b3,w4,b4]
createKPParameters (Just KeyPointParameters{..}) = do
  let value x y = TF.initializedVariable $ TF.constant x y
  w1 <- value [  6,  6,  3, 32] $ fst kpConv1
  b1 <- value [             32] $ snd kpConv1
  w2 <- value [  5,  5, 32, 64] $ fst kpConv2
  b2 <- value [             64] $ snd kpConv2
  w3 <- value [    40960, 4096] $ fst kpFull3
  b3 <- value [           4096] $ snd kpFull3
  w4 <- value [        4096, 9] $ fst kpFull4
  b4 <- value [              9] $ snd kpFull4
  return [w1,b1,w2,b2,w3,b3,w4,b4]

-- | model of key point
data KeyPointModel
  = KeyPointModel { kpTrain :: TF.TensorData Float -- ^ images
                            -> TF.TensorData Int32 -- ^ labels
                            -> TF.Session ()
                  , kpInfer :: TF.TensorData Float -- ^ images
                            -> TF.Session (V.Vector [Int32])
                  , kpErrRt :: TF.TensorData Float -- ^ images
                            -> TF.TensorData Int32 -- ^ labels
                            -> TF.Session Float
                  , kpParam :: TF.Session KeyPointParameters
                  }

instance Training KeyPointModel where
  type TInput KeyPointModel = Float
  type TLabel KeyPointModel = Int32
  type TParam KeyPointModel = KeyPointParameters
  train = kpTrain
  infer = kpInfer
  errRt = kpErrRt
  param = kpParam
  sizes = undefined

createKPModel :: Maybe KeyPointParameters -- ^ parameters
              -> TF.Build KeyPointModel   -- ^ model
createKPModel p = do
  images <- TF.placeholder [-1,960,536,3]
  w1:b1:w2:b2:w3:b3:w4:b4:_ <- createKPParameters p
  out <- kpConvLayer (4,6) (4,6) w1 b1 images >>=
    kpConvLayer (8,4) (8,4) w2 b2 >>=
    kpFullLayer w3 b3 >>=
    kpFullLayer w4 b4
  labels <- TF.placeholder [-1,9] :: TF.Build (TF.Tensor TF.Value Int32)
  let outI = TF.cast out :: TF.Tensor TF.Build Int32
      loss = TF.sqrt $ TF.reduceMean $ TF.square $ (TF.cast labels) `TF.sub` out
      params = w1:b1:w2:b2:w3:b3:w4:b4:[]
  trainStep <- TF.minimizeWith TF.adam loss params
  let diffPredictions = TF.sum (TF.scalar (0 :: Int32)) (TF.abs $ outI `TF.sub` labels) `TF.less` TF.scalar 30
  errorRateTensor <- TF.render $ 1 - TF.reduceMean (TF.cast diffPredictions)
  return KeyPointModel
    { kpTrain = \imF lF ->
        TF.runWithFeeds_ [ TF.feed images imF
                         , TF.feed labels lF
                         ] trainStep
    , kpInfer = \imF -> do
       x <- V.toList <$> TF.runWithFeeds [TF.feed images imF] outI
       return $ V.fromList $ chunksOf 9 x
    , kpErrRt = \imF lF ->
        TF.unScalar <$> TF.runWithFeeds [ TF.feed images imF
                                        , TF.feed labels lF
                                        ] errorRateTensor
    , kpParam =
      let trans :: TF.Variable Float -> TF.Session [Float]
          trans x = V.toList <$> (TF.run =<< TF.render (TF.cast $ TF.readValue x))
      in KeyPointParameters
         <$> ((,) <$> trans w1 <*> trans b1)
         <*> ((,) <$> trans w2 <*> trans b2)
         <*> ((,) <$> trans w3 <*> trans b3)
         <*> ((,) <$> trans w4 <*> trans b4)
    }