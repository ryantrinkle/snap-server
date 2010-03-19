{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Internal.Http.Parser.Tests
  ( tests ) where

import qualified Control.Exception as E
import           Control.Exception hiding (try)
import           Control.Monad
import           Control.Monad.Identity
import           Control.Parallel.Strategies
import qualified Data.Attoparsec as Atto
import           Data.Attoparsec hiding (Result(..))
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import           Data.ByteString.Internal (c2w, w2c)
import           Data.Maybe (fromJust)
import           Data.Time.Clock
import           Data.Time.Format
import           System.Locale
import           Test.Framework 
import           Test.Framework.Providers.HUnit
import           Test.Framework.Providers.QuickCheck2
import           Test.HUnit hiding (Test, path)
import           Text.Printf

import           Snap.Internal.Http.Parser
import           Snap.Internal.Http.Types hiding (Enumerator)
import           Snap.Iteratee
import           Snap.Test.Common()


tests :: [Test]
tests = [ testShow
        , testCookie
        , testChunked
        , testBothChunked
        , testP2I
        , testNull
        , testPartial
        , testIterateeError
        , testIterateeError2
        , testParseError ]


emptyParser :: Parser ByteString
emptyParser = option "foo" $ string "bar"

testShow :: Test
testShow = testCase "show" $ do
    let i = IRequest GET "/" (1,1) []
    let !b = show i `using` rdeepseq
    return $ b `seq` ()


testP2I :: Test
testP2I = testCase "parserToIteratee" $ do
    i <- enumBS "z" (parserToIteratee emptyParser)
    l <- run i

    assertEqual "should be foo" "foo" l

forceErr :: SomeException -> IO ()
forceErr e = f `seq` (return ())
  where
    !f = show e

testNull :: Test
testNull = testCase "short parse" $ do
    f <- E.try $ run (parseRequest)

    case f of (Left e)  -> forceErr e
              (Right x) -> assertFailure $ "expected exception, got " ++ show x

testPartial :: Test
testPartial = testCase "partial parse" $ do
    i <- enumBS "GET / " parseRequest
    f <- E.try $ run i

    case f of (Left e)  -> forceErr e
              (Right x) -> assertFailure $ "expected exception, got " ++ show x


testParseError :: Test
testParseError = testCase "parse error" $ do
    i <- enumBS "ZZZZZZZZZZ" parseRequest
    f <- E.try $ run i

    case f of (Left e)  -> forceErr e
              (Right x) -> assertFailure $ "expected exception, got " ++ show x


introduceError :: (Monad m) => Enumerator m a
introduceError iter = return $ IterateeG $ \_ ->
                          runIter iter (EOF (Just (Err "EOF")))

testIterateeError :: Test
testIterateeError = testCase "iteratee error" $ do
    i <- liftM liftI $ runIter parseRequest (EOF (Just (Err "foo")))
    f <- E.try $ run i

    case f of (Left e)  -> forceErr e
              (Right x) -> assertFailure $ "expected exception, got " ++ show x

testIterateeError2 :: Test
testIterateeError2 = testCase "iteratee error 2" $ do
    i <- (enumBS "GET / " >. introduceError) parseRequest
    f <- E.try $ run i

    case f of (Left e)  -> forceErr e
              (Right x) -> assertFailure $ "expected exception, got " ++ show x


-- | convert a bytestring to chunked transfer encoding
transferEncodingChunked :: L.ByteString -> L.ByteString
transferEncodingChunked = f . L.toChunks
  where
    toChunk s = L.concat [ len, "\r\n", L.fromChunks [s], "\r\n" ]
      where
        len = L.pack $ map c2w $ printf "%x" $ S.length s

    f l = L.concat $ (map toChunk l ++ ["0\r\n\r\n"])

-- | ensure that running the 'readChunkedTransferEncoding' iteratee against
-- 'transferEncodingChunked' returns the original string
testChunked :: Test
testChunked = testProperty "chunked transfer encoding" prop_chunked
  where
    prop_chunked :: L.ByteString -> Bool
    prop_chunked s = runIdentity (run iter) == s
      where
        enum = enumLBS (transferEncodingChunked s)

        iter :: Iteratee Identity L.ByteString
        iter = runIdentity $ do
                   i <- (readChunkedTransferEncoding stream2stream) >>= enum 
                   return $ liftM fromWrap i

testBothChunked :: Test
testBothChunked = testProperty "chunk . unchunk == id" prop
  where
    prop :: L.ByteString -> Bool
    prop s = runIdentity (run iter) == s
      where
        bs = runIdentity $
                 (writeChunkedTransferEncoding
                    (enumLBS s) stream2stream) >>=
                 run >>=
                 return . fromWrap

        enum = enumLBS bs

        iter = runIdentity $ do
                   i <- (readChunkedTransferEncoding stream2stream) >>= enum 
                   return $ liftM fromWrap i



testCookie :: Test
testCookie =
    testCase "parseCookie" $ do
        assertEqual "cookie parsing" (Just cv) cv2

  where
    cv  = Cookie nm v (Just d) (Just domain) (Just path)
    cv2 = parseCookie ct


    d = (fromJust $
         parseTime defaultTimeLocale "%a, %d-%b-%Y %H:%M:%S %Z" dts) :: UTCTime

    dt     = "Fri, 22-Jan-2010 12:34:56 GMT"
    dts    = map w2c $ S.unpack dt
    nm     = "foo"
    v      = "bar"
    domain = ".foo.com"
    path   = "/zzz"

    ct = S.concat [ nm
                  , "="
                  , v
                  , "; expires="
                  , dt
                  , "; domain="
                  , domain
                  , "; path=/zzz; freeform=unparsed" ]


