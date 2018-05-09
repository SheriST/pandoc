{-
  Copyright (C) 2018 Yan Pashkovsky <yanp.bugz@gmail.com>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA



-}

{- |
   Module      : Text.Pandoc.Readers.Man
   Copyright   : Copyright (C) 2018 Yan Pashkovsky
   License     : GNU GPL, version 2 or above

   Maintainer  : Yan Pashkovsky <yanp.bugz@gmail.com>
   Stability   : WIP
   Portability : portable

Conversion of man to 'Pandoc' document.
-}
module Text.Pandoc.Readers.Man where

import Control.Monad.Except (throwError)
import Data.Default (Default)
import Data.Map (insert)
import Data.Maybe (isJust)
import Data.List (intersperse, intercalate)
import qualified Data.Text as T

import Text.Pandoc.Class (PandocMonad(..), runPure)
import Text.Pandoc.Definition
import Text.Pandoc.Error (PandocError)
import Text.Pandoc.Logging (LogMessage(..))
import Text.Pandoc.Options
import Text.Pandoc.Parsing hiding (enclosed)
import Text.Pandoc.Shared (crFilter)
import Text.Parsec
import Text.Parsec.Char ()

data FontKind = Regular | Italic | Bold | ItalicBold deriving Show

data RoffState = RoffState { inCodeBlock :: Bool
                           , fontKind :: FontKind
                           } deriving Show

instance Default RoffState where
  def = RoffState {inCodeBlock = False, fontKind = Regular}

data ManState = ManState {pState :: ParserState, rState :: RoffState}

instance HasLogMessages ManState where
  addLogMessage lm mst  = mst {pState = addLogMessage lm (pState mst)}
  getLogMessages mst = getLogMessages $ pState mst

modifyRoffState :: PandocMonad m => (RoffState -> RoffState) -> ParsecT a ManState m ()
modifyRoffState f = do
  mst <- getState
  setState mst { rState = f $ rState mst }

type ManParser m = ParserT [Char] ManState m

testStrr :: [Char] -> SourceName -> Either PandocError (Either ParseError Pandoc)
testStrr s srcnm = runPure (runParserT parseMan (ManState {pState=def, rState=def}) srcnm s)

printPandoc :: Pandoc -> [Char]
printPandoc (Pandoc m content) =
  let ttl = "Pandoc: " ++ (show $ unMeta m)
      cnt = intercalate "\n" $ map show content
  in ttl ++ "\n" ++ cnt

strrepr :: (Show a2, Show a1) => Either a2 (Either a1 Pandoc) -> [Char]
strrepr obj = case obj of
  Right x -> case x of
    Right x' -> printPandoc x'
    Left y' -> show y'
  Left y -> show y

testFile :: FilePath -> IO ()
testFile fname = do
  cont <- readFile fname
  putStrLn . strrepr $ testStrr cont fname


-- | Read man (troff) from an input string and return a Pandoc document.
readMan :: PandocMonad m => ReaderOptions -> T.Text -> m Pandoc
readMan opts txt = do
  let state = ManState { pState = def{ stateOptions = opts }, rState = def}
  parsed <- readWithM parseMan state (T.unpack $ crFilter txt)
  case parsed of
    Right result -> return result
    Left e       -> throwError e

