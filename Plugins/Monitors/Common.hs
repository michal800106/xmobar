-----------------------------------------------------------------------------
-- |
-- Module      :  Plugins.Monitors.Common
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
--
-- Maintainer  :  Andrea Rossato <andrea.rossato@unibz.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- Utilities for creating monitors for Xmobar
--
-----------------------------------------------------------------------------

module Plugins.Monitors.Common (
                       -- * Monitors
                       -- $monitor
                         Monitor
                       , MConfig (..)
                       , Opts (..)
                       , setConfigValue
                       , getConfigValue
                       , mkMConfig
                       , runM
                       , io
                       -- * Parsers
                       -- $parsers
                       , runP
                       , skipRestOfLine
                       , getNumbers
                       , getNumbersAsString
                       , getAllBut
                       , getAfterString
                       , skipTillString
                       , parseTemplate
                       -- ** String Manipulation
                       -- $strings
                       , showWithColors
                       , showPercentsWithColors
                       , takeDigits
                       , showDigits
                       , floatToPercent
                       , stringParser
                       -- * Threaded Actions
                       -- $thread
                       , doActionTwiceWithDelay
                       , catRead
                       ) where


import Control.Concurrent
import Control.Monad.Reader
import Control.Monad (zipWithM)
import qualified Data.ByteString.Lazy.Char8 as B
import Data.IORef
import qualified Data.Map as Map
import Data.List
import Numeric
import Text.ParserCombinators.Parsec
import System.Console.GetOpt
import Control.Exception (SomeException,handle)
import System.Process (readProcess)

import Plugins
-- $monitor

type Monitor a = ReaderT MConfig IO a

data MConfig =
    MC { normalColor :: IORef (Maybe String)
       , low         :: IORef Int
       , lowColor    :: IORef (Maybe String)
       , high        :: IORef Int
       , highColor   :: IORef (Maybe String)
       , template    :: IORef String
       , export      :: IORef [String]
       , ppad        :: IORef Int
       , minWidth    :: IORef Int
       , maxWidth    :: IORef Int
       , padChars    :: IORef [Char]
       , padRight    :: IORef Bool
       }

-- | from 'http:\/\/www.haskell.org\/hawiki\/MonadState'
type Selector a = MConfig -> IORef a

sel :: Selector a -> Monitor a
sel s =
    do hs <- ask
       liftIO $ readIORef (s hs)

mods :: Selector a -> (a -> a) -> Monitor ()
mods s m =
    do v <- ask
       io $ modifyIORef (s v) m

setConfigValue :: a -> Selector a -> Monitor ()
setConfigValue v s =
       mods s (\_ -> v)

getConfigValue :: Selector a -> Monitor a
getConfigValue s =
    sel s

mkMConfig :: String
          -> [String]
          -> IO MConfig
mkMConfig tmpl exprts =
    do lc <- newIORef Nothing
       l  <- newIORef 33
       nc <- newIORef Nothing
       h  <- newIORef 66
       hc <- newIORef Nothing
       t  <- newIORef tmpl
       e  <- newIORef exprts
       p  <- newIORef 0
       mn <- newIORef 0
       mx <- newIORef 0
       pc <- newIORef " "
       pr <- newIORef False
       return $ MC nc l lc h hc t e p mn mx pc pr

data Opts = HighColor String
          | NormalColor String
          | LowColor String
          | Low String
          | High String
          | Template String
          | PercentPad String
          | MinWidth String
          | MaxWidth String
          | PadChars String
          | PadAlign String

