{-# LANGUAGE FlexibleContexts, OverloadedStrings, MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module HsDev.Database.Update (
	Status(..), Progress(..), Task(..), isStatus,
	UpdateOptions(..),

	UpdateM(..),
	runUpdate,

	UpdateMonad,

	postStatus, waiter, updater, loadCache, getCache, runTask, runTasks,
	readDB,

	scanModule, scanModules, scanFile, scanFileContents, scanCabal, prepareSandbox, scanSandbox, scanPackageDb, scanProjectFile, scanProjectStack, scanProject, scanDirectory, scanContents,
	scanDocs, inferModTypes,
	scan,
	updateEvent, processEvent,

	-- * Helpers
	liftExceptT,

	module HsDev.Watcher,

	module Control.Monad.Except
	) where

import Control.Arrow
import Control.Concurrent.Lifted (fork)
import Control.DeepSeq
import Control.Lens (preview, _Just, view, over, set, _1, mapMOf_, each, (^..), _head)
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.Writer
import Data.Aeson
import Data.Aeson.Types
import Data.List ((\\))
import Data.Foldable (toList)
import qualified Data.Map as M
import Data.Maybe (mapMaybe, isJust, fromMaybe, catMaybes)
import Data.Maybe.JustIf
import qualified Data.Text as T (unpack)
import System.Directory (canonicalizePath, doesFileExist)
import System.FilePath
import qualified System.Log.Simple as Log

import Control.Concurrent.Worker (inWorker)
import qualified HsDev.Cache.Structured as Cache
import HsDev.Database
import HsDev.Database.Async hiding (Event)
import HsDev.Display
import HsDev.Inspect (inspectDocs, inspectDocsGhc)
import HsDev.Project
import HsDev.Sandbox
import HsDev.Stack
import HsDev.Symbols
import HsDev.Tools.Ghc.Worker (ghcWorker)
import HsDev.Tools.Ghc.Types (inferTypes)
import HsDev.Tools.HDocs
import qualified HsDev.Scan as S
import HsDev.Scan.Browse
import HsDev.Util (liftE, isParent, ordNub)
import HsDev.Server.Types (commandNotify, serverWriteCache, serverReadCache, CommandError(..), commandError_)
import HsDev.Server.Message
import HsDev.Database.Update.Types
import HsDev.Watcher
import Text.Format

onStatus :: UpdateMonad m => m ()
onStatus = asks (view updateTasks) >>= commandNotify . Notification . toJSON . reverse

childTask :: UpdateMonad m => Task -> m a -> m a
childTask t = local (over updateTasks (t:))

isStatus :: Value -> Bool
isStatus = isJust . parseMaybe (parseJSON :: Value -> Parser Task)

