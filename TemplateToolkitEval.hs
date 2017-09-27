module TemplateToolkitEval where

import TemplateToolkitAST
import Data.List
import Data.Foldable (toList)
import Control.Applicative ((<*))
import Control.Monad.State
import System.Directory
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.HashMap.Lazy as HashMap (toList)

import Data.Char (toUpper,toLower,isDigit)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO (readFile)
import qualified Data.Text.Encoding as TE (decodeUtf8)
import qualified Data.Text.Lazy as TL (fromStrict)
import qualified Data.Text.Lazy.Encoding as TLE (encodeUtf8)
import qualified Data.ByteString.Char8 as BS

import Text.Regex.PCRE
import qualified Text.Regex.PCRE.ByteString.Utils as PCRE
import qualified Network.URI.Encode as URI (encodeText)
import qualified Data.Aeson as Aeson
import Data.Scientific (floatingOrInteger)

import Debug.Trace

type TErr = String
type EvaldStmt = Either TErr T.Text
    
instance Eq Val where
    (==) (VFloat x) (VFloat y) = x == y
    (==) (VFloat x) (VInt y) = x == (fromInteger y)
    (==) (VInt x) (VFloat y) = (fromInteger x) == y
    (==) (VInt x) (VInt y) = x == y
    (==) x@(VFloat _) y = x == (toNum y)
    (==) x y@(VFloat _) = (toNum x) == y
    (==) x@(VInt _) y = x == (toNum y)
    (==) x y@(VInt _) = (toNum x) == y
    (==) (VString a) (VString b) = a == b

instance Ord Val where
    compare (VFloat x) (VFloat y) = compare x y
    compare (VFloat x) (VInt y) = compare x (fromInteger y)
    compare (VInt x) (VFloat y) = compare (fromInteger x) y
    compare (VInt x) (VInt y) = compare x y
    compare (VString x) (VString y) = compare x y
    compare x@(VString _) y@(VFloat _) = compare (toNum x) y
    compare x@(VString _) y@(VInt _) = compare (toNum x) y
    compare x@(VFloat _) y@(VString _) = compare x (toNum y)
    compare x@(VInt _) y@(VString _) = compare x (toNum y)
    
instance Num Val where
    (+) (VInt x) (VInt y) = VInt (x + y)
    (+) (VInt x) (VFloat y) = VFloat (fromInteger x + y)
    (+) (VFloat x) (VFloat y) = VFloat (x + y)
    (+) (VFloat x) (VInt y) = VFloat (x + fromInteger y)
    (+) x y = (toNum x) + (toNum y)
    (*) (VInt x) (VInt y) = VInt (x * y)
    (*) (VInt x) (VFloat y) = VFloat (fromInteger x * y)
    (*) (VFloat x) (VFloat y) = VFloat (x * y)
    (*) (VFloat x) (VInt y) = VFloat (x * fromInteger y)
    (*) x y = (toNum x) * (toNum y)
    abs (VInt x) = VInt (abs x)
    abs (VFloat x) = VFloat (abs x)
    abs x = abs (toNum x)
    signum (VInt x) = VInt (signum x)
    signum (VFloat x) = VFloat (signum x)
    signum x = signum (toNum x)
    fromInteger = VInt
    negate (VInt x) = VInt (negate x)
    negate (VFloat x) = VFloat (negate x)
    negate x = negate (toNum x)
    
instance Fractional Val where
    fromRational = VFloat . fromRational
    (/) (VFloat x) (VFloat y) = VFloat (x / y)
    (/) (VFloat x) (VInt y) = VFloat (x / fromInteger y)
    (/) (VInt x) (VFloat y) = VFloat (fromInteger x / y)
    (/) (VInt x) (VInt y) = VFloat (fromInteger x / fromInteger y)
    (/) x y = (toNum x) / (toNum y)

    
fromAeson :: Aeson.Value -> Expr
fromAeson Aeson.Null = EVal Undef
fromAeson (Aeson.Bool True) = EVal $ VInt 1
fromAeson (Aeson.Bool False) = EVal $ VInt 0
fromAeson (Aeson.Number x) = case floatingOrInteger x of
    (Left f) -> EVal . VFloat . realToFrac $ f
    (Right i) -> EVal . VInt . fromInteger $ i
fromAeson (Aeson.String s) = EVal $ VString s
fromAeson (Aeson.Array a) = EVal . VArray . (map fromAeson) . toList $ a
fromAeson (Aeson.Object o) = EVal . VHash . (map (\(k,v) -> (T.unpack k,fromAeson v))) . HashMap.toList $ o
    
refTableInsert :: Hash -> Val -> (String,Hash)
refTableInsert refTableOrig v = (refId, refTableNew) where
    refId = reftype ++ "ref#" ++ show (Map.size refTableOrig + 1)
        where reftype = case v of
                VHashV _ -> "hash"
                VArrayV _ -> "array"
                _ -> ""
    refTableNew = Map.insert refId v refTableOrig
    
getFromHash :: String -> Hash -> Val
getFromHash = Map.findWithDefault (Undef)

