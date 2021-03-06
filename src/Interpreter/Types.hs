{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections   #-}

module Interpreter.Types where


import Data.Ix                (inRange)
import Data.Foldable          (fold)
import Control.Lens           hiding (Context)
import Control.Applicative
import Control.Monad          (join)
import Data.Map               as Map hiding (fold)
import Data.Monoid
import Data.List              as L
import Control.Monad.State    (State, get, put, evalState)
import Data.Maybe             (fromMaybe)
import System.Random          (randomRs, mkStdGen)

import qualified Interpreter.Queue as Q
import           Interpreter.Queue (Queue(..))
import           Interpreter.AST

data SystemState = Undefined | Success deriving Show

data Context = Context { _core :: [Instruction] , _queue :: Map Warior (Queue Address) , _warior :: Warior , coreSize :: Address} deriving Show

makeLenses ''Context

putQ :: Warior -> Address -> State Context ()
putQ w a = do
    ctx <- get
    let newMap = Map.adjust (Q.put a) w $ _queue ctx
    put $ ctx & queue .~ newMap

start :: [[Instruction]] -> Either SystemState SystemState
start codes = do
    let coreSize = 4000
        wariors  = take (length codes) [0..]
        codesLen = fold $ genericLength <$> codes
    if codesLen > coreSize then Left  Undefined
                           else Right Success
    let pos    = validatePos codes $ randomRs (0, coreSize) $ mkStdGen 0
        queues = flip Q.put (Queue [] []) <$> pos
        core   = cycle $ genericTake coreSize $ putCode pos codes
        ctx    = Context core (Map.fromList $ zip wariors queues) 0 4000

    return $ evalState (execWar 100 100 (cycle wariors)) ctx

putCode :: [Address] -> [[Instruction]] -> [Instruction]
putCode pos codes = core <> hole
    where core  = L.foldl (\a (dat, code) -> dat <> code <> a) [] $ zip holes codes 
          holes = flip genericTake hole <$> diffs pos
          hole  = repeat $ Instruction DAT I DIRECT 1 DIRECT 1
          diffs :: [Address] -> [Address]
          diffs (a : (b : cx)) = b - a : diffs cx
          diffs _              = []

validatePos :: Num a => [[Instruction]] -> [Address] -> [Address]
validatePos codes randoms =
    if invalid then validatePos codes randomTail
               else randomHead
    where (randomHead, randomTail) = genericSplitAt n randoms
          ranges                   = zipWith (\codeLen pos -> (pos, pos + codeLen)) randomHead $ genericLength <$> codes
          invalid                  = n > (fold $ fromBool <$> (inRange <$> ranges <*> randomHead))
          n                        = genericLength codes
          fromBool :: Bool -> Address
          fromBool True            = 1
          fromBool False           = 0


execWar :: Address -> Address -> [Warior] -> State Context SystemState
execWar readLimit writeLimit (w : wx) = do
    ctx@(Context _ map _ _) <- get
    if Map.null map then return Success
                else runWarior (Map.lookup w map) w readLimit writeLimit wx 

runWarior :: Maybe (Queue Address) -> Warior -> Address -> Address -> [Warior] -> State Context SystemState

runWarior Nothing _ = execWar 

runWarior (Just (Queue [] [])) w = \rl wl wx -> do
    put . (queue %~ Map.delete w) =<< get
    execWar rl wl wx

runWarior _ newWarior = \rl wl wx -> do
    Context c q w cs <- get
    let (pc, newQueue) = Q.pop $ q ! w
        newCore = genericDrop pc c
        updatedQ = (\a -> mod (a + cs - pc) cs) <$> newQueue
        newMap   = Map.insert w updatedQ q
    put $ Context newCore newMap newWarior cs
    emi94 rl wl
    execWar rl wl wx

emi94 :: Address -> Address -> State Context SystemState
emi94 readLimit writeLimit = do
    Instruction opc modifier aMode aNumber bMode bNumber <- head . _core <$> get
    (rpa, _  , ira) <- getRWpointers aMode aNumber (`mod` readLimit) (`mod` writeLimit)
    (_  , wpb, irb) <- getRWpointers bMode bNumber (`mod` readLimit) (`mod` writeLimit)
    exec opc modifier ira irb wpb rpa


getRWpointers :: Mode -> Address -> (Address -> Address) -> (Address -> Address) -> State Context (Address, Address, Instruction)
getRWpointers mode number rl wl = do
    ctx@(Context c@(fst : _) _ _ cs) <- get
    let rp                   = rl number
        wp                   = wl number
        (head, wiPre : tail) = genericSplitAt    wp c
        riPre                = flip genericIndex rp c
        modify :: (Address -> Address) -> (Instruction, Instruction, [Instruction]) 
               -- (Address -> Address) -> (Instruction, Instruction, [Instruction])
        modify action = (wiPost, riPost, newCore)
            where
                wiPost  = wiPre & bNumber %~ (`mod` cs) . action
                newCore = head <> (wiPost : tail)
                riPost  = genericIndex newCore rp
    (rp, wp, ir) <- case mode of
        IMMEDIATE -> return (0                    , 0                    , fst)
        DIRECT    -> return (rp                   , wp                   , flip genericIndex rp c)
        INDIRECT  -> return (rp + riPre ^. bNumber, wp + wiPre ^. bNumber, riPre)
        DECREMENT -> do
            let (wiPost, riPost, newCore) = modify (+ (cs - 1))
            put $ ctx & core .~ newCore
            return (rp + riPost ^. bNumber, wp + wiPost ^. bNumber, riPost)
        INCREMENT -> do
            let (_, riPost, newCore) = modify succ
            put $ ctx & core .~ newCore
            return (rp + riPost ^. bNumber, wp + wiPre ^. bNumber, riPost)
    return (rp `mod` cs, wp `mod` cs, ir)


exec :: Opcode -> Modifier -> Instruction -> Instruction -> Address -> Address -> State Context SystemState

exec DAT _  _    _    = const $ const $ return Success

exec MOV A  regA _    = movExec $ aNumber .~ (regA ^. aNumber)
exec MOV B  regA _    = movExec $ bNumber .~ (regA ^. bNumber)
exec MOV AB regA _    = movExec $ bNumber .~ (regA ^. aNumber)
exec MOV BA regA _    = movExec $ aNumber .~ (regA ^. bNumber)
exec MOV F  regA _    = movExec $ \(Instruction o m am an bm bn) -> Instruction o m am an bm bn
exec MOV X  regA _    = movExec $ \(Instruction o m am an bm bn) -> Instruction o m am bn bm an
exec MOV I  regA _    = movExec $ const regA

exec ADD m  regA regB = arith m regA regB (+)
exec MUL m  regA regB = arith m regA regB (*)
exec SUB m  regA regB = \wpb rpa -> do
    cs <- coreSize <$> get
    arith m regA regB ((-) . (+ cs)) wpb rpa
exec DIV m  regA regB = arithDiv m regA regB (quot)
exec MOD m  regA regB = arithDiv m regA regB (mod)

exec JMP _  regA _    = jmpExec True $ return ()

exec JMZ A  regA regB = exec JMZ BA regA regB
exec JMZ BA regA regB = jmpExec (regB ^. aNumber == 0) $ return ()
exec JMZ B  regA regB = exec JMZ AB regA regB
exec JMZ AB regA regB = jmpExec (regB ^. bNumber == 0) $ return ()
exec JMZ F  regA regB = exec JMZ I regA regB
exec JMZ X  regA regB = exec JMZ I regA regB
exec JMZ I  regA regB = jmpExec (regB ^. aNumber == 0 && regB ^. bNumber == 0) $ return ()

exec JMN A  regA regB = exec JMZ BA regA regB
exec JMN BA regA regB = jmpExec (regB ^. aNumber /= 0) $ return ()
exec JMN B  regA regB = exec JMZ AB regA regB
exec JMN AB regA regB = jmpExec (regB ^. bNumber /= 0) $ return ()
exec JMN F  regA regB = exec JMZ I regA regB
exec JMN X  regA regB = exec JMZ I regA regB
exec JMN I  regA regB = jmpExec (regB ^. aNumber /= 0 || regB ^. bNumber == 0) $ return ()

exec DJN A  regA regB = exec JMZ BA regA regB
exec DJN BA regA regB = \wpb -> jmpExec (regB ^. aNumber /= 0) (decrement (aNumber %~) wpb) wpb
exec DJN B  regA regB = exec JMZ AB regA regB
exec DJN AB regA regB = \wpb -> jmpExec (regB ^. bNumber /= 0) (decrement (bNumber %~) wpb) wpb
exec DJN F  regA regB = exec JMZ I regA regB
exec DJN X  regA regB = exec JMZ I regA regB
exec DJN I  regA regB = \wpb -> jmpExec (regB ^. aNumber /= 0 || regB ^. bNumber == 0) (decrement (aNumber %~) wpb >>= const (decrement (bNumber %~) wpb)) wpb

exec CMP A  regA regB = const $ const $ jmpExec (regA ^. aNumber == regB ^. aNumber) (return ()) 2 2
exec CMP B  regA regB = const $ const $ jmpExec (regA ^. bNumber == regB ^. bNumber) (return ()) 2 2
exec CMP AB regA regB = const $ const $ jmpExec (regA ^. aNumber == regB ^. bNumber) (return ()) 2 2
exec CMP BA regA regB = const $ const $ jmpExec (regA ^. bNumber == regB ^. aNumber) (return ()) 2 2
exec CMP F  regA regB = const $ const $ jmpExec (regA ^. aNumber == regB ^. aNumber &&
                                                 regA ^. bNumber == regB ^. bNumber) (return ()) 2 2
exec CMP X  regA regB = const $ const $ jmpExec (regA ^. aNumber == regB ^. bNumber &&
                                                 regA ^. bNumber == regB ^. aNumber) (return ()) 2 2
exec CMP I  regA regB = const $ const $ jmpExec (regA            == regB           ) (return ()) 2 2

exec SLT A  regA regB = const $ const $ jmpExec (regA ^. aNumber <  regB ^. aNumber) (return ()) 2 2
exec SLT B  regA regB = const $ const $ jmpExec (regA ^. bNumber <  regB ^. bNumber) (return ()) 2 2
exec SLT AB regA regB = const $ const $ jmpExec (regA ^. aNumber <  regB ^. bNumber) (return ()) 2 2
exec SLT BA regA regB = const $ const $ jmpExec (regA ^. bNumber <  regB ^. aNumber) (return ()) 2 2
exec SLT F  regA regB = exec SLT I regA regB
exec SLT I  regA regB = const $ const $ jmpExec (regA ^. aNumber <  regB ^. aNumber &&
                                                 regA ^. bNumber <  regB ^. bNumber) (return ()) 2 2
exec SLT X  regA regB = const $ const $ jmpExec (regA ^. aNumber <  regB ^. bNumber &&
                                                 regA ^. bNumber <  regB ^. aNumber) (return ()) 2 2

exec SPL _  regA _    = jmpExec True $ do
    w <- _warior <$> get
    putQ w 1

movExec :: (Instruction -> Instruction) -> Address -> Address -> State Context SystemState
movExec modifier wpb _ = do
    ctx <- get
    write modifier wpb
    putQ (_warior ctx) 1
    return Success

arith :: Modifier -> Instruction -> Instruction -> (Address -> Address -> Address) -> Address -> Address -> State Context SystemState
arith A  regA regB op = arithExec $ aNumber .~ (regB ^. aNumber) `op` (regA ^. aNumber)
arith B  regA regB op = arithExec $ bNumber .~ (regB ^. bNumber) `op` (regA ^. bNumber)
arith AB regA regB op = arithExec $ bNumber .~ (regB ^. aNumber) `op` (regA ^. bNumber)
arith BA regA regB op = arithExec $ aNumber .~ (regB ^. bNumber) `op` (regA ^. aNumber)
arith F  regA regB op = arith I  regA regB op
arith I  regA regB op = arithExec $ \(Instruction o m am an bm bn) -> Instruction o m am opA bm opB
    where opA = (regB ^. aNumber) `op` (regA ^. aNumber)
          opB = (regB ^. bNumber) `op` (regA ^. bNumber)
arith X  regA regB op = arithExec $ \(Instruction o m am an bm bn) -> Instruction o m am opB bm opA
    where opA = (regB ^. aNumber) `op` (regA ^. bNumber)
          opB = (regB ^. bNumber) `op` (regA ^. aNumber)

arithDiv :: Modifier -> Instruction -> Instruction -> (Address -> Address -> Address) -> Address -> Address -> State Context SystemState
arithDiv A  regA = if regA ^. aNumber == 0
                     then const $ const $ const $ const $ return Success
                     else arith A regA
arithDiv B  regA = if regA ^. bNumber == 0
                    then const $ const $ const $ const $ return Success
                    else arith B regA
arithDiv AB regA = if regA ^. aNumber == 0
                    then const $ const $ const $ const $ return Success
                    else arith AB regA
arithDiv BA regA = if regA ^. bNumber == 0
                    then const $ const $ const $ const $ return Success
                    else arith BA regA
arithDiv F  regA = arithDiv I regA
arithDiv I  regA = if regA ^. aNumber == 0 || regA ^. bNumber == 0
                     then const $ const $ const $ const $ return Success
                     else arith I regA
arithDiv X  regA = if regA ^. aNumber == 0 || regA ^. bNumber == 0
                    then const $ const $ const $ const $ return Success
                    else arith X regA

jmpExec :: Bool -> State Context () -> Address -> Address -> State Context SystemState
jmpExec check pre _ dst = do
    w <- _warior <$> get
    pre
    if check then putQ w dst
             else putQ w 1
    return Success


arithExec :: (Instruction -> Instruction) -> Address -> Address -> State Context SystemState
arithExec modifier wpb _ = do
    write modifier wpb
    w <- _warior <$> get
    putQ w 1
    return Success

decrement :: ((Address -> Address) -> Instruction -> Instruction) -> Address -> State Context ()
decrement setter wpb = do
    cs <- coreSize <$> get
    write (setter (+ (cs - 1))) wpb

write :: (Instruction -> Instruction) -> Address -> State Context ()
write modifier wpb = do
    ctx@(Context c _ _ cs) <- get
    let (h, i : t) = genericSplitAt wpb c
        newI = (aNumber %~ (`mod` cs)) <$> (bNumber %~ (`mod` cs)) $ modifier i
    put $ ctx & core .~ h <> (newI : t)