runUpdate :: ServerMonadBase m => UpdateOptions -> UpdateM m a -> ClientM m a
runUpdate uopts act = Log.scope "update" $ do
	(r, updatedMods) <- runWriterT (runUpdateM act' `runReaderT` uopts)
	db <- askSession sessionDatabase
	wait db
	dbval <- liftIO $ readAsync db
	let
		dbs = ordNub $ mapMaybe (preview modulePackageDb) updatedMods
		projs = ordNub $ mapMaybe (preview $ moduleProject . _Just) updatedMods
		stand = any moduleStandalone updatedMods

		modifiedDb = mconcat $ concat [
			map (`packageDbDB` dbval) dbs,
			map (`projectDB` dbval) projs,
			[standaloneDB dbval | stand]]
	serverWriteCache modifiedDb
	return r
	where
		act' = do
			(r, mlocs') <- liftM (second $ filter (isJust . preview moduleFile)) $ listen act
			db <- askSession sessionDatabase
			wait db
			let
				getMods :: (MonadIO m) => m [InspectedModule]
				getMods = do
					db' <- liftIO $ readAsync db
					return $ filter ((`elem` mlocs') . view inspectedId) $ toList $ databaseModules db'
			when (view updateDocs uopts) $ do
				Log.log Log.Trace "forking inspecting source docs"
				void $ fork (getMods >>= waiter . mapM_ scanDocs_)
			when (view updateInfer uopts) $ do
				Log.log Log.Trace "forking inferring types"
				void $ fork (getMods >>= waiter . mapM_ inferModTypes_)
			return r
		scanDocs_ :: UpdateMonad m => InspectedModule -> m ()
		scanDocs_ im = do
			im' <- liftExceptT $ S.scanModify (\opts _ -> inspectDocs opts) im
			updater $ return $ fromModule im'
		inferModTypes_ :: UpdateMonad m => InspectedModule -> m ()
		inferModTypes_ im = do
			-- TODO: locate sandbox
			s <- getSession
			im' <- liftExceptT $ S.scanModify (infer' s) im
			updater $ return $ fromModule im'
		infer' :: Session -> [String] -> PackageDbStack -> Module -> ExceptT String IO Module
		infer' s opts pdbs m = case preview (moduleLocation . moduleFile) m of
			Nothing -> return m
			Just _ -> inWorkerT (sessionGhc s) $ inferTypes opts pdbs m Nothing
		inWorkerT w = ExceptT . inWorker w . runExceptT 

-- | Post status
postStatus :: UpdateMonad m => Task -> m ()
postStatus t = childTask t onStatus

-- | Wait DB to complete actions
waiter :: UpdateMonad m => m () -> m ()
waiter act = do
	db <- askSession sessionDatabase
	act
	wait db

-- | Update task result to database
updater :: UpdateMonad m => m Database -> m ()
updater act = do
	db <- askSession sessionDatabase
	db' <- act
	update db $ return $!! db'
	tell $!! map (view moduleLocation) $ allModules db'

-- | Clear obsolete data from database
cleaner :: UpdateMonad m => m Database -> m ()
cleaner act = do
	db <- askSession sessionDatabase
	db' <- act
	clear db $ return $!! db'

-- | Get data from cache without updating DB
loadCache :: UpdateMonad m => (FilePath -> ExceptT String IO Structured) -> m Database
loadCache act = do
	mdat <- serverReadCache act
	return $ fromMaybe mempty mdat

-- | Load data from cache if not loaded yet and wait
getCache :: UpdateMonad m => (FilePath -> ExceptT String IO Structured) -> (Database -> Database) -> m Database
getCache act check = do
	dbval <- liftM check readDB
	if nullDatabase dbval
		then do
			db <- loadCache act
			waiter $ updater $ return db
			return db
		else
			return dbval

-- | Run one task
runTask :: (Display t, UpdateMonad m, NFData a) => String -> t -> m a -> m a
runTask action subj act = Log.scope "task" $ do
	postStatus $ set taskStatus StatusWorking task
	x <- childTask task act
	x `deepseq` postStatus (set taskStatus StatusOk task)
	return x
	`catchError`
	(\c@(CommandError e _) -> postStatus (set taskStatus (StatusError e) task) >> throwError c)
	where
		task = Task {
			_taskName = action,
			_taskStatus = StatusWorking,
			_taskSubjectType = displayType subj,
			_taskSubjectName = display subj,
			_taskProgress = Nothing }

-- | Run many tasks with numeration
runTasks :: UpdateMonad m => [m ()] -> m ()
runTasks ts = zipWithM_ taskNum [1..] (map noErr ts) where
	total = length ts
	taskNum n = local setProgress where
		setProgress = set (updateTasks . _head . taskProgress) (Just (Progress n total))
	noErr v = v `mplus` return ()

-- | Get database value
readDB :: SessionMonad m => m Database
readDB = askSession sessionDatabase >>= liftIO . readAsync

-- | Scan module
scanModule :: UpdateMonad m => [String] -> ModuleLocation -> Maybe String -> m ()
scanModule opts mloc mcts = runTask "scanning" mloc $ Log.scope "module" $ do
	defs <- askSession sessionDefines
	im <- liftExceptT $ S.scanModule defs opts mloc mcts
	updater $ return $ fromModule im
	_ <- return $ view inspectionResult im
	return ()

-- | Scan modules
scanModules :: UpdateMonad m => [String] -> [S.ModuleToScan] -> m ()
scanModules opts ms = runTasks $
	[scanProjectFile opts p >> return () | p <- ps] ++
	[scanModule (opts ++ mopts) m mcts | (m, mopts, mcts) <- ms]
	where
		ps = ordNub $ mapMaybe (toProj . view _1) ms
		toProj (FileModule _ p) = fmap (view projectCabal) p
		toProj _ = Nothing

-- | Scan source file
scanFile :: UpdateMonad m => [String] -> FilePath -> m ()
scanFile opts fpath = scanFileContents opts fpath Nothing

-- | Scan source file with contents
scanFileContents :: UpdateMonad m => [String] -> FilePath -> Maybe String -> m ()
scanFileContents opts fpath mcts = Log.scope "file" $ do
	dbval <- readDB
	fpath' <- liftCIO $ canonicalizePath fpath
	ex <- liftCIO $ doesFileExist fpath'
	mlocs <- if ex
		then do
			mloc <- case lookupFile fpath' dbval of
				Just m -> return $ view moduleLocation m
				Nothing -> do
					mproj <- liftCIO $ locateProject fpath'
					return $ FileModule fpath' mproj
			return [(mloc, [], mcts)]
		else return []
	mapMOf_ (each . _1) (watch . flip watchModule) mlocs
	scan
		(Cache.loadFiles (== fpath'))
		(filterDB (inFile fpath') (const False) . standaloneDB)
		mlocs
		opts
		(scanModules opts)
	where
		inFile f = maybe False (== f) . preview (moduleIdLocation . moduleFile)

-- | Scan cabal modules, doesn't rescan if already scanned
scanCabal :: UpdateMonad m => [String] -> m ()
scanCabal opts = Log.scope "cabal" $ do
	dbval <- readDB
	let
		scannedDbs = databasePackageDbs dbval
		unscannedDbs = filter ((`notElem` scannedDbs) . topPackageDb) $ reverse $ packageDbStacks userDb
	if null unscannedDbs
		then do
			Log.log Log.Trace $ "cabal (global-db and user-db) already scanned"
		else runTasks $ map (scanPackageDb opts) unscannedDbs

-- | Prepare sandbox for scanning. This is used for stack project to build & configure.
prepareSandbox :: UpdateMonad m => Sandbox -> m ()
prepareSandbox sbox@(Sandbox StackWork fpath) = Log.scope "prepare" $ runTasks [
	runTask "building dependencies" sbox $ void $ liftIO $ runMaybeT $ buildDeps myaml,
	runTask "configuring" sbox $ void $ liftIO $ runMaybeT $ configure myaml]
	where
		myaml = Just $ takeDirectory fpath </> "stack.yaml"
prepareSandbox _ = return ()

-- | Scan sandbox modules, doesn't rescan if already scanned
scanSandbox :: UpdateMonad m => [String] -> Sandbox -> m ()
scanSandbox opts sbox = Log.scope "sandbox" $ do
	dbval <- readDB
	prepareSandbox sbox
	pdbs <- liftExceptT $ sandboxPackageDbStack sbox
	let
		scannedDbs = databasePackageDbs dbval
		unscannedDbs = filter ((`notElem` scannedDbs) . topPackageDb) $ reverse $ packageDbStacks pdbs
	if null unscannedDbs
		then do
			Log.log Log.Trace $ "sandbox already scanned"
		else runTasks $ map (scanPackageDb opts) unscannedDbs

-- | Scan top of package-db stack, usable for rescan
scanPackageDb :: UpdateMonad m => [String] -> PackageDbStack -> m ()
scanPackageDb opts pdbs = runTask "scanning" (topPackageDb pdbs) $ Log.scope "package-db" $ do
	watch (\w -> watchPackageDb w pdbs opts)
	mlocs <- liftM
		(filter (\mloc -> preview modulePackageDb mloc == Just (topPackageDb pdbs))) $
		liftExceptT $ listModules opts pdbs
	scan (Cache.loadPackageDb (topPackageDb pdbs)) (packageDbDB (topPackageDb pdbs)) ((,,) <$> mlocs <*> pure [] <*> pure Nothing) opts $ \mlocs' -> do
		ms <- liftExceptT $ browseModules opts pdbs (mlocs' ^.. each . _1)
		docs <- liftExceptT $ hdocsCabal pdbs opts
		updater $ return $ mconcat $ map (fromModule . fmap (setDocs' docs)) ms
	where
		setDocs' :: Map String (Map String String) -> Module -> Module
		setDocs' docs m = maybe m (`setDocs` m) $ M.lookup (T.unpack $ view moduleName m) docs

-- | Scan project file
scanProjectFile :: UpdateMonad m => [String] -> FilePath -> m Project
scanProjectFile opts cabal = runTask "scanning" cabal $ liftExceptT $ S.scanProjectFile opts cabal

-- | Scan project and related package-db stack
scanProjectStack :: UpdateMonad m => [String] -> FilePath -> m ()
scanProjectStack opts cabal = do
	proj <- scanProjectFile opts cabal
	scanProject opts cabal
	sbox <- liftIO $ searchSandbox (view projectPath proj)
	maybe (scanCabal opts) (scanSandbox opts) sbox

-- | Scan project
scanProject :: UpdateMonad m => [String] -> FilePath -> m ()
scanProject opts cabal = runTask "scanning" (project cabal) $ Log.scope "project" $ do
	proj <- scanProjectFile opts cabal
	watch (\w -> watchProject w proj opts)
	S.ScanContents _ [(_, sources)] _ <- liftExceptT $ S.enumProject proj
	scan (Cache.loadProject $ view projectCabal proj) (projectDB proj) sources opts $ \ms -> do
		scanModules opts ms
		updater $ return $ fromProject proj

-- | Scan directory for source files and projects
scanDirectory :: UpdateMonad m => [String] -> FilePath -> m ()
scanDirectory opts dir = runTask "scanning" dir $ Log.scope "directory" $ do
	S.ScanContents standSrcs projSrcs pdbss <- liftExceptT $ S.enumDirectory dir
	runTasks [scanProject opts (view projectCabal p) | (p, _) <- projSrcs]
	runTasks $ map (scanPackageDb opts) pdbss -- TODO: Don't rescan
	mapMOf_ (each . _1) (watch . flip watchModule) standSrcs
	scan (Cache.loadFiles (dir `isParent`)) (filterDB inDir (const False) . standaloneDB) standSrcs opts $ scanModules opts
	where
		inDir = maybe False (dir `isParent`) . preview (moduleIdLocation . moduleFile)

scanContents :: UpdateMonad m => [String] -> S.ScanContents -> m ()
scanContents opts (S.ScanContents standSrcs projSrcs pdbss) = do
	dbval <- readDB
	let
		projs = databaseProjects dbval ^.. each . projectCabal
		pdbs = databasePackageDbs dbval
		files = allModules (standaloneDB dbval) ^.. each . moduleLocation . moduleFile
		srcs = standSrcs ^.. each . _1 . moduleFile
		inSrcs src = src `elem` srcs && src `notElem` files
		inFiles = maybe False inSrcs . preview (moduleIdLocation . moduleFile)
	mapMOf_ (each . _1 . projectCabal) (\p -> Log.log Log.Trace ("scanning project: {}" ~~ p)) projSrcs
	runTasks [scanProject opts (view projectCabal p) | (p, _) <- projSrcs, view projectCabal p `notElem` projs]
	mapMOf_ (each . _1 . moduleFile) (\f -> Log.log Log.Trace ("scanning file: {}" ~~ f)) standSrcs
	mapMOf_ (each . _1) (watch . flip watchModule) standSrcs
	scan (Cache.loadFiles inSrcs) (filterDB inFiles (const False) . standaloneDB) standSrcs opts $ scanModules opts
	mapMOf_ each (\s -> Log.log Log.Trace ("scanning package-db: {}" ~~ topPackageDb s)) pdbss
	runTasks [scanPackageDb opts pdbs' | pdbs' <- pdbss, topPackageDb pdbs' `notElem` pdbs]

-- | Scan docs for inspected modules
scanDocs :: UpdateMonad m => [InspectedModule] -> m ()
scanDocs ims = do
	w <- liftIO $ ghcWorker ["-haddock"] (return ())
	runTasks $ map (scanDocs' w) ims
	where
		scanDocs' w im = runTask "scanning docs" (view inspectedId im) $ Log.scope "docs" $ do
			Log.log Log.Trace $ "Scanning docs for {}" ~~  view inspectedId im
			im' <- liftExceptT $ S.scanModify (\opts _ -> inWorkerT w . inspectDocsGhc opts) im
			Log.log Log.Trace $ "Docs for {} updated" ~~ view inspectedId im
			updater $ return $ fromModule im'
		inWorkerT w = ExceptT . inWorker w . runExceptT 

inferModTypes :: UpdateMonad m => [InspectedModule] -> m ()
inferModTypes = runTasks . map inferModTypes' where
	inferModTypes' im = runTask "inferring types" (view inspectedId im) $ Log.scope "docs" $ do
		w <- askSession sessionGhc
		Log.log Log.Trace $ "Inferring types for {}" ~~ view inspectedId im
		im' <- liftExceptT $ S.scanModify (\opts cabal m -> inWorkerT w (inferTypes opts cabal m Nothing)) im
		Log.log Log.Trace $ "Types for {} inferred" ~~ view inspectedId im
		updater $ return $ fromModule im'
	inWorkerT w = ExceptT . inWorker w . runExceptT

-- | Generic scan function. Reads cache only if data is not already loaded, removes obsolete modules and rescans changed modules.
scan :: UpdateMonad m
	=> (FilePath -> ExceptT String IO Structured)
	-- ^ Read data from cache
	-> (Database -> Database)
	-- ^ Get data from database
	-> [S.ModuleToScan]
	-- ^ Actual modules. Other modules will be removed from database
	-> [String]
	-- ^ Extra scan options
	-> ([S.ModuleToScan] -> m ())
	-- ^ Function to update changed modules
	-> m ()
scan cache' part' mlocs opts act = Log.scope "scan" $ do
	dbval <- getCache cache' part'
	let
		obsolete = filterDB (\m -> view moduleIdLocation m `notElem` (mlocs ^.. each . _1)) (const False) dbval
	changed <- liftExceptT $ S.changedModules dbval opts mlocs
	cleaner $ return obsolete
	act changed

updateEvent :: ServerMonadBase m => Watched -> Event -> UpdateM m ()
updateEvent (WatchedProject proj projOpts) e
	| isSource e = do
		Log.log Log.Info $ "File '{file}' in project {proj} changed"
			~~ ("file" %= view eventPath e)
			~~ ("proj" %= view projectName proj)
		dbval <- readDB
		let
			opts = fromMaybe [] $ do
				m <- lookupFile (view eventPath e) dbval
				preview (inspection . inspectionOpts) $ getInspected dbval m
		scanFile opts $ view eventPath e
	| isCabal e = do
		Log.log Log.Info $ "Project {proj} changed"
			~~ ("proj" %= view projectName proj)
		scanProject projOpts $ view projectCabal proj
	| otherwise = return ()
updateEvent (WatchedPackageDb pdbs opts) e
	| isConf e = do
		Log.log Log.Info $ "Package db {package} changed"
			~~ ("package" %= topPackageDb pdbs)
		scanPackageDb opts pdbs
	| otherwise = return ()
updateEvent WatchedModule e
	| isSource e = do
		Log.log Log.Info $ "Module {file} changed"
			~~ ("file" %= view eventPath e)
		dbval <- readDB
		let
			opts = fromMaybe [] $ do
				m <- lookupFile (view eventPath e) dbval
				preview (inspection . inspectionOpts) $ getInspected dbval m
		scanFile opts $ view eventPath e
	| otherwise = return ()

liftExceptT :: CommandMonad m => ExceptT String IO a -> m a
liftExceptT act = liftIO (runExceptT act) >>= either commandError_ return

liftCIO ::CommandMonad m => IO a -> m a
liftCIO = liftExceptT . liftE

processEvent :: UpdateOptions -> Watched -> Event -> ClientM IO ()
processEvent uopts w e = runUpdate uopts $ updateEvent w e

watch :: SessionMonad m => (Watcher -> IO ()) -> m ()
watch f = do
	w <- askSession sessionWatcher
	liftIO $ f w