parseMacro :: PandocMonad m => ManParser m Block
parseMacro = do
  char '.' <|> char '\''
  many space
  macroName <- many1 (letter <|> oneOf ['\\', '"'])
  args <- parseArgs
  let joinedArgs = concat $ intersperse " " args
  case macroName of
    "\\\"" -> return Null -- comment
    "TH"   -> macroTitle (if null args then "" else head args)
    "nf"   -> macroCodeBlock True >> return Null
    "fi"   -> macroCodeBlock False >> return Null
    "B"    -> return $ Plain [Strong [Str joinedArgs]]
    "BR"   -> return $ Plain [Strong [Str joinedArgs]]
    "BI"   -> return $ Plain [Strong [Emph [Str joinedArgs]]]
    "I"    -> return $ Plain [Emph   [Str joinedArgs]]
    "SH"   -> return $ Header 2 nullAttr [Str joinedArgs]
    "sp"   -> return $ Plain [LineBreak]
    _      -> unkownMacro macroName args

  where

  macroTitle :: PandocMonad m => String -> ManParser m Block
  macroTitle mantitle = do
    modifyState (changeTitle mantitle)
    if null mantitle
      then return Null
      else return $ Header 1 nullAttr [Str mantitle]
    where
    changeTitle title mst @ ManState{ pState = pst} =
      let meta = stateMeta pst
          metaUp = Meta $ insert "title" (MetaString title) (unMeta meta)
      in
      mst { pState = pst {stateMeta = metaUp} }


  macroCodeBlock :: PandocMonad m => Bool -> ManParser m ()
  macroCodeBlock insideCB = modifyRoffState (\rst -> rst{inCodeBlock = insideCB}) >> return ()
    
  unkownMacro :: PandocMonad m => String -> [String] -> ManParser m Block
  unkownMacro mname args = do
    pos <- getPosition
    logMessage $ SkippedContent ("Unknown macro: " ++ mname) pos
    return $ Plain $ Str <$> args
   
  parseArgs :: PandocMonad m => ManParser m [String]
  parseArgs = do
    eolOpt <- optionMaybe $ char '\n'
    if isJust eolOpt
      then return []
      else do
        many1 space
        arg <- try quotedArg <|> plainArg
        otherargs <- parseArgs
        return $ arg : otherargs

    where

    plainArg :: PandocMonad m => ManParser m String
    plainArg = many1 $ noneOf " \t\n"

    quotedArg :: PandocMonad m => ManParser m String
    quotedArg = do
      char '"'
      val <- many1 quotedChar
      char '"'
      return val

    quotedChar :: PandocMonad m => ManParser m Char
    quotedChar = noneOf "\"\n" <|> try (string "\"\"" >> return '"')

roffInline :: RoffState -> String -> (Maybe Inline)
roffInline rst str
  | null str        = Nothing
  | inCodeBlock rst = Just $ Code nullAttr str
  | otherwise       = Just $ case fontKind rst of
    Regular -> Str str
    Italic  -> Emph [Str str]
    _       -> Strong [Str str]

parseLine :: PandocMonad m => ManParser m Block
parseLine = do
  parts <- parseLineParts
  newline
  return $ if null parts
    then Plain [LineBreak]
    else Plain parts
  where
    parseLineParts :: PandocMonad m => ManParser m [Inline]
    parseLineParts = do
      lnpart <- many $ noneOf "\n\\"
      ManState {rState = roffSt} <- getState
      let inl = roffInline roffSt lnpart
      others <- backSlash <|> return []
      return $ case inl of
        Just x  -> x:others
        Nothing -> others
    
    backSlash :: PandocMonad m => ManParser m [Inline]
    backSlash = do
      char '\\'
      esc <- choice [ char 'f' >> fEscape
                    , char '-' >> return (Just '-')
                    , Just <$> noneOf "\n"
                    ]
      ManState {rState = roffSt} <- getState
      case esc of
        Just c -> case roffInline roffSt [c] of
          Just inl -> do
            oth <- parseLineParts
            return $ inl : oth
          Nothing -> parseLineParts
        Nothing -> parseLineParts
      where
      
      fEscape :: PandocMonad m => ManParser m (Maybe Char)
      fEscape = choice [ char 'B' >> modifyRoffState (\rst -> rst {fontKind = Bold})
                       , char 'I' >> modifyRoffState (\rst -> rst {fontKind = Italic})
                       , char 'P' >> modifyRoffState (\rst -> rst {fontKind = Regular})
                       ]
                >> return Nothing
      
      

parseMan :: PandocMonad m => ManParser m Pandoc
parseMan = do
  blocks <- many (parseMacro <|> parseLine)
  parserst <- pState <$> getState
  return $ Pandoc (stateMeta parserst) blocks
