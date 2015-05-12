{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
import Network.HTTP.Client (newManager, withResponse, responseBody, brConsume)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import           ClassyPrelude.Conduit
import qualified Codec.Archive.Tar                     as Tar
import qualified Data.ByteString.Lazy                  as L
import           Data.Semigroup                        (Max (Max))
import           Data.Version                          (Version)
import           Distribution.Compat.ReadP             (readP_to_S)
import           Distribution.Package                  (PackageName, PackageIdentifier (..))
import           Distribution.PackageDescription
import           Distribution.PackageDescription.Parse
import           Distribution.Text                     (parse, disp)
import Text.PrettyPrint (render)
import qualified Distribution.Text
import           System.Directory
import           System.FilePath
import           System.IO                             (IOMode (ReadMode),
                                                        openBinaryFile)
import Data.Yaml
import Data.Aeson
import Stackage.Install
import Codec.Compression.GZip (decompress)
import Crypto.Hash.SHA256 (hashlazy)
import qualified Data.ByteString.Base16 as B16
import Stackage.PackageIndex.Conduit

data PackageInfo = PackageInfo
    { piLatest :: !Version
    , piHash :: !Text
    , piAllVersions :: !(Set Version)
    , piSynopsis :: !Text
    , piDescription :: !Text
    , piDescriptionType :: !Text
    , piChangeLog :: !Text
    , piChangeLogType :: !Text
    }
    deriving (Show, Eq, Typeable, Generic)
instance ToJSON PackageInfo where
    toJSON pi = object
        [ "latest" .= renderDistText (piLatest pi)
        , "hash" .= piHash pi
        , "all-versions" .= map renderDistText (setToList $ piAllVersions pi)
        , "synopsis" .= piSynopsis pi
        , "description" .= piDescription pi
        , "description-type" .= piDescriptionType pi
        , "changelog" .= piChangeLog pi
        , "changelog-type" .= piChangeLogType pi
        ]
instance FromJSON PackageInfo where
    parseJSON = withObject "PackageInfo" $ \o -> PackageInfo
        <$> (o .: "latest" >>= parseDistText)
        <*> o .: "hash"
        <*> (o .: "all-versions" >>= fmap setFromList . mapM parseDistText)
        <*> o .: "synopsis"
        <*> o .: "description"
        <*> o .: "description-type"
        <*> o .: "changelog"
        <*> o .: "changelog-type"

newtype SemiMap k v = SemiMap (Map k v)
instance (Ord k, Semigroup v) => Monoid (SemiMap k v) where
    mempty = SemiMap mempty
    mappend (SemiMap x) (SemiMap y) = SemiMap $ unionWith (<>) x y

data Deprecation = Deprecation
    { depPackage :: !Text
    , depInFavourOf :: !(Set Text)
    }
instance ToJSON Deprecation where
    toJSON d = object
        [ "deprecated-package" .= depPackage d
        , "in-favour-of" .= depInFavourOf d
        ]
instance FromJSON Deprecation where
    parseJSON = withObject "Deprecation" $ \o -> Deprecation
        <$> o .: "deprecated-package"
        <*> o .: "in-favour-of"

main :: IO ()
main = do
    man <- newManager tlsManagerSettings
    bss <- withResponse "https://hackage.haskell.org/packages/deprecated.json" man
        $ \res -> brConsume $ responseBody res
    deps <- either throwIO return $ decodeEither' $ concat bss
    encodeFile "deprecated.yaml" (deps :: [Deprecation])

    SemiMap newest <- runResourceT $ sourceAllCabalFiles defaultIndexTar $$ foldMapC
        (\cfe -> SemiMap $ singletonMap
            (cfeName cfe)
            (Max $ cfeVersion cfe, singletonSet $ cfeVersion cfe))
    runResourceT $ sourceAllCabalFiles defaultIndexTar $$ mapM_C (updatePIM newest)

updatePIM :: MonadResource m
          => Map PackageName (Max Version, Set Version)
          -> CabalFileEntry
          -> m ()
updatePIM newest cfe
    | latest == version = do
        epi <- liftIO $ decodeFileEither fp
        case epi of
            Left _ -> load >>= save
            Right pi
                | version == piLatest pi && thehash == piHash pi -> return ()
                | otherwise -> load >>= save
    | otherwise = return ()
  where
    name = cfeName cfe
    version = cfeVersion cfe
    lbs = cfeRaw cfe
    mgpd = cfeParsed cfe

    Just (Max latest, allVersions) = lookup name newest

    fp = "packages" </> (take 2 $ name' ++ "XX") </> name' <.> "yaml"
    name' = renderDistText name

    load = do
        putStrLn $ "Loading " ++ tshow (name, version)
        loadPI name version allVersions thehash mgpd

    save pi = liftIO $ do
        createDirectoryIfMissing True $ takeDirectory fp
        encodeFile fp pi

    thehash = decodeUtf8 $ B16.encode $ hashlazy lbs

loadPI :: MonadResource m
       => PackageName
       -> Version
       -> Set Version
       -> Text -- ^ the hash
       -> ParseResult GenericPackageDescription
       -> m PackageInfo
loadPI name version _ _ (ParseFailed pe) = error $ show (name, version, pe)
loadPI name version allVersions thehash (ParseOk _ gpd) = do
    when (package pd /= PackageIdentifier name version) $
        error $ show ("mismatch", name, version, package pd)

    -- FIXME stackage-install: allow precomputed manager, and return path info
    let name' = renderDistText name
        version' = renderDistText version
    liftIO $ download defaultSettings [(name', version')]
    cabal <- liftIO $ getAppUserDataDirectory "cabal"
    let tarball = cabal
              </> "packages"
              </> "hackage.haskell.org"
              </> name'
              </> version'
              </> concat [name', "-", version', ".tar.gz"]

    (desc, desct, cl, clt) <-
        sourceTarFile True tarball $$ foldlC goEntry
            (pack $ description pd, "haddock", "", "")

    return PackageInfo
        { piLatest = version
        , piHash = thehash
        , piAllVersions = allVersions
        , piSynopsis = pack $ synopsis pd
        , piDescription = desc
        , piDescriptionType = desct
        , piChangeLog = cl
        , piChangeLogType = clt
        }
  where
    pd = packageDescription gpd

    goEntry :: (Text, Text, Text, Text) -> Tar.Entry -> (Text, Text, Text, Text)
    goEntry orig@(desc, desct, cl, clt) e =
        case (toEntryType $ Tar.entryPath e, toText $ Tar.entryContent e) of
            (ChangeLog clt', Just cl') -> (desc, desct, cl', clt')
            (Desc desct', Just desc') -> (desc', desct', cl, clt)
            _ -> orig

    toText (Tar.NormalFile lbs _) = Just $ decodeUtf8 $ toStrict lbs
    toText _ = Nothing

data EntryType = Ignored | ChangeLog Text | Desc Text

toEntryType :: FilePath -> EntryType
toEntryType fp
    | name == "changelog" = ChangeLog t
    | name == "readme" = Desc t
    | otherwise = Ignored
  where
    (name', ext) = splitExtension fp
    name = toLower name'
    t =
        case ext of
            ".md" -> "markdown"
            _ -> "text"