options :: [OptDescr Opts]
options =
    [ Option ['H']  ["High"]     (ReqArg High "number"              )   "The high threshold"
    , Option ['L']  ["Low"]      (ReqArg Low "number"               )   "The low threshold"
    , Option ['h']  ["high"]     (ReqArg HighColor "color number"   )   "Color for the high threshold: ex \"#FF0000\""
    , Option ['n']  ["normal"]   (ReqArg NormalColor "color number" )   "Color for the normal threshold: ex \"#00FF00\""
    , Option ['l']  ["low"]      (ReqArg LowColor "color number"    )   "Color for the low threshold: ex \"#0000FF\""
    , Option ['t']  ["template"] (ReqArg Template "output template" )   "Output template."
    , Option ['p']  ["ppad"]     (ReqArg PercentPad "percent padding" ) "Minimum percentage width."
    , Option ['m']  ["minwidth"] (ReqArg MinWidth "minimum width")      "Minimum field width"
    , Option ['M']  ["maxwidth"] (ReqArg MaxWidth "maximum width")      "Maximum field width"
    , Option ['c']  ["padchars"] (ReqArg PadChars "padding chars")      "Characters to use for padding"
    , Option ['a']  ["align"]    (ReqArg PadAlign "padding alignment")  "'l' for left padding, 'r' for right"
    ]

doArgs :: [String]
       -> ([String] -> Monitor String)
       -> Monitor String
doArgs args action =
    do case (getOpt Permute options args) of
         (o, n, []  ) -> do doConfigOptions o
                            action n
         (_, _, errs) -> return (concat errs)

doConfigOptions :: [Opts] -> Monitor ()
doConfigOptions [] = io $ return ()
doConfigOptions (o:oo) =
    do let next = doConfigOptions oo
           nz s = let x = read s in max 0 x
       case o of
         High         h -> setConfigValue (read h) high >> next
         Low          l -> setConfigValue (read l) low >> next
         HighColor   hc -> setConfigValue (Just hc) highColor >> next
         NormalColor nc -> setConfigValue (Just nc) normalColor >> next
         LowColor    lc -> setConfigValue (Just lc) lowColor >> next
         Template     t -> setConfigValue t template >> next
         PercentPad   p -> setConfigValue (nz p) ppad >> next
         MinWidth    mn -> setConfigValue (nz mn) minWidth >> next
         MaxWidth    mx -> setConfigValue (nz mx) maxWidth >> next
         PadChars    pc -> setConfigValue pc padChars >> next
         PadAlign    pa -> setConfigValue (isPrefixOf "r" pa) padRight >> next

runM :: [String] -> IO MConfig -> ([String] -> Monitor String) -> Int -> (String -> IO ()) -> IO ()
runM args conf action r cb = do go
    where go = do
            c <- conf
            let ac = doArgs args action
                he = return . (++) "error: " . show . flip asTypeOf (undefined::SomeException)
            s <- handle he $ runReaderT ac c
            cb s
            tenthSeconds r
            go

io :: IO a -> Monitor a
io = liftIO



-- $parsers

runP :: Parser [a] -> String -> IO [a]
runP p i =
    do case (parse p "" i) of
         Left _ -> return []
         Right x  -> return x

getAllBut :: String -> Parser String
getAllBut s =
    manyTill (noneOf s) (char $ head s)

getNumbers :: Parser Float
getNumbers = skipMany space >> many1 digit >>= \n -> return $ read n

getNumbersAsString :: Parser String
getNumbersAsString = skipMany space >> many1 digit >>= \n -> return n

skipRestOfLine :: Parser Char
skipRestOfLine =
    do many $ noneOf "\n\r"
       newline

getAfterString :: String -> Parser String
getAfterString s =
    do { try $ manyTill skipRestOfLine $ string s
       ; v <- manyTill anyChar $ newline
       ; return v
       } <|> return ("<" ++ s ++ " not found!>")

skipTillString :: String -> Parser String
skipTillString s =
    manyTill skipRestOfLine $ string s

-- | Parses the output template string
templateStringParser :: Parser (String,String,String)
templateStringParser =
    do { s <- nonPlaceHolder
       ; com <- templateCommandParser
       ; ss <- nonPlaceHolder
       ; return (s, com, ss)
       }
    where
      nonPlaceHolder = liftM concat . many $
                       (many1 $ noneOf "<") <|> colorSpec

-- | Recognizes color specification and returns it unchanged
colorSpec :: Parser String
colorSpec = (try $ string "</fc>") <|> try (
            do string "<fc="
               s <- many1 (alphaNum <|> char ',' <|> char '#')
               char '>'
               return $ "<fc=" ++ s ++ ">")

-- | Parses the command part of the template string
templateCommandParser :: Parser String
templateCommandParser =
    do { char '<'
       ; com <- many $ noneOf ">"
       ; char '>'
       ; return com
       }

