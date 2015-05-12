{-# LANGUAGE RankNTypes #-}
module Stackage.PackageIndex.Conduit
    ( sourceTarFile
    , sourceAllCabalFiles
    , parseDistText
    , renderDistText
    , defaultIndexTar
    , CabalFileEntry (..)
    ) where

import Data.Conduit
import Control.Monad.Trans.Resource
import qualified Codec.Archive.Tar                     as Tar
import qualified Data.ByteString.Lazy                  as L
import qualified Data.Text.Lazy as TL
import Data.Text.Lazy.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import           Distribution.Text                     (parse, disp)
import qualified Distribution.Text
import Text.PrettyPrint (render)
import Control.Monad (guard)
import Data.Version (Version)
import qualified Data.Conduit.List as CL
import System.FilePath
import System.Directory
import Control.Monad.IO.Class
import System.IO (hClose, IOMode (ReadMode), openBinaryFile)
import Codec.Compression.GZip (decompress)
import           Distribution.Compat.ReadP             (readP_to_S)
import           Distribution.Package                  (PackageName, PackageIdentifier (..))
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Parse

sourceTarFile :: MonadResource m
              => Bool -- ^ ungzip?
              -> FilePath
              -> Producer m Tar.Entry
sourceTarFile toUngzip fp = do
    bracketP (openBinaryFile fp ReadMode) hClose $ \h -> do
        lbs <- liftIO $ L.hGetContents h
        loop $ Tar.read $ ungzip' lbs
  where
    ungzip'
        | toUngzip = decompress
        | otherwise = id
    loop Tar.Done = return ()
    loop (Tar.Fail e) = throwM e
    loop (Tar.Next e es) = yield e >> loop es

defaultIndexTar :: IO FilePath
defaultIndexTar = do
    cabal <- getAppUserDataDirectory "cabal"
    return $ cabal </> "packages" </> "hackage.haskell.org" </> "00-index.tar"

data CabalFileEntry = CabalFileEntry
    { cfeName :: !PackageName
    , cfeVersion :: !Version
    , cfeRaw :: !L.ByteString
    , cfeParsed :: !(ParseResult GenericPackageDescription)
    }

sourceAllCabalFiles
    :: MonadResource m
    => IO FilePath -- ^ get location of 00-index.tar, probably want 'defaultIndexTar'
    -> Producer m CabalFileEntry
sourceAllCabalFiles getIndexTar = do
    tarball <- liftIO $ getIndexTar
    sourceTarFile False tarball =$= CL.mapMaybe go
  where
    go e =
        case (toPkgVer $ Tar.entryPath e, Tar.entryContent e) of
            (Just (name, version), Tar.NormalFile lbs _) -> Just CabalFileEntry
                { cfeName = name
                , cfeVersion = version
                , cfeRaw = lbs
                , cfeParsed = parsePackageDescription $ TL.unpack $ decodeUtf8With lenientDecode lbs
                }
            _ -> Nothing

    toPkgVer s0 = do
        (name', '/':s1) <- Just $ break (== '/') s0
        (version', '/':s2) <- Just $ break (== '/') s1
        guard $ s2 == (name' ++ ".cabal")
        name <- parseDistText name'
        version <- parseDistText version'
        Just (name, version)

parseDistText :: (Monad m, Distribution.Text.Text t) => String -> m t
parseDistText s =
    case map fst $ filter (null . snd) $ readP_to_S parse s of
        [x] -> return x
        _ -> fail $ "Could not parse: " ++ s

renderDistText :: Distribution.Text.Text t => t -> String
renderDistText = render . disp
