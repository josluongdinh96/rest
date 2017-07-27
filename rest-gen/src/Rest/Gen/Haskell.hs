{-# LANGUAGE
    CPP
  , DoAndIfThenElse
  , LambdaCase
  , PatternGuards
  , TemplateHaskell
  , ViewPatterns
  #-}
module Rest.Gen.Haskell
  ( HaskellContext (..)
  , mkHsApi
  ) where

import Control.Applicative
import Control.Arrow (first, second)
import Control.Category
import Control.Monad
import Data.Label (modify, set)
import Data.Label.Derive (mkLabelsNamed)
import Data.List
import Data.Maybe
import Prelude hiding (id, (.))
import Safe
import System.Directory
import System.FilePath
import qualified Data.Generics.Uniplate.Data                 as U
import qualified Data.Label.Total                            as L
import qualified Data.List.NonEmpty                          as NList
import qualified Distribution.ModuleName                     as Cabal
import qualified Distribution.Package                        as Cabal
import qualified Distribution.PackageDescription             as Cabal
import qualified Distribution.PackageDescription.Parse       as Cabal
import qualified Distribution.PackageDescription.PrettyPrint as Cabal
import qualified Distribution.Simple.Utils                   as Cabal
import qualified Distribution.Verbosity                      as Cabal
import qualified Distribution.Version                        as Cabal
import qualified Language.Haskell.Exts.Pretty                as H
import qualified Language.Haskell.Exts.Syntax                as H

import Rest.Api (Router, Version)

import Rest.Gen.Base
import Rest.Gen.Types
import Rest.Gen.Utils
import qualified Rest.Gen.NoAnnotation          as N
import qualified Rest.Gen.Base.ActionInfo.Ident as Ident

mkLabelsNamed ("_" ++) [''Cabal.GenericPackageDescription, ''Cabal.CondTree, ''Cabal.Library]

data HaskellContext =
  HaskellContext
    { apiVersion     :: Version
    , targetPath     :: String
    , wrapperName    :: String
    , includePrivate :: Bool
    , sources        :: [N.ModuleName]
    , imports        :: [N.ImportDecl]
    , rewrites       :: [(N.ModuleName, N.ModuleName)]
    , namespace      :: [String]
    }

mkHsApi :: HaskellContext -> Router m s -> IO ()
mkHsApi ctx r =
  do let tree = sortTree . (if includePrivate ctx then id else noPrivate) . apiSubtrees $ r
     mkCabalFile ctx tree
     mapM_ (writeRes ctx) $ allSubTrees tree

mkCabalFile :: HaskellContext -> ApiResource -> IO ()
mkCabalFile ctx tree =
  do cabalExists <- doesFileExist cabalFile
     gpkg <-
       if cabalExists
       then updateExposedModules modules <$> Cabal.readPackageDescription Cabal.normal cabalFile
       else return (mkGenericPackageDescription (wrapperName ctx) modules)
     writeCabalFile cabalFile gpkg
  where
    cabalFile = targetPath ctx </> wrapperName ctx ++ ".cabal"
    modules   = map (Cabal.fromString . unModuleName) (sources ctx)
             ++ map (Cabal.fromString . qualModName . (namespace ctx ++)) (allSubResourceIds tree)

writeCabalFile :: FilePath -> Cabal.GenericPackageDescription -> IO ()
writeCabalFile path = Cabal.writeUTF8File path . unlines . filter emptyField . lines . Cabal.showGenericPackageDescription
  where emptyField = (/= "\"\" ") . takeWhile (/= ':') . reverse

updateExposedModules :: [Cabal.ModuleName] -> Cabal.GenericPackageDescription -> Cabal.GenericPackageDescription
updateExposedModules modules = modify _condLibrary (Just . maybe (mkCondLibrary modules) (set (_exposedModules . _condTreeData) modules))

mkGenericPackageDescription :: String -> [Cabal.ModuleName] -> Cabal.GenericPackageDescription
mkGenericPackageDescription name modules =
#if MIN_VERSION_Cabal(2,0,0)
  Cabal.GenericPackageDescription pkg [] (Just (mkCondLibrary modules)) [] [] [] [] []
#else
  Cabal.GenericPackageDescription pkg [] (Just (mkCondLibrary modules)) [] [] []
#endif
  where
    pkg = Cabal.emptyPackageDescription
      { Cabal.package        = Cabal.PackageIdentifier (cabalPackageName name) (cabalVersion [0, 1])
      , Cabal.buildType      = Just Cabal.Simple
      , Cabal.specVersionRaw = Right (Cabal.orLaterVersion (cabalVersion [1, 8]))
      }

mkCondLibrary :: [Cabal.ModuleName] -> Cabal.CondTree Cabal.ConfVar [Cabal.Dependency] Cabal.Library
mkCondLibrary modules = Cabal.CondNode
  { Cabal.condTreeData        = cabalLibrary modules
  , Cabal.condTreeConstraints =
     [ Cabal.Dependency (cabalPackageName "base")        (Cabal.withinVersion $ cabalVersion [4]      )
     , Cabal.Dependency (cabalPackageName "rest-types")  (Cabal.withinVersion $ cabalVersion [1, 10]  )
     , Cabal.Dependency (cabalPackageName "rest-client") (Cabal.withinVersion $ cabalVersion [0, 5, 2])
     ]
  , Cabal.condTreeComponents  = []
  }

cabalLibrary :: [Cabal.ModuleName] -> Cabal.Library
#if MIN_VERSION_Cabal(2,0,0)
cabalLibrary mods = Cabal.emptyLibrary
  { Cabal.exposedModules = mods
  , Cabal.libBuildInfo = (Cabal.libBuildInfo Cabal.emptyLibrary) { Cabal.hsSourceDirs = ["src"] }
  }
#else
#if MIN_VERSION_Cabal(1,22,0)
cabalLibrary mods = Cabal.Library mods [] [] [] True Cabal.emptyBuildInfo { Cabal.hsSourceDirs = ["src"] }
#else
cabalLibrary mods = Cabal.Library mods True Cabal.emptyBuildInfo { Cabal.hsSourceDirs = ["src"] }
#endif
#endif

cabalVersion :: [Int] -> Cabal.Version
#if MIN_VERSION_Cabal(2,0,0)
cabalVersion = Cabal.mkVersion
#else
cabalVersion v = Cabal.Version v []
#endif

cabalPackageName :: String -> Cabal.PackageName
#if MIN_VERSION_Cabal(2,0,0)
cabalPackageName =  Cabal.mkPackageName
#else
cabalPackageName = Cabal.PackageName
#endif

writeRes :: HaskellContext -> ApiResource -> IO ()
writeRes ctx node =
  do createDirectoryIfMissing True (targetPath ctx </> "src" </> modPath (namespace ctx ++ resParents node))
     writeFile (targetPath ctx </> "src" </> modPath (namespace ctx ++ resId node) ++ ".hs") (mkRes ctx node)

mkRes :: HaskellContext -> ApiResource -> String
mkRes ctx node = H.prettyPrint $ buildHaskellModule ctx node pragmas Nothing
  where
    pragmas :: [N.ModulePragma]
    pragmas = [ H.LanguagePragma () [H.Ident () "OverloadedStrings"]
              , H.OptionsPragma () (Just H.GHC) "-fno-warn-unused-imports"
              ]
    _warningText = "Warning!! This is automatically generated code, do not modify!"

buildHaskellModule :: HaskellContext -> ApiResource ->
                      [N.ModulePragma] -> Maybe N.WarningText ->
                      N.Module
buildHaskellModule ctx node pragmas warningText =
  rewriteModuleNames (rewrites ctx) $
     H.Module () (Just $ H.ModuleHead () name warningText exportSpecs) pragmas importDecls decls
  where
    name :: N.ModuleName
    name = H.ModuleName () $ qualModName $ namespace ctx ++ resId node
    exportSpecs :: Maybe N.ExportSpecList
    exportSpecs = Nothing
    importDecls :: [N.ImportDecl]
    importDecls = nub $ namedImport "Rest.Client.Internal"
                      : extraImports
                     ++ parentImports
                     ++ dataImports
                     ++ idImports
    decls :: [N.Decl]
    decls = idData node ++ concat funcs

    extraImports :: [N.ImportDecl]
    extraImports = imports ctx
    parentImports :: [N.ImportDecl]
    parentImports = map mkImport . tail . inits . resParents $ node
    dataImports :: [N.ImportDecl]
    dataImports = map (qualImport . unModuleName) datImp
    idImports :: [N.ImportDecl]
    idImports = concat . mapMaybe (return . map (qualImport . unModuleName) . Ident.haskellModules <=< snd) . resAccessors $ node

    funcs :: [[N.Decl]]
    datImp :: [N.ModuleName]
    (funcs, datImp) = second (nub . concat) . unzip . map (mkFunction (apiVersion ctx) . resName $ node) $ resItems node
    mkImport :: [String] -> N.ImportDecl
    mkImport p = (namedImport importName)
                   { H.importQualified = True
                   , H.importAs        = importAs'
                   }
      where
        importName :: String
        importName = qualModName $ namespace ctx ++ p
        importAs' :: Maybe N.ModuleName
        importAs' = fmap (H.ModuleName () . modName) . lastMay $ p

rewriteModuleNames :: [(N.ModuleName, N.ModuleName)] -> N.Module -> N.Module
rewriteModuleNames rews = U.transformBi $ \m -> lookupJustDef m m rews

noBinds :: Maybe N.Binds
noBinds = Nothing

use :: N.Name -> N.Exp
use = H.Var () . H.UnQual ()

useMQual :: Maybe N.ModuleName -> N.Name -> N.Exp
useMQual Nothing = use
useMQual (Just qual) = H.Var () . H.Qual () qual

mkFunction :: Version -> String -> ApiAction -> ([N.Decl], [N.ModuleName])
mkFunction ver res (ApiAction _ lnk ai) =
  ([H.TypeSig () [funName] fType,
    H.FunBind () [H.Match () funName fParams rhs noBinds]],
    responseModules errorI ++ responseModules output ++ maybe [] inputModules mInp)
     where
       funName :: N.Name
       funName = mkHsName ai
       fParams :: [N.Pat]
       fParams = map (H.PVar ()) $ lPars
                           ++ maybe [] ((:[]) . hsName . cleanName . description) (ident ai)
                           ++ maybe [] (const [input]) mInp
                           ++ (if null (params ai) then [] else [pList])
       lUrl :: N.Exp
       lPars :: [N.Name]
       (lUrl, lPars) = linkToURL res lnk
       mInp :: Maybe InputInfo
       mInp = fmap (inputInfo . L.get desc . chooseType) . NList.nonEmpty . inputs $ ai
       fType :: N.Type
       fType = H.TyForall () Nothing (Just ctx) $ fTypify tyParts
         where
           ctx :: N.Context
           ctx = H.CxSingle () $ H.ClassA () (H.UnQual () cls) [m]
           cls :: N.Name
           cls = H.Ident () "ApiStateC"
           m :: N.Type
           m = H.TyVar () $ H.Ident () "m"
           fTypify :: [N.Type] -> N.Type
           fTypify = \case
             []          -> error "Rest.Gen.Haskell.mkFunction.fTypify - expects at least one type"
             [ty1]       -> ty1
             [ty1, ty2]  -> H.TyFun () ty1 ty2
             (ty1 : tys) -> H.TyFun () ty1 (fTypify tys)
           tyParts :: [N.Type]
           tyParts = map qualIdent lPars
                  ++ maybe [] (return . Ident.haskellType) (ident ai)
                  ++ inp
                  ++ (if null (params ai)
                      then []
                      else [H.TyList ()
                              (H.TyTuple () H.Boxed
                                [ haskellStringType
                                , haskellStringType
                                ])])
                  ++ [H.TyApp () m
                        (H.TyApp ()
                          (H.TyApp ()
                            (H.TyCon () $ H.UnQual () (H.Ident () "ApiResponse"))
                            (responseHaskellType errorI))
                          (responseHaskellType output))]
           qualIdent :: N.Name -> N.Type
           qualIdent = \case
             (H.Ident _ s)
               | s == cleanHsName res -> H.TyCon () $ H.UnQual () tyIdent
               | otherwise            -> H.TyCon () $ H.Qual () (H.ModuleName () $ modName s) tyIdent
             H.Symbol{}               -> error "Rest.Gen.Haskell.mkFunction.qualIdent - not expecting a Symbol"
           inp :: [N.Type]
           inp | Just i <- mInp
               , i' <- inputHaskellType i = [i']
               | otherwise = []
       input :: N.Name
       input = H.Ident () "input"
       pList :: N.Name
       pList = H.Ident () "pList"
       rhs :: N.Rhs
       rhs = H.UnGuardedRhs () $ H.Let () binds expr
         where
           binds :: N.Binds
           binds = H.BDecls () [rHeadersBind, requestBind]
           rHeadersBind :: N.Decl
           rHeadersBind =
             H.PatBind () (H.PVar () rHeaders)
               (H.UnGuardedRhs () $
                 H.List ()
                   [ H.Tuple () H.Boxed
                     [ use hAccept
                     , stringLit $ dataTypesToAcceptHeader JSON $ responseAcceptType responseType
                     ]
                   , H.Tuple () H.Boxed
                     [ use hContentType
                     , stringLit $ maybe "text/plain" inputContentType mInp
                     ]])
               noBinds

           rHeaders     :: N.Name
           rHeaders     = H.Ident () "rHeaders"
           hAccept      :: N.Name
           hAccept      = H.Ident () "hAccept"
           hContentType :: N.Name
           hContentType = H.Ident () "hContentType"
           doRequest    :: N.Name
           doRequest    = H.Ident () "doRequest"

           requestBind :: N.Decl
           requestBind =
             H.PatBind () (H.PVar () request)
                (H.UnGuardedRhs () $
                  appLast
                    (H.App ()
                      (H.App ()
                        (H.App ()
                          (H.App () (H.App () (use makeReq) (stringLit str)) (stringLit ve))
                          url)
                        (if null (params ai) then H.List () [] else use pList))
                      (use rHeaders))) noBinds
             where
               str = show $ method ai
           appLast :: N.Exp -> N.Exp
           appLast e
             | Just i <- mInp = H.App () e (H.App () (use $ H.Ident () $ inputFunc i) (use input))
             | otherwise = H.App () e (stringLit "")
           makeReq :: N.Name
           makeReq = H.Ident () "makeReq"
           request :: N.Name
           request = H.Ident () "request"

           expr :: N.Exp
           expr = H.App () (H.App () (H.App () (use doRequest)
                                      (use . H.Ident () $ responseFunc errorI))
                                      (use . H.Ident () $ responseFunc output))
                                      (use request)

       ve :: String
       url :: N.Exp
       (ve, url) = ("v" ++ show ver, lUrl)
       errorI :: ResponseInfo
       errorI = errorInfo responseType
       output :: ResponseInfo
       output = outputInfo responseType
       responseType :: ResponseType
       responseType = chooseResponseType ai