-- | Combines the template parsers
templateParser :: Parser [(String,String,String)]
templateParser = many templateStringParser --"%")

-- | Takes a list of strings that represent the values of the exported
-- keys. The strings are joined with the exported keys to form a map
-- to be combined with 'combine' to the parsed template. Returns the
-- final output of the monitor.
parseTemplate :: [String] -> Monitor String
parseTemplate l =
    do t <- getConfigValue template
       s <- io $ runP templateParser t
       e <- getConfigValue export
       let m = Map.fromList . zip e $ l
       return $ combine m s

-- | Given a finite "Map" and a parsed templatet produces the
-- | resulting output string.
combine :: Map.Map String String -> [(String, String, String)] -> String
combine _ [] = []
combine m ((s,ts,ss):xs) =
    s ++ str ++ ss ++ combine m xs
        where str = Map.findWithDefault err ts m
              err = "<" ++ ts ++ " not found!>"

-- $strings

type Pos = (Int, Int)

takeDigits :: Int -> Float -> Float
takeDigits d n =
    fromIntegral ((round (n * fact)) :: Int) / fact
  where fact = 10 ^ d

showDigits :: Int -> Float -> String
showDigits d n =
    showFFloat (Just d) n ""

padString :: Int -> Int -> String -> Bool -> String -> String
padString mnw mxw pad pr s =
  let len = length s
      rmin = if mnw == 0 then 1 else mnw
      rmax = if mxw == 0 then max len rmin else mxw
      (rmn, rmx) = if rmin <= rmax then (rmin, rmax) else (rmax, rmin)
      rlen = min (max rmn len) rmx
  in if rlen < len then
       take rlen s
     else let ps = take (rlen - len) (cycle pad)
          in if pr then s ++ ps else ps ++ s

floatToPercent :: Float -> Monitor String
floatToPercent n =
  do pad <- getConfigValue ppad
     pc <- getConfigValue padChars
     pr <- getConfigValue padRight
     let p = showDigits 0 (n * 100)
     return $ padString pad pad pc pr p ++ "%"

stringParser :: Pos -> B.ByteString -> String
stringParser (x,y) =
     B.unpack . li x . B.words . li y . B.lines
    where li i l | length l > i = l !! i
                 | otherwise    = B.empty

setColor :: String -> Selector (Maybe String) -> Monitor String
setColor str s =
    do a <- getConfigValue s
       case a of
            Nothing -> return str
            Just c -> return $
                "<fc=" ++ c ++ ">" ++ str ++ "</fc>"

showWithColors :: (Num a, Ord a) => (a -> String) -> a -> Monitor String
showWithColors f x =
    do h <- getConfigValue high
       l <- getConfigValue low
       mn <- getConfigValue minWidth
       mx <- getConfigValue maxWidth
       p <- getConfigValue padChars
       pr <- getConfigValue padRight
       let col = setColor $ padString mn mx p pr $ f x
           [ll,hh] = map fromIntegral $ sort [l, h] -- consider high < low
       head $ [col highColor   | x > hh ] ++
              [col normalColor | x > ll ] ++
              [col lowColor    | True]

showPercentsWithColors :: [Float] -> Monitor [String]
showPercentsWithColors fs =
  do fstrs <- mapM floatToPercent fs
     zipWithM (showWithColors . const) fstrs (map (*100) fs)

-- $threads

doActionTwiceWithDelay :: Int -> IO [a] -> IO ([a], [a])
doActionTwiceWithDelay delay action =
    do v1 <- newMVar []
       forkIO $! getData action v1 0
       v2 <- newMVar []
       forkIO $! getData action v2 delay
       threadDelay (delay `div` 3 * 4)
       a <- readMVar v1
       b <- readMVar v2
       return (a,b)

getData :: IO a -> MVar a -> Int -> IO ()
getData action var d =
    do threadDelay d
       s <- action
       modifyMVar_ var (\_ -> return $! s)

catRead :: FilePath -> IO B.ByteString
catRead file = B.pack `fmap` readProcess "/bin/cat" [file] ""
