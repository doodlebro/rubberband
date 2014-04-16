{- |

A nicer layer above the C API.

  * The 'State' object is garbage-collected by Haskell.

  * The 'study', 'process', and 'retrieve' functions use 'StorableArray's
    instead of raw pointers.

  * Some error checking is done in cases like giving arrays of different
    lengths to 'study' and 'process', or giving a different number of arrays
    from how many channels the 'State' was constructed with.

-}
module Sound.RubberBand.Nice where

import qualified Sound.RubberBand.Raw as Raw
import Sound.RubberBand.Raw (SampleRate, NumChannels, TimeRatio, PitchScale)
import Sound.RubberBand.Option

import Foreign (Ptr, ForeignPtr, newForeignPtr, withForeignPtr, finalizerFree)
import Control.Applicative ((<$>))
import Foreign.Marshal.Array (withArray, withArrayLen, mallocArray)
import Data.Array.Storable
import Foreign.C.Types (CFloat)
import Control.Monad (guard, liftM, forM, replicateM)
import Data.Array.Unsafe (unsafeForeignPtrToStorableArray)

newtype State = State (ForeignPtr Raw.State)
  deriving (Eq)

withRawState :: State -> (Raw.State -> IO a) -> IO a
withRawState (State fp) f = withForeignPtr fp $ f . Raw.State

new ::
  SampleRate -> NumChannels -> Options -> TimeRatio -> PitchScale -> IO State
new a b c d e = do
  Raw.State p <- Raw.new a b c d e
  State <$> newForeignPtr Raw.p_delete p

reset :: State -> IO ()
reset s = withRawState s Raw.reset

setTimeRatio :: State -> TimeRatio -> IO ()
setTimeRatio s d = withRawState s $ \r -> Raw.setTimeRatio r d

setPitchScale :: State -> PitchScale -> IO ()
setPitchScale s d = withRawState s $ \r -> Raw.setPitchScale r d

getTimeRatio :: State -> IO TimeRatio
getTimeRatio s = withRawState s Raw.getTimeRatio

getPitchScale :: State -> IO PitchScale
getPitchScale s = withRawState s Raw.getPitchScale

getLatency :: State -> IO Int
getLatency s = withRawState s Raw.getLatency

setTransientsOption :: State -> Transients -> IO ()
setTransientsOption s o = withRawState s $ \r -> Raw.setTransientsOption r o

setDetectorOption :: State -> Detector -> IO ()
setDetectorOption s o = withRawState s $ \r -> Raw.setDetectorOption r o

setPhaseOption :: State -> Phase -> IO ()
setPhaseOption s o = withRawState s $ \r -> Raw.setPhaseOption r o

setFormantOption :: State -> Formant -> IO ()
setFormantOption s o = withRawState s $ \r -> Raw.setFormantOption r o

setPitchOption :: State -> Pitch -> IO ()
setPitchOption s o = withRawState s $ \r -> Raw.setPitchOption r o

setExpectedInputDuration :: State -> Int -> IO ()
setExpectedInputDuration s n =
  withRawState s $ \r -> Raw.setExpectedInputDuration r n

getSamplesRequired :: State -> IO Int
getSamplesRequired s = withRawState s Raw.getSamplesRequired

setMaxProcessSize :: State -> Int -> IO ()
setMaxProcessSize s n = withRawState s $ \r -> Raw.setMaxProcessSize r n

setKeyFrameMap :: State -> [(Int, Int)] -> IO ()
setKeyFrameMap s pairs = withRawState s $ \r ->
  withArray (map (fromIntegral . fst) pairs) $ \p1 ->
    withArray (map (fromIntegral . snd) pairs) $ \p2 ->
      Raw.setKeyFrameMap r (length pairs) p1 p2

withStorableArrays :: [StorableArray i e] -> ([Ptr e] -> IO a) -> IO a
withStorableArrays []       f = f []
withStorableArrays (x : xs) f =
  withStorableArray x $ \p ->
    withStorableArrays xs $ \ps ->
      f $ p : ps

getUniform :: (Eq a) => [a] -> Maybe a
getUniform (x : xs) = guard (all (== x) xs) >> Just x
getUniform []       = Nothing

getLength :: (MArray a e m, Num i, Ix i) => a i e -> m i
getLength = liftM (\(x, y) -> y - x + 1) . getBounds

-- | Ugly, but needed to share the code for 'study' and 'process'.
studyProcess ::
  String -> (Raw.State -> Ptr (Ptr CFloat) -> Int -> Bool -> IO ()) ->
    State -> [StorableArray Int CFloat] -> Bool -> IO ()
studyProcess fname f s chans final = do
  msamples <- fmap getUniform $ mapM getLength chans
  samples <- case msamples of
    Nothing -> if null chans
      then return 0 -- is this sensible? user gave no audio so whatever
      else error $ fname ++ ": input arrays have differing lengths"
    Just sam -> return sam
  withStorableArrays chans $ \pfs ->
    withArrayLen pfs $ \len ppf -> do
      numchans <- getChannelCount s
      if numchans == len
        then withRawState s $ \r -> f r ppf samples final
        else error $ unwords
          [ fname ++ ": passed"
          , show len
          , "channels but State needs"
          , show numchans
          ]

study :: State -> [StorableArray Int CFloat] -> Bool -> IO ()
study = studyProcess "study" Raw.study

process :: State -> [StorableArray Int CFloat] -> Bool -> IO ()
process = studyProcess "process" Raw.process

-- | Returns 'Nothing' if all data has been fully processed.
available :: State -> IO (Maybe Int)
available s = withRawState s $ \r -> do
  i <- Raw.available r
  return $ guard (i /= (-1)) >> Just i

retrieveInto :: State -> [Ptr CFloat] -> Int -> IO Int
retrieveInto s pfs samples = do
  numchans <- getChannelCount s
  withArrayLen pfs $ \len ppf ->
    if len == numchans
      then withRawState s $ \r -> Raw.retrieve r ppf samples
      else error $ unwords
        [ "retrieveInto: passed"
        , show len
        , "channels but State needs"
        , show numchans
        ]

retrieve :: State -> Int -> IO [StorableArray Int CFloat]
retrieve s samples = do
  numchans <- getChannelCount s
  ps <- replicateM numchans $ mallocArray samples
  actual <- retrieveInto s ps samples
  forM ps $ \p -> do
    fp <- newForeignPtr finalizerFree p
    unsafeForeignPtrToStorableArray fp (0, actual - 1)

getChannelCount :: State -> IO Int
getChannelCount s = withRawState s Raw.getChannelCount

calculateStretch :: State -> IO ()
calculateStretch s = withRawState s Raw.calculateStretch

setDebugLevel :: State -> Int -> IO ()
setDebugLevel s n = withRawState s $ \r -> Raw.setDebugLevel r n

setDefaultDebugLevel :: Int -> IO ()
setDefaultDebugLevel = Raw.setDefaultDebugLevel
