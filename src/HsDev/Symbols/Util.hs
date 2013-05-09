module HsDev.Symbols.Util (
	sameProject,
	inProject,
	inProject_,
	inFile,
	inModule,
	inCabal,
	bySources,
	isImported,
	isReachable,
	isVisible,

	sourceModule,
	visibleModule,
	preferredModule,

	satisfy
	) where

import Control.Monad
import Data.List
import Data.Maybe
import qualified Data.Map as M
import System.FilePath

import HsDev.Symbols
import HsDev.Project

sameProject :: Symbol a -> Symbol b -> Bool
sameProject l r = project' l == project' r where
	project' s = symbolLocation s >>= locationProject

inProject :: Project -> Symbol a -> Bool
inProject p s = Just p == project' where
	project' = symbolLocation s >>= locationProject

inProject_ :: Maybe Project -> Symbol a -> Bool
inProject_ Nothing _ = False
inProject_ (Just p) s = inProject p s

inFile :: FilePath -> Symbol a -> Bool
inFile f s = Just (normalise f) == fmap locationFile (symbolLocation s)

inModule :: String -> Symbol a -> Bool
inModule moduleName = maybe False ((== moduleName) . symbolName) . symbolModule

inCabal :: Cabal -> Symbol a -> Bool
inCabal cabal = maybe False ((== Just cabal) . moduleCabal . symbol) . symbolModule

bySources :: Symbol a -> Bool
bySources = isJust . symbolLocation

isImported :: Symbol Module -> Maybe String -> Symbol Module -> Bool
isImported m Nothing imported = maybe (symbolName imported == "Prelude") (not . importIsQualified) $ M.lookup (symbolName imported) (moduleImports $ symbol m)
isImported m (Just q) imported = maybe prelude qualifiedImport $ M.lookup (symbolName imported) (moduleImports $ symbol m) where
	qualifiedImport i = q == importModuleName i || Just q == importAs i
	prelude = symbolName imported == "Prelude" && q == "Prelude"

isReachable :: Symbol Module -> Maybe String -> Symbol Module -> Bool
isReachable m q imported
	| m == imported && (q == Nothing || q == Just (symbolName m)) = True
	| otherwise = isImported m q imported

isVisible :: Cabal -> Maybe Project -> Symbol Module -> Bool
isVisible cabal project = liftM2 (||) (inCabal cabal) (maybe (const False) inProject project)

sourceModule :: Maybe Project -> [Symbol Module] -> Maybe (Symbol Module)
sourceModule project ms = listToMaybe $ filter (inProject_ project) ms ++ filter bySources ms

visibleModule :: Cabal -> Maybe Project -> [Symbol Module] -> Maybe (Symbol Module)
visibleModule cabal project ms = listToMaybe $ filter (inProject_ project) ms ++ filter (inCabal cabal) ms

preferredModule :: Cabal -> Maybe Project -> [Symbol Module] -> Maybe (Symbol Module)
preferredModule cabal project ms = listToMaybe $ concatMap (`filter` ms) order where
	order = [
		inProject_ project,
		inCabal cabal,
		bySources,
		const True]

satisfy :: [a -> Bool] -> a -> Bool
satisfy ps x = all ($ x) ps