getVal :: (String,Val) -> VarNode -> StateT Env IO (String,Val)
getVal (_,VRef r') k = do
    (_,reft) <- get
    getVal (r',getFromHash r' reft) k
getVal (r,VHashV h) (VarKey k) = do
    case Map.lookup k h of
        Nothing -> case lookup k vmethods of
            Nothing -> return (r,Undef)
            Just m -> m (VHashV h) [] r
        Just v -> return (r,v)
getVal (r,VArrayV a) (VarIndex i) = return $ if Seq.length a <= (fromIntegral i) then (r,Undef) else (r,Seq.index a i)
getVal (r,v) (VarMethod met pars) = case lookup met vmethods of
    -- Nothing -> return (r,Undef)
    Nothing -> return (r,VString . T.pack $ "Invalid method '" ++ met ++ "'")
    Just m -> m v pars r
getVal (r,v) (VarKey k) = do
    case lookup k vmethods of
        Nothing -> return (r,Undef)
        Just m -> m v [] r
getVal (r,_) _ = return (r,Undef)
    
getVar :: Var -> StateT Env IO (String,Val)
getVar (Var ((VarKey k0):vs)) = do
    (vars,reft) <- get
    getVar' ("",getFromHash k0 vars) vs
    where getVar' (r,val) (v':vs') = do
                k' <- getNode v'
                (r',v') <- getVal (r,val) k'
                getVar' (r',v') vs'
          getVar' (r,val) [] = return (r,val)
          getNode (VarRef r) = do
                val <- getVar r
                case val of
                    (_,VInt i) -> return $ VarIndex (fromIntegral i)
                    (_,v) -> return $ VarKey (toString v)
          getNode n = return n

getVarVal :: Var -> StateT Env IO Val
getVarVal var = do
    (_,val) <- getVar var
    case val of
        (VRef r) -> do
            (_,reft) <- get
            return $ getFromHash r reft
        _ -> return val
          
toNum :: Val -> Val
toNum (VString s) = case reads (T.unpack s) :: [(Integer,String)] of
    [] -> case reads (T.unpack s) :: [(Double,String)] of
        [] -> VInt 0
        (s',_):_ -> VFloat s'
    (s',_):_ -> VInt s'
toNum v@(VInt _) = v
toNum v@(VFloat _) = v
toNum _  = VInt 0
-- toNum Undef = VInt 0
-- toNum _ = error "Can't use Array/Hash in numeric operation"

toInt :: Val -> Int
toInt (VFloat v) = fromIntegral . truncate $ v
toInt (VInt v) = fromIntegral v
toInt v = toInt . toNum $ v

toString :: Val -> String
toString (VString v) = T.unpack v
toString (VInt v) = show v
toString (VFloat v) = show v
toString (VRef v) = v
toString _ = ""

toText :: Val -> T.Text
toText (VString v) = v
toText v = T.pack . toString $ v

not' :: Val -> Val
not' (VString s) = if (T.unpack s) == "" then VInt 1 else VInt 0
not' (VInt 0) = VInt 1
not' (VFloat 0.0) = VInt 1
not' (Undef) = VInt 1
not' _ = VInt 0

evalUnOp :: UnOp -> Expr -> StateT Env IO Val
evalUnOp Pos e = liftM toNum (evalExpr e)
evalUnOp Neg e = liftM (negate . toNum) (evalExpr e)
evalUnOp Not e = liftM not' (evalExpr e)

isValTrue :: Val -> Bool
isValTrue v = not' v == VInt 0

evalBinOp' :: (Val -> Val -> Val) -> Expr -> Expr -> StateT Env IO Val
evalBinOp' f e1 e2 = liftM2 f (evalExpr e1) (evalExpr e2)
evalBinBoolOp' :: (Val -> Val -> Bool) -> Expr -> Expr -> StateT Env IO Val
evalBinBoolOp' f e1 e2 = do
    x' <- evalExpr e1
    y' <- evalExpr e2
    case f x' y' of
        True -> return $ VInt 1
        False -> return $ VInt 0
evalBinOp :: BinOp -> Expr -> Expr -> StateT Env IO Val
evalBinOp Add = evalBinOp' (+)
evalBinOp Sub = evalBinOp' (-)
evalBinOp Mul = evalBinOp' (*)
evalBinOp Div = div'
    where div' x y = do
            x' <- evalExpr x
            y' <- evalExpr y
            return $ if (toInt y') == 0 then VString (T.pack "Error: Division by zero") else x' / y'
evalBinOp Mod = mod'
    where mod' x y = liftM2 mod'' (evalExpr x) (evalExpr y)
          mod'' (VInt x) (VInt y) = VInt $ x `mod` y
          mod'' _ _ = VString . T.pack $ "Error: Not integer in 'mod' operation"
evalBinOp Con = con'
    where con' x y = do
            x' <- evalExpr x
            y' <- evalExpr y
            return $ VString (toText x' `T.append` toText y')
evalBinOp Gt = evalBinBoolOp' (>)
evalBinOp Ge = evalBinBoolOp' (>=)
evalBinOp Lt = evalBinBoolOp' (<)
evalBinOp Le = evalBinBoolOp' (<=)
evalBinOp Eq = evalBinBoolOp' (==)
evalBinOp Ne = evalBinBoolOp' (/=)
evalBinOp And = and'
    where and' e1 e2 = do
            v1' <- evalExpr e1
            if isValTrue v1'
            then do
                v2' <- evalExpr e2
                if isValTrue v2'
                then return v2'
                else return $ VInt 0
            else return $ VInt 0
evalBinOp Or = or'
    where or' e1 e2 = do
            v1' <- evalExpr e1
            if isValTrue v1'
            then return v1'
            else do
                v2' <- evalExpr e2
                if isValTrue v2'
                then return v2'
                else return $ VInt 0

evalExpr :: Expr -> StateT Env IO Val
evalExpr (EVal (VArray xs)) = do
    xs' <- mapM evalExprWithRef xs
    return $ VArrayV $ Seq.fromList xs'
    -- (vars,reft) <- get
    -- let (id,reft') = refTableInsert reft (VArrayV $ Seq.fromList xs')
    -- put (vars,reft')
    -- return $ VRef id
evalExpr (EVal (VArrayRange e1 e2)) = do
    from' <- evalExpr e1
    to' <- evalExpr e2
    return $ VArrayV . Seq.fromList . (map (VInt . fromIntegral)) $ [(toInt from')..(toInt to')]
    -- arr' <- evalExpr . EVal . VArray $ (map (EVal . VInt . fromIntegral) [(toInt from')..(toInt to')])
    -- return arr'
evalExpr (EVal a@(VArrayV _)) = do
    return a
    -- (vars,reft) <- get
    -- let (id,reft') = refTableInsert reft a
    -- put (vars,reft')
    -- return $ VRef id
evalExpr (EVal (VHash xs)) = do
    let (ks',es') = unzip xs
    vs' <- mapM evalExprWithRef es'
    return $ VHashV (Map.fromList (zip ks' vs'))
    -- (vars,reft) <- get
    -- let (id,reft') = refTableInsert reft (VHashV $ Map.fromList (zip ks' vs'))
    -- put (vars,reft')
    -- return $ VRef id
evalExpr (EVal (VIString vs)) = do
    let getVIString (IString s) = return s
        getVIString (IVar v) = liftM (toText . snd) (getVar v)
    vs' <- mapM getVIString vs
    return $ VString (T.concat vs')
    
evalExpr (EVal v) = return v
evalExpr (EVar var) = do
    (_,val) <- getVar var
    return val
evalExpr (EUnOp op e) = evalUnOp op e
evalExpr (EBinOp op e1 e2) = evalBinOp op e1 e2
evalExpr (ETerOp e1 e2 e3) = do
    v1' <- evalExpr e1
    if isValTrue v1'
    then evalExpr e2
    else evalExpr e3

evalExprWithRef :: Expr -> StateT Env IO Val
evalExprWithRef e = do
    v <- evalExpr e
    case v of
        a@(VArrayV _) -> do
            (vars,reft) <- get
            let (id,reft') = refTableInsert reft a
            put (vars,reft')
            return $ VRef id
        h@(VHashV _) -> do
            (vars,reft) <- get
            let (id,reft') = refTableInsert reft h
            put (vars,reft')
            return $ VRef id
        x -> return x

--
----- statement evaluators
--

fst3 :: (a,b,c) -> a
fst3 (x,_,_) = x

snd3 :: (a,b,c) -> b
snd3 (_,x,_) = x

trd3 :: (a,b,c) -> c
trd3 (_,_,x) = x

evalOrSkipStmt :: Stmt -> StateT Env IO EvaldStmt
evalOrSkipStmt stmt = do
    (_,reft) <- get
    let (VHashV loops) = Map.findWithDefault (VHashV Map.empty) "#loopcontrols" reft
    let (VInt breakCode) = Map.findWithDefault (VInt 0) (show . fst3 . sId $ stmt) loops
    if breakCode == 0
    then evalStmt stmt
    else return $ Right T.empty

evalStmt :: Stmt -> StateT Env IO EvaldStmt

evalStmt (Seq ss stmtId _) = do
    ss' <- mapM evalOrSkipStmt ss
    case sequence ss' of
        (Right txts) -> return $ Right (T.concat txts)
        (Left err) -> return $ Left err

evalStmt (SComment _ _) = return $ Right T.empty
    
evalStmt (SText s stmtId _) = return $ Right s

evalStmt (SExpr e stmtId _) = do
    val <- evalExpr e
    return $ Right (toText val)
evalStmt (SAssign (Var varPath@((VarKey k0):vs)) e stmtId _) = do
    val <- evalExprWithRef e
    if null vs
    then do
        modify (\(vars,reft) -> (Map.insert k0 val vars,reft))
        return $ Right T.empty
    else do
        var <- getVar (Var $ init varPath)
        updateRefTable var (last varPath) val >> (return $ Right T.empty)
            where updateRefTable :: (String,Val) -> VarNode -> Val -> StateT Env IO ()
                  updateRefTable (r,VHashV h) (VarKey k) val = modify (\(vars,reft) -> (vars,Map.insert r (VHashV $ Map.insert k val h) reft))
                  updateRefTable (r,VHashV h) (VarMethod "item" (e':_)) val = do
                        k' <- evalExpr e'
                        modify (\(vars,reft) -> (vars,Map.insert r (VHashV $ Map.insert (toString k') val h) reft))
                  updateRefTable (r,VArrayV a) (VarIndex i) val = modify (\(vars,reft) -> (vars,Map.insert r (VArrayV $ updateArr' i val a) reft))
                        where updateArr' i val a = if (Seq.length a > i) then (Seq.update i val a)
                                                   else (a Seq.>< (Seq.replicate (i - Seq.length a) (Undef))) Seq.|> val
                  updateRefTable (_,VRef r) vark val = do
                        (_,reft) <- get
                        updateRefTable (r,getFromHash r reft) vark val
                  updateRefTable v k val = error $ "Reftable update error.\n" ++ (show (v,k,val))
    
evalStmt (SIf cond body maybeElse stmtId _) = do
    v' <- evalExpr cond
    if isValTrue v'
    then evalOrSkipStmt body
    else evalElse' maybeElse
        where evalElse' Nothing = return $ Right T.empty
              evalElse' (Just (Elsif cond' body' maybeElse')) = do
                    v'' <- evalExpr cond'
                    if isValTrue v''
                    then evalOrSkipStmt body'
                    else evalElse' maybeElse'
              evalElse' (Just (Else body'')) = evalOrSkipStmt body''
          
evalStmt whileStmt@(SWhile cond body stmtId _) = do
    -- collectGarbage
    isSkip <- loopStart (snd3 . sId $ whileStmt)
    val <- evalExpr cond
    if isValTrue val && (not isSkip)
    then do
        v' <- evalOrSkipStmt body
        v'' <- evalOrSkipStmt whileStmt
        return $ liftM2 T.append v' v''
    else return $ Right T.empty
    
evalStmt foreachStmt@(SForeach var expr body stmtId lineN) = do
    -- collectGarbage
    isSkip <- loopStart (snd3 . sId $ foreachStmt)
    val <- evalExpr expr
    foreach' val isSkip <* loopEnd (sId foreachStmt)
        where foreach' :: Val -> Bool -> StateT Env IO EvaldStmt
              foreach' (VRef r') False = do
                    (_,reft) <- get
                    foreach' (getFromHash r' reft) False
              foreach' (VArrayV a') False = case toList a' of
                    [] -> return $ Right T.empty
                    (x:xs) -> do
                        evalIterator (snd3 stmtId) a' (+1)
                        evalStmt (SAssign var (EVal x) stmtId lineN)
                        v' <- evalStmt body
                        -- v'' <- evalStmt $ SForeach var (EVal . VArrayV $ Seq.fromList xs) body stmtId
                        isSkip' <- loopStart (snd3 . sId $ foreachStmt)
                        v'' <- foreach' (VArrayV $ Seq.fromList xs) isSkip'
                        return $ liftM2 T.append v' v''
              foreach' x False = foreach' (VArrayV $ Seq.singleton x) False
              foreach' _ True = return $ Right T.empty
                    
evalStmt (SBlock name body stmtId _) = do
    (vars,reft) <- get
    let (VHashV coderefs) = Map.findWithDefault (VHashV Map.empty) "#coderefs" reft
    let coderefs' = Map.insert name (VCode body) coderefs
    put (vars,Map.insert "#coderefs" (VHashV coderefs') reft)
    return $ Right T.empty

evalStmt (SProcess name assigns stmtId _) = do
    mapM evalOrSkipStmt assigns
    (VString name') <- evalExpr (EVal (VIString [name]))
    evalNamedBlock (T.unpack name',stmtId)

evalStmt (SWrapper name assigns body stmtId lineN) = do
    (VString name') <- evalExpr (EVal (VIString [name]))
    mapM evalOrSkipStmt assigns >> return T.empty
    content <- evalOrSkipStmt body
    case content of
        Right content' -> (evalStmt $ SAssign (Var [VarKey "content"]) (EVal (VString content')) (0,0,0) lineN)
                          >> evalNamedBlock (T.unpack name',stmtId)
        Left err -> return $ Left err

evalStmt (SFilter name exprs body stmtId _) = do
    v <- evalStmt body
    case v of
        Left err -> return $ Left err
        Right v' -> case lookup name filters of
                        Nothing -> return $ Left ("Invalid filter '" ++ name ++ "'")
                        Just f -> liftM Right (f exprs v')
                          
evalStmt (SLast (parent,_,_) _) = do
    evalLastNext parent (-1)

evalStmt (SNext (parent,_,_) _) = do
    evalLastNext parent 1

evalNamedBlock :: (String,StmtId) -> StateT Env IO EvaldStmt
evalNamedBlock (name,stmtId) = do
    env@(_,reft) <- get
    let (VHashV coderefs) = Map.findWithDefault (VHashV Map.empty) "#coderefs" reft
    case Map.lookup name coderefs of
        (Just (VCode body)) -> evalOrSkipStmt body
        Nothing -> do
            t <- getVarVal (Var [VarKey "_SETTINGS", VarKey "TEMPLATES", VarKey name])
            case t of
                Undef -> return $ Left ("\"" ++ name ++ "\" not found")
                tn -> do
                    tf <- lift $ TIO.readFile (toString tn)
                    let stmtId' = (fst3 stmtId, (trd3 stmtId) + 1, (trd3 stmtId) + 1)
                    case parseTemplateWithStmtId tf name stmtId' of
                        Left err -> return $ Left (name ++ ": " ++ (show err))
                        Right stmt -> do
                            evalStmt (SBlock (toString tn) stmt stmtId' 0)
                            evalOrSkipStmt stmt

    
evalLastNext :: Int -> Int -> StateT Env IO EvaldStmt
evalLastNext parent breakCode = do
    (vars,reft) <- get
    let (VHashV loops) = Map.findWithDefault (VHashV Map.empty) "#loopcontrols" reft
    let loops' = Map.insert (show parent) (VInt $ fromIntegral breakCode) loops
    put (vars,Map.insert "#loopcontrols" (VHashV loops') reft)
    return $ Right T.empty
    
loopStart :: Int -> StateT Env IO Bool
loopStart loopId = do
    (vars,reft) <- get
    let (VHashV loops) = Map.findWithDefault (VHashV Map.empty) "#loopcontrols" reft
        (VInt breakCode) = Map.findWithDefault (VInt 0) (show loopId) loops
        loops' = Map.insert (show loopId) (VInt $ if breakCode /= (-1) then 0 else (-1)) loops
    put (vars,Map.insert "#loopcontrols" (VHashV loops') reft)
    return $ if breakCode == (-1) then True else False
    
loopEnd :: StmtId -> StateT Env IO ()
loopEnd loopId = do
    modify (\(vars,reft) -> (vars,Map.delete ("#foreacharr" ++ (show $ snd3 loopId)) reft))
    modify (\(vars,reft) -> (vars,Map.delete ("#foreach" ++ (show $ snd3 loopId)) reft))
    (vars,reft) <- get
    let (VHashV loops) = Map.findWithDefault (VHashV Map.empty) "#loopcontrols" reft
        loops' = Map.insert (show $ snd3 loopId) (VInt 0) loops
        reft' = Map.insert "#loopcontrols" (VHashV loops') reft
        (VArrayV outer) = Map.findWithDefault (VArrayV Seq.empty) ("#foreacharr" ++ (show $ fst3 loopId)) reft'
    if Seq.null outer then put (Map.delete "loop" vars,reft') >> return ()
    else put (vars,reft') >> evalIterator (fst3 loopId) outer id
    
evalIterator :: Int -> Array -> (Val -> Val) -> StateT Env IO ()
evalIterator loopId arr iterFunc = do
    (vars,reft) <- get
    let l' = fromIntegral $ Seq.length arr
        start = [("size",VInt l')
                ,("max",VInt $ l' - 1)
                ,("index",VInt (-1))
                ]
        (VHashV h') = Map.findWithDefault (VHashV $ Map.fromList start) ("#foreach" ++ show loopId) reft
        (VArrayV a') = Map.findWithDefault (VArrayV arr) ("#foreacharr" ++ show loopId) reft
        (VInt i) = iterFunc (h' Map.! "index")
        (VInt iMax) = h' Map.! "max"
        h = flip Map.union h' (Map.fromList [("index",VInt i)
                                           ,("count",VInt i+1)
                                           ,("first",if i == 0 then VInt 1 else VInt 0)
                                           ,("last",if i == iMax then VInt 1 else VInt 0)
                                           ,("prev",if i == 0 then Undef else (a' `Seq.index` (fromIntegral i - 1)))
                                           ,("next",if i == iMax then Undef else (a' `Seq.index` (fromIntegral i + 1)))
                                           ,("odd",if (i + 1) `mod` 2 == 0 then VInt 0 else VInt 1)
                                           ,("even",if (i + 1) `mod` 2 == 0 then VInt 1 else VInt 0)
                                           ])
        reft' = Map.insert ("#foreach" ++ show loopId) (VHashV h) reft
        reft'' = Map.insert ("#foreacharr" ++ show loopId) (VArrayV a') reft'
        vars'' = Map.insert "loop" (VHashV h) vars
    put (vars'',reft'')
    return ()

{-
collectGarbage :: StateT Env IO ()
collectGarbage = do
    (vars,reft) <- get
    let usedRefs = map (toString . snd) (filter (isRef) (Map.toList vars))
            where isRef (_,VRef _) = True
                  isRef _ = False
        reft' = Map.filterWithKey inRefTable reft
            where inRefTable ('#':_) _ = True
                  inRefTable k _ = k `elem` usedRefs
    put (vars,reft')
    return ()
-}    

                    
--
----- /statement evaluators
--


--
----- common functions for vmethods and filters
--

_changefirst' s change = case T.unpack s of
    x:xs -> T.pack $ (change x):xs
    [] -> T.empty
_Lcfirst' s = _changefirst' s toLower
_Lower' = T.toLower
_Ucfirst' s = _changefirst' s toUpper
_Upper' = T.toUpper
_Replace' s re su = case PCRE.substituteCompile' (BS.pack re) (BS.pack . T.unpack $ s) (BS.pack su) of
                        Left err -> error err
                        Right bs -> TE.decodeUtf8 $ bs
_Trim' s = _Replace' s "(^\\s+|\\s+$)" ""
_Collapse' s = _Trim' $ _Replace' s "\\s+" " "

--
----- /common functions for vmethods and filters
--

--
----- vmethods
--

vmethods =
    [("collapse",_collapse)
    ,("defined",_defined)
    ,("delete",_delete)
    ,("each",_values)
    ,("keys",_keys)
    ,("first",_first)
    ,("grep",_grep)
    ,("import",_import)
    ,("item",_item)
    ,("join",_join)
    ,("last",_last)
    ,("lcfirst",_lcfirst)
    ,("length",_length)
    ,("lower",_lower)
    ,("match",_match)
    ,("nsort",_nsort)
    ,("replace",_replace)
    ,("remove",_remove)
    ,("pairs",_pairs)
    ,("pop",_pop)
    ,("push",_push)
    ,("reverse",_reverse)
    ,("shift",_shift)
    ,("size",_size)
    ,("slice",_slice)
    ,("sort",_sort)
    ,("splice",_splice)
    ,("split",_split)
    ,("trim",_trim)
    ,("ucfirst",_ucfirst)
    ,("unique",_unique)
    ,("unshift",_unshift)
    ,("upper",_upper)
    ,("values",_values)
    
    ] where
    getter v _ r = return (r,v)
    
    _match' :: Val -> String -> [Val]
    _match' v re = map (VString . TE.decodeUtf8) matches
        where bs = (BS.pack . toString $ v) =~ re :: AllTextSubmatches [] BS.ByteString
              matches = case getAllTextSubmatches bs of
                    [] -> []
                    (full:[]) -> [full]
                    (_:subs) -> subs
        
    _matchGlobal' :: Val -> String -> [Val]
    _matchGlobal' v re = case _match' (VString $ T.pack re) "\\(.+\\)" of
        [] -> matches 
        _ -> concat $ map (\m' -> _match' m' re) matches
        where matches = map (VString . TE.decodeUtf8) $ getAllTextMatches ((BS.pack . toString $ v) =~ re :: AllTextMatches [] BS.ByteString)

    _size' (VArrayV a) = fromIntegral $ Seq.length a
    
    _splice' a offs leng arr = (Seq.take offs'' a) Seq.>< arr Seq.>< (Seq.drop (offs'' + leng'') a)
        where l = Seq.length a
              offs' = if offs < 0 then l + offs + 1 else offs
              offs'' = if offs' < 0 then 0 else offs'
              leng' = if leng < 0 then (l - offs'' + leng) else leng
              leng'' = if leng' < 0 then 0 else leng'
 
    _collapse s _ r = return (r, VString . _Collapse' . toText $ s)
    
    _defined h@(VHashV _) (k:_) r = do
        k' <- evalExpr k
        (r',v) <- getVal (r,h) (VarKey . toString $ k')
        _defined v [] r
    _defined a@(VArrayV _) (i:_) r = do
        i' <- evalExpr i
        (r',v) <- getVal (r,a) (VarIndex . toInt $ i')
        _defined v [] r
    _defined Undef _ r = return (r,VInt 0)
    _defined _ _ r = return (r,VInt 1)
    
    _delete _ [] r = return (r,Undef)
    _delete (VHashV h) (e:es) r = do
        k <- evalExpr e
        let vh = VHashV $ Map.delete (toString k) h
        modify (\(vars,reft) -> (vars,Map.insert r vh reft))
        _delete vh es r
    
    _each (VHashV h) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArray . concat . map (\(k,v) -> [(EVal . VString . T.pack $ k),EVal v]) $ (Map.toList h)
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . concat . map (\(k,v) -> [(VString . T.pack $ k),v]) $ (Map.toList h)
    _each _ _ r = return (r,Undef)
    
    _first a@(VArrayV a') [] r = if (_size' a) > 0 then return (r,a' `Seq.index` 0) else return (r,Undef)
    _first (VArrayV a) (e:_) r = do
        i <- evalExpr e
        -- (VRef id) <- evalExpr . EVal . VArrayV $ Seq.take (toInt i) a
        -- return (id,VRef id)
        return (r, VArrayV $ Seq.take (toInt i) a)
    _first _ _ r = return (r,Undef)
    
    _grep (VArrayV a) (re:_) r = do
        re' <- liftM toString (evalExpr re)
        let a' = filter (\v -> not . null $ _match' v re') (toList a)
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.fromList $ a'
        -- return (id,VRef id)
        return (r, VArrayV . Seq.fromList $ a')
    
    _import (VHashV h) (e:es) r = do
        v <- evalExpr e
        case v of
            (VRef r') -> do
                (_,reft) <- get
                let v' = reft Map.! r'
                _import (VHashV h) ((EVal v'):es) r
            (VHashV h') -> do
                let vh = VHashV $ Map.union h' h
                modify (\(vars,reft) -> (vars,Map.insert r vh reft))
                _import vh es r
            _ -> _import (VHashV h) es r
    _import (VArrayV a) (e:es) r = do
        v <- evalExpr e
        case v of
            (VRef r') -> do
                (_,reft) <- get
                let v' = reft Map.! r'
                _import (VArrayV a) ((EVal v'):es) r
            (VArrayV a') -> do
                let va = VArrayV $ a Seq.>< a'
                modify (\(vars,reft) -> (vars,Map.insert r va reft))
                _import va es r
            _ -> _import (VArrayV a) es r
    _import _ _ r = return (r,Undef)
            
    _item h@(VHashV _) (e:_) r = do
        k <- evalExpr e
        (_,v) <- getVal (r,h) (VarKey .toString $ k)
        return (r,v)
    _item _ _ r = return (r,Undef)
        
    _join (VArrayV a) (e:_) r = do
        delim <- evalExpr e
        return(r,VString . T.pack . (intercalate $ toString delim) . (map toString) . toList $ a)
    _join a@(VArrayV _) [] r = _join a [(EVal . VString . T.pack $ ",")] r
    _join _ _ r = return (r,Undef)
    
    _keys (VHashV h) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArray . map (EVal . VString . T.pack) $ (Map.keys h)
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . map (VString . T.pack) $ (Map.keys h)
    _keys _ _ r = return (r,Undef)
    
    _last a@(VArrayV a') [] r = if (_size' a) > 0 then return (r,a' `Seq.index` ((_size' a) - 1)) else return (r,Undef)
    _last (VArrayV a) (e:_) r = do
        i <- evalExpr e
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.reverse $ Seq.take (toInt i) (Seq.reverse a)
        -- return (id,VRef id)
        return (r, VArrayV . Seq.reverse $ Seq.take (toInt i) (Seq.reverse a))
    _last _ _ r = return (r,Undef)
    
    _lcfirst s = getter $ VString (_Lcfirst' . toText $ s)

    _length s = getter $ VInt (fromIntegral . length . toString $ s)

    _lower s = getter $ VString (_Lower' . toText $ s)
    
    _match v (re:gl:_) r = do
        re' <- liftM toString (evalExpr re)
        gl' <- evalExpr gl
        let matcher = if isValTrue gl' then _matchGlobal' else _match'
        case matcher v re' of
            [] -> return (r,Undef)
            ms -> do
                -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.fromList $ ms
                -- return (id,VRef id)
                return (r,VArrayV . Seq.fromList $ ms)
    _match v (re:[]) r = _match v [re, EVal . VInt $ 0] r
    _match _ _ r = return (r,Undef)
            
    _nsort (VArrayV a) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.fromList . sort . (map toNum) . toList $ a
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . sort . (map toNum) . toList $ a
    _nsort _ _ r = return (r,Undef)
    
    _pairs (VHashV h) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArray . map
                -- (\(k,v) -> EVal . VHashV . Map.fromList $ [("key",VString . T.pack $ k),("value",v)]) $ (Map.toList h)
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . map
                        (\(k,v) -> VHashV . Map.fromList $ [("key",VString . T.pack $ k),("value",v)]) $ Map.toList h
    _pairs _ _ r = return (r,Undef)
    
    _pop (VArrayV a) [] r = do
        (_,v) <- _last (VArrayV a) [] r
        let a' = VArrayV $ _splice' a (-2) 1 Seq.empty
        modify (\(vars,reft) -> (vars,Map.insert r a' reft))
        return (r,v)
    _pop _ _ r = return (r,Undef)

    _push (VArrayV a) exs r = do
        vxs <- mapM evalExpr exs
        let a' = VArrayV $ _splice' a (-1) 0 (Seq.fromList vxs)
        modify (\(vars,reft) -> (vars,Map.insert r a' reft))
        return (r,Undef)
    _push _ _ r = return (r,Undef)

    _remove v (re:_) r = _replace v [re] r
    _remove _ _ r = return (r,Undef)
    
    _replace v (re:su:_) r = do
        re' <- liftM toString (evalExpr re)
        su' <- liftM toString (evalExpr su)
        let v' = _Replace' (toText v) re' su'
        return (r,VString v')
    _replace v (re:_) r = _replace v [re, EVal . VString $ T.empty] r
    _replace _ _ r = return (r,Undef)
    
    _reverse (VArrayV a) [] r = do
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.reverse $ a
        -- return (id,VRef id)
        return (r,VArrayV . Seq.reverse $ a)
    _reverse _ _ r = return (r,Undef)
    
    _shift (VArrayV a) [] r = do
        (_,v) <- _first (VArrayV a) [] r
        let a' = VArrayV $ _splice' a 0 1 Seq.empty
        modify (\(vars,reft) -> (vars,Map.insert r a' reft))
        return (r,v)
    _shift _ _ r = return (r,Undef)
    
    _size (VHashV h) _ r = return (r,VInt . fromIntegral . length . toList $ h)
    _size a@(VArrayV _) _ r = return (r,VInt (_size' a))
    _size _ _ r = return (r,VInt 0)
    
    _slice (VArrayV a) (fr:to:_) r = do
        fr' <- liftM toInt (evalExpr fr)
        to' <- liftM toInt (evalExpr to)
        let l = Seq.length a
            fr'' = if fr' < 0 then l + fr' else fr'
            to'' = if to' < 0 then l + to' else to'
            a' = if fr'' < 0 || to'' < 0 || fr'' > to'' || fr'' > l || to'' > l then Seq.empty
                 else (Seq.take (to'' - fr'' + 1)) . (Seq.drop fr'') $ a
        -- (VRef id) <- evalExpr . EVal . VArrayV $ a'
        -- return (id,VRef id)
        return (r,VArrayV a')
    _slice (VArrayV a) (fr:_) r = _slice (VArrayV a) [fr,EVal . VInt $ (-1)] r
    _slice _ _ r = _slice (VArrayV Seq.empty) (map (EVal . VInt) [0,0]) r
            
        
    _sort (VArrayV a) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.fromList . sort . (map (VString . T.pack . toString)) . toList $ a
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . sort . (map (VString . T.pack . toString)) . toList $ a
    _sort _ _ r = return (r,Undef)
    
    _splice (VArrayV a) (eo:el:exs) r = do
        offs <- liftM toInt (evalExpr eo)
        leng <- liftM toInt (evalExpr el)
        vxs <- mapM evalExpr exs
        arr <- mapM mkArrEl vxs
        let arr' = VArrayV $ _splice' a offs leng (Seq.fromList $ concat arr)
        modify (\(vars,reft) -> (vars,Map.insert r arr' reft))
        return (r,Undef)
            where mkArrEl :: Val -> StateT Env IO [Val]
                  mkArrEl (VRef r') = do
                        (_,reft) <- get
                        mkArrEl (reft Map.! r')
                  mkArrEl (VArrayV a') = return (toList a')
                  mkArrEl v = return [v]
    _splice a@(VArrayV a') (eo:[]) r = _splice a [eo,(EVal . VInt . fromIntegral . Seq.length $ a')] r
    _splice a@(VArrayV a') [] r = _splice a [EVal (VInt 0)] r
    _splice _ _ r = return (r,Undef)
    
    _split v (re:_) r = do
        re' <- liftM toString (evalExpr re)
        let a = case PCRE.splitCompile' (BS.pack re') (BS.pack . toString $ v) of
                    Left err -> error err
                    Right vs -> VArrayV . Seq.fromList . (map (VString . TE.decodeUtf8)) $ vs
        -- (VRef id) <- evalExpr . EVal $ a
        -- return (id,VRef id)
        return (r,a)
    _split v _ r = return (r,VArrayV . Seq.singleton . VString . toText $ v)
    
    _trim s _ r = return (r, VString . _Trim' . toText $ s)

    _ucfirst s = getter $ VString (_Ucfirst' . toText $ s)
    
    _unique (VArrayV a) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArrayV . Seq.fromList . (nubBy (\x y -> toString x == toString y)) . toList $ a
        -- return (id,VRef id)
        return (r,arr)
            where arr = VArrayV . Seq.fromList . (nubBy (\x y -> toString x == toString y)) . toList $ a

    _unshift (VArrayV a) exs r = do
        vxs <- mapM evalExpr exs
        let a' = VArrayV $ _splice' a 0 0 (Seq.fromList vxs)
        modify (\(vars,reft) -> (vars,Map.insert r a' reft))
        return (r,Undef)
    _unshift _ _ r = return (r,Undef)

    _upper s = getter $ VString (_Upper' . toText $ s)

    _values (VHashV h) _ r = do
        -- (VRef id) <- evalExpr . EVal . VArray . map EVal $ (Map.elems h)
        -- return (id,VRef id)
        return (r, VArray . map EVal $ (Map.elems h))
    _values _ _ r = return (r,Undef)


--
----- /vmethods
--


--
----- filters
--

filters =
    [("collapse",_collapse)
    ,("html",_html)
    ,("lcfirst",_lcfirst)
    ,("lower",_lower)
    ,("null",_null)
    ,("replace",_replace)
    ,("trim",_trim)
    ,("ucfirst",_ucfirst)
    ,("upper",_upper)
    ,("uri",_uri)
    ] where
    _collapse _ v = return $ _Collapse' v
    _html _ s = return $ foldr (\(re,su) s' -> _Replace' s' re su) s [("<","&lt;"),(">","&gt;"),("&","&amp;"),("\"","&quot;")]
    _lcfirst _ v = return $ _Lcfirst' v
    _lower _ v = return $ _Lower' v
    _null _ _ = return T.empty
    _replace [] v = return v
    _replace (re:[]) v = _replace [re, EVal . VString $ T.empty] v
    _replace (re:su:_) v = do
        re' <- liftM toString (evalExpr re)
        su' <- liftM toString (evalExpr su)
        let v' = _Replace' v re' su'
        return v'
    _trim _ v = return $ _Trim' v
    _ucfirst _ v = return $ _Ucfirst' v
    _upper _ v = return $ _Upper' v
    _uri _ v = return $ URI.encodeText v

--
----- /filters
--
    
evalTemplate :: TName -> T.Text -> Env -> IO EvaldStmt
evalTemplate tName s env@(vars,reft) = case parseTemplate tName s of
    Left err -> return $ Left (tName ++ ": " ++ (show err))
    -- Right stmt -> evalState (evalStmt stmt) env
    Right stmt -> do
        vDirs <- evalStateT (getVarVal (Var [VarKey "_SETTINGS", VarKey "INCLUDE_PATH"])) env
        let dirs = case vDirs of
                    (VArrayV a) -> toList a
                    s@(VString _) -> [s]
                    _ -> []
            getFilesPaths d = do
                    f' <- liftM (map (\f_ -> (f_,d ++ "/" ++ f_))) (getDirectoryContents d)
                    f'' <- filterM (doesFileExist . snd) f'
                    return f''
        files <- mapM getFilesPaths (map toString dirs)
        let files' = map (\(k,v) -> (k, VString . T.pack $ v)) (concat files)
            assign = SAssign (Var [VarKey "_SETTINGS", VarKey "TEMPLATES"]) (EVal (VHashV . Map.fromList $ files')) (0,0,0) 0
        env' <- execStateT (evalStmt assign) env
        res <- runStateT (evalOrSkipStmt stmt) env'
        return $ Right (T.pack . show $ res)


evalTemplateFromAeson :: TName -> T.Text -> Aeson.Value -> IO EvaldStmt
evalTemplateFromAeson tName s aeson = case fromAeson aeson of
    (EVal (VHash h)) -> do
        -- register all json object pairs as initial variables in env
        env <- foldM assignVar (Map.empty,Map.empty) h
        evalTemplate tName s env
            where assignVar env' (k,e) = execStateT (evalStmt (SAssign (Var [VarKey k]) e (0,0,0) 0)) env'
    _ -> return $ Left "Aeson 'object' expected as a second parameter"

evalTemplateFromJson :: TName -> T.Text -> T.Text -> IO EvaldStmt
evalTemplateFromJson tName s json = case Aeson.decode (TLE.encodeUtf8 . TL.fromStrict $ json) of
    (Just v) -> evalTemplateFromAeson tName s v
    _ -> return $ Left "Invalid JSON string"