linkToURL :: String -> Link -> (N.Exp, [N.Name])
linkToURL res lnk = first (H.List ()) $ urlParts res lnk ([], [])

urlParts :: String -> Link -> ([N.Exp], [N.Name]) -> ([N.Exp], [N.Name])
urlParts res lnk ac@(rlnk, pars) =
  case lnk of
    [] -> ac
    (LResource r : a@(LAccess _) : xs)
      | not (hasParam a) -> urlParts res xs (rlnk ++ [H.List () [stringLit r]], pars)
      | otherwise -> urlParts res xs (rlnk', pars ++ [H.Ident () . cleanHsName $ r])
           where
             rlnk' = rlnk ++ (H.List () [stringLit r] : tailed)
             tailed = [H.App () (useMQual qual $ H.Ident () "readId")
                             (use . hsName $ cleanName r)]
               where
                 qual :: Maybe N.ModuleName
                 qual | r == res  = Nothing
                      | otherwise = Just . H.ModuleName () $ modName r
    (LParam p : xs) -> urlParts res xs (rlnk ++ [H.List () [H.App () (use $ H.Ident () "showUrl")
                                                          (use $ hsName (cleanName p))]], pars)
    (i : xs) -> urlParts res xs (rlnk ++ [H.List () [stringLit $ itemString i]], pars)

idData :: ApiResource -> [N.Decl]
idData node =
  case resAccessors node of
    [] -> []
    [(_pth, Nothing)] -> []
    [(pth, Just i)] ->
      let pp xs | null pth = xs
                | otherwise = stringLit pth : xs
      in [ H.TypeDecl () (H.DHead () tyIdent) (Ident.haskellType i),
           H.TypeSig () [funName] fType,
           H.FunBind () [ H.Match () funName [H.PVar () x]
                            (H.UnGuardedRhs () $ H.List () $ pp [showURLx])
                            noBinds
                        ]
         ]
    ls ->
      let ctor :: (String, Maybe Ident) -> N.QualConDecl
          ctor (pth,mi) =
            H.QualConDecl () Nothing Nothing (H.ConDecl () (H.Ident () (dataName pth)) $ maybe [] f mi)
              where
                f ty = [Ident.haskellType ty]
          fun :: (String, Maybe Ident) -> [N.Decl]
          fun (pth, mi) = [H.FunBind () [H.Match () funName fparams rhs noBinds]]
            where
              (fparams, rhs) =
                case mi of
                  Nothing ->
                    ( [H.PVar () . H.Ident () $ dataName pth]
                    , H.UnGuardedRhs () $ H.List () [stringLit pth]
                    )
                  Just{}  ->  -- Pattern match with data constructor
                    ([H.PParen () $ H.PApp () (H.UnQual () $ H.Ident () (dataName pth)) [H.PVar () x]],
                     H.UnGuardedRhs () $ H.List () [stringLit pth, showURLx])
      in [ H.DataDecl () (H.DataType ()) Nothing (H.DHead () tyIdent) (map ctor ls) Nothing
         , H.TypeSig () [funName] fType
         ] ++ concatMap fun ls
    where
      x        :: N.Name
      x        = H.Ident () "x"
      fType    :: N.Type
      fType    = H.TyFun () (H.TyCon () $ H.UnQual () tyIdent) (H.TyList () haskellStringType)
      funName  :: N.Name
      funName  = H.Ident () "readId"
      showURLx :: N.Exp
      showURLx = H.App () (H.Var () $ H.UnQual () $ H.Ident () "showUrl") (H.Var () $ H.UnQual () x)

tyIdent :: N.Name
tyIdent = H.Ident () "Identifier"

mkHsName :: ActionInfo -> N.Name
mkHsName ai = hsName $ concatMap cleanName parts
  where
      parts = case actionType ai of
        Retrieve   -> case nm of
          [] -> ["access"]
          _  -> nm
          where
            nm = get ++ by ++ target
        Create     -> ["create"] ++ by ++ target
        -- Should be delete, but delete is a JS keyword and causes problems in collect.
        Delete     -> ["remove"] ++ by ++ target
        DeleteMany -> ["removeMany"] ++ by ++ target
        List       -> ["list"] ++ by ++ target
        Update     -> ["save"] ++ by ++ target
        UpdateMany -> ["saveMany"] ++ by ++ target
        Modify   -> if resDir ai == "" then ["do"] else [resDir ai]

      target = if resDir ai == "" then maybe [] ((:[]) . description) (ident ai) else [resDir ai]
      by     = ["by" | target /= [] && (isJust (ident ai) || actionType ai == UpdateMany)]
      get    = ["get" | not (isAccessor ai)]

hsName :: [String] -> N.Name
hsName []       = H.Ident () ""
hsName (x : xs) = H.Ident () $ cleanHsName $ downFirst x ++ concatMap upFirst xs

cleanHsName :: String -> String
cleanHsName s =
  if s `elem` reservedNames
    then s ++ "_"
    else intercalate "" . cleanName $ s
  where
    reservedNames =
      ["as","case","class","data","instance","default","deriving","do"
      ,"foreign","if","then","else","import","infix","infixl","infixr","let"
      ,"in","module","newtype","of","qualified","type","where"]

qualModName :: ResourceId -> String
qualModName = intercalate "." . map modName

modPath :: ResourceId -> String
modPath = intercalate "/" . map modName

dataName :: String -> String
dataName = modName

modName :: String -> String
modName = concatMap upFirst . cleanName

data InputInfo = InputInfo
  { inputModules     :: [N.ModuleName]
  , inputHaskellType :: N.Type
  , inputContentType :: String
  , inputFunc        :: String
  } deriving (Eq, Show)

inputInfo :: DataDesc -> InputInfo
inputInfo dsc =
  case L.get dataType dsc of
    String -> InputInfo [] haskellStringType "text/plain" "toLbs"
    XML    -> InputInfo (L.get haskellModules dsc) (L.get haskellType dsc) "text/xml" "toXML"
    JSON   -> InputInfo (L.get haskellModules dsc) (L.get haskellType dsc) "text/json" "toJSON"
    File   -> InputInfo [] haskellByteStringType "application/octet-stream" "id"
    Other  -> InputInfo [] haskellByteStringType "text/plain" "id"

data ResponseInfo = ResponseInfo
  { responseModules     :: [N.ModuleName]
  , responseHaskellType :: N.Type
  , responseFunc        :: String
  } deriving (Eq, Show)

outputInfo :: ResponseType -> ResponseInfo
outputInfo r =
  case outputType r of
    Nothing -> ResponseInfo [] haskellUnitType "(const ())"
    Just t -> case L.get dataType t of
      String -> ResponseInfo [] haskellStringType "toString"
      XML    -> ResponseInfo (L.get haskellModules t) (L.get haskellType t) "fromXML"
      JSON   -> ResponseInfo (L.get haskellModules t) (L.get haskellType t) "fromJSON"
      File   -> ResponseInfo [] haskellByteStringType "id"
      Other  -> ResponseInfo [] haskellByteStringType "id"

errorInfo :: ResponseType -> ResponseInfo
errorInfo r =
  case errorType r of
    -- Rest only has XML and JSON instances for errors, so we need to
    -- include at least one of these in the accept header. We don't
    -- want to make assumptions about the response type if there is no
    -- accept header so in that case we force it to be JSON.
    Nothing -> fromJustNote ("rest-gen bug: toResponseInfo' was called with a data type other than XML or JSON, responseType: " ++ show r)
             . toResponseInfo' . defaultErrorDataDesc . maybe JSON (\x -> case x of { XML -> XML; _ -> JSON })
             . fmap (L.get dataType) . outputType
             $ r
    Just t -> toResponseInfo [t]
  where
    toResponseInfo :: [DataDesc] -> ResponseInfo
    toResponseInfo xs
      = fromMaybe (error $ "Unsupported error formats: " ++ show xs ++ ", this is a bug in rest-gen.")
      . headMay
      . mapMaybe toResponseInfo'
      $ xs
    toResponseInfo' :: DataDesc -> Maybe ResponseInfo
    toResponseInfo' t = case L.get dataType t of
      XML  -> Just $ ResponseInfo (L.get haskellModules t) (L.get haskellType t) "fromXML"
      JSON -> Just $ ResponseInfo (L.get haskellModules t) (L.get haskellType t) "fromJSON"
      _    -> Nothing

defaultErrorDataDesc :: DataType -> DataDesc
defaultErrorDataDesc dt =
  DataDesc
    { _dataType       = dt
    , _haskellType    = haskellVoidType
    , _haskellModules = [ModuleName () "Rest.Types.Void"]
    }

stringLit :: String -> N.Exp
stringLit s = H.Lit () $ H.String () s s
