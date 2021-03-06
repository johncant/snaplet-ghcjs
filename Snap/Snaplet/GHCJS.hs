{-# language OverloadedStrings #-}
{-# language TemplateHaskell #-}

-- | Snaplet that serves javascript files compiled with ghcjs 
--   (<https://github.com/valderman/ghcjs-compiler>). This Snaplet is meant to be
--   used for development. You can work on client side Haskell code and
--   immedietely test the code with a simple browser reload. It certainly adds
--   some overhead and is not meant to be used in production websites.
--
-- Usage:
--
-- Put haskell source files in the snaplet path (e.g. @$ROOT\/snaplets\/ghcjs@).
-- For every such haskell file there will be a new javascript file available via
-- http.
--
-- * Other files won't be served through http. The snaplet will 'mzero' on .hs,
--   .hi, .o and all other files.
--
-- * If any haskell file in the snaplet path is newer than the
--   requested javascript file, it will be recompiled.  The ghcjs
--   snaplet does not track haskell import dependencies: recompilation
--   happens whether the js file is requested or not.
--
-- * If ghcjsc exits with an error code this snaplet will serve a special
--   javascript file that contains the error message as a comment and a
--   javascript command that will raise the error message as a javascript
--   exception.
-- 
-- Please add such a handler to your routes:
--
--   [ ...
--   , ("" , with ghcjs ghcjsServe)
--   ]

module Snap.Snaplet.GHCJS (
    GHCJS,
    snapletArgs,
    initialize,
    ghcjsServe,
  ) where


import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.State.Class as State
import Control.Lens (makeLenses)
import Data.List
import Data.String.Conversions
import Snap.Core
import Snap.Snaplet
import Snap.Util.FileServe
import System.Directory
import System.Exit
import System.FilePath
import System.IO
import System.Process
import Text.Printf



-- | Internal data type for the ghcjs snaplet.
data GHCJS = GHCJS { _ghcjsc :: FilePath
                   , _snapletArgs :: [String]
                   }

makeLenses ''GHCJS

-- | Initializes the ghcjs snaplet. Use it with e.g. 'nestSnaplet'.
initialize :: [String] -> SnapletInit app GHCJS
initialize args = makeSnaplet "ghcjs" description Nothing $ do
    cabalPackageDBs <- liftIO parseCabalPackageDBs
    let packageArgs = cabalPackageDBs >>= (\a -> ["-package-db", a])
    liftIO $ mapM_ putStrLn packageArgs
    return $ GHCJS "ghcjs" (packageArgs ++ args)
  where
    description = "handler for delivering javascript files compiled with ghcjs"

-- The following is a hack. There is code to parse the cabal config properly
-- to find the sandbox, but it is in cabal-install which doesn't export it

-- There may also be a few ways of doing this with cabal, but they would
-- be even worse than the following:
parseCabalPackageDBs :: IO [String]
parseCabalPackageDBs = do
    -- lines not indented are paths
    -- TODO - validate properly
    let isPath s = take 2 s /= ("  "::String) && take 1 s == ("/" :: String)

    dir <- getCurrentDirectory

    writeFile "cabal.snaplet-ghcjs.config" $
      unlines [ "-- Automatically generated by snaplet-ghcjs to help determine location of package db"
              , "compiler: ghcjs"
              , "-- Thankyou."
              , ""]

    (_stdin, Just stdoutH, Just stderrH, processHandle) <-
        createProcess (proc "cabal" ["--config-file=cabal.snaplet-ghcjs.config", "exec", "ghcjs-pkg", "list"]){
            cwd = Just dir,
            std_out = CreatePipe,
            std_err = CreatePipe
          }
    exitCode <- waitForProcess processHandle
    stdout <- hGetContents stdoutH
    stderr <- hGetContents stderrH
    case exitCode of
      -- Delete trailing colon
      ExitSuccess -> return $ map init $ filter isPath $ lines stdout
      ExitFailure _ -> do
        putStrLn "snaplet-ghcjs WARNING: dirty hack failed. Please set -package-db yourself."
        return []


ghcjsServe :: Handler app GHCJS ()
ghcjsServe = do
    jsPath <- cs <$> rqPathInfo <$> getRequest
    ghcjsDir <- getSnapletFilePath
    if takeExtension jsPath /= ".js" then
        mzero
      else
        deliverJS (dropExtension (ghcjsDir </> jsPath))

deliverJS :: FilePath -> Handler app GHCJS ()
deliverJS basename = do
    hsExists   <- liftIO $ doesFileExist (basename <.> "hs")

    unless hsExists mzero

    let jsFile =  jsFileName basename
    snapletDir <- getSnapletFilePath

    jsNewer    <- liftIO $ isJSNewer jsFile snapletDir

    if jsNewer then
            serveFile jsFile
          else
            compile basename

-- | Returns whether the given javascript file exists and is newer than
--   all Haskell files in the given directory.
isJSNewer :: FilePath -> FilePath -> IO Bool
isJSNewer jsFile dir = do
    exists <- liftIO $ doesFileExist jsFile
    if not exists then
        return False
      else do
        hsFiles <- collectAllHsFiles dir
        hsTimeStamps <- mapM getModificationTime hsFiles
        jsTimeStamp <- getModificationTime jsFile
        return (jsTimeStamp > maximum hsTimeStamps)
  where
    collectAllHsFiles :: FilePath -> IO [FilePath]
    collectAllHsFiles dir = do
        paths <- fmap (dir </>) <$>
            filter (not . ("." `isPrefixOf`)) <$>
            getDirectoryContents dir
        (files, dirs) <- partitionM doesFileExist paths
        let hsFiles = filter (\ f -> takeExtension f == ".hs") files
        subHsFiles <- concat <$> mapM collectAllHsFiles dirs
        return (hsFiles ++ subHsFiles)

    partitionM :: Monad m => (a -> m Bool) -> [a] -> m ([a], [a])
    partitionM pred (a : r) = do
        is <- pred a
        (yes, no) <- partitionM pred r
        return $ if is then (a : yes, no) else (yes, a : no)
    partitionM pred [] = return ([], [])

-- | Recompiles the file and serves it in case of success.
compile :: FilePath -> Handler app GHCJS ()
compile name = do
    GHCJS
      ghcjsc
      snapletArgs       <- State.get
    let args            =  snapletArgs ++ [name <.> "hs"]
        outfile         =  jsFileName name
    dir                 <- getSnapletFilePath

    (exitCode, message) <- liftIO $ do
        (_stdin, Just stdoutH, Just stderrH, processHandle) <-
            createProcess (proc ghcjsc args){
                cwd = Just dir,
                std_out = CreatePipe,
                std_err = CreatePipe
              }

        exitCode <- waitForProcess processHandle
        stdout   <- hGetContents stdoutH
        stderr   <- hGetContents stderrH

        return (exitCode, "\nGHCJS error:\n============\n" ++ stdout ++ stderr)

    case exitCode of
        ExitFailure _ ->
            writeBS $ cs (printf ("/*\n\n%s\n\n*/\n\nthrow %s;") message (show message) :: String)

        ExitSuccess -> serveFile outfile

-- At time of writing, there's no way to include js from packages.
-- Just throw everything up onto the frontend without worrying about
-- duplicate code etc.
jsFileName :: String -> FilePath
jsFileName name = name <.> "jsexe" </> "all.js"

