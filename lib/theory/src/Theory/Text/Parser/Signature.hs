{-# LANGUAGE TypeApplications #-}
-- |
-- Copyright   : (c) 2010-2012 Simon Meier, Benedikt Schmidt
--               contributing in 2019: Robert Künnemann, Johannes Wocker
-- License     : GPL v3 (see LICENSE)
--
-- Maintainer  : Simon Meier <iridcode@gmail.com>
-- Portability : portable
--
-- Parsing Signatures
------------------------------------------------------------------------------

module Theory.Text.Parser.Signature (
    heuristic
    , builtins
    , options
    , functions
    , equations
    , liftedAddPredicate
    , preddeclaration
    , goalRanking
    , diffbuiltins
    , export
)
where

import           Prelude                    hiding (id)
import qualified Data.ByteString.Char8      as BC
import           Data.Either
-- import           Data.Monoid                hiding (Last)
import qualified Data.Set                   as S
--import           Data.Char
--import qualified Data.Map                   as M
import           Control.Applicative        hiding (empty, many, optional)
import           Control.Monad
import qualified Control.Monad.Catch        as Catch
import           Text.Parsec                hiding ((<|>))

import           Term.Substitution
import           Term.SubtermRule
import           Term.Builtin.Convenience hiding (sign)
import           Theory
import           Theory.Text.Parser.Token
import Theory.Text.Parser.Fact
import Theory.Text.Parser.Term
import Theory.Text.Parser.Formula
import Theory.Text.Parser.Exceptions

import Data.Label.Total
import Data.Label.Mono (Lens)
import Theory.Sapic
import qualified Data.Functor



 -- Describes the mapping between Maude Signatures and the builtin Name
builtinsDiffNames :: [(String,
                       MaudeSig)]
builtinsDiffNames = [
  ("diffie-hellman", dhMaudeSig),
  ("bilinear-pairing", bpMaudeSig),
  ("multiset", msetMaudeSig),
  ("xor", xorMaudeSig),
  ("symmetric-encryption", symEncMaudeSig),
  ("asymmetric-encryption", asymEncMaudeSig),
  ("signing", signatureMaudeSig),
  ("dest-pairing", pairDestMaudeSig),  
  ("dest-symmetric-encryption", symEncDestMaudeSig),
  ("dest-asymmetric-encryption", asymEncDestMaudeSig),
  ("dest-signing", signatureDestMaudeSig),  
  ("revealing-signing", revealSignatureMaudeSig),
  ("hashing", hashMaudeSig)
              ]

-- | Describes the mapping between a builtin name, its potential Maude Signatures
-- and its potential option
builtinsNames :: [([Char], Maybe MaudeSig, Maybe (Lens Total Option Bool))]
builtinsNames =
  [
  ("locations-report",  Just locationReportMaudeSig, Just transReport),
  ("reliable-channel",  Nothing, Just transReliable)
  ]
  ++ map (\(x,y) -> (x, Just y, Nothing)) builtinsDiffNames

-- | Builtin signatures.
builtins :: OpenTheory -> Parser OpenTheory
builtins thy0 =do
            _  <- symbol "builtins"
            _  <- colon
            l <- commaSep1 builtinTheory -- l is list of lenses to set options to true with
                                         -- builtinTheory modifies signature in state.
            return $ foldl setOption' thy0 l
  where
    setName thy name = modify thyItems (++ [TranslationItem (SignatureBuiltin name)]) thy
    setOption' thy (Nothing, name)  = setName thy name
    setOption' thy (Just l, name) = setOption l (setName thy name)
    extendSig (name, Just msig, opt) = do
        _ <- symbol name
        modifyStateSig (`mappend` msig)
        return (opt, name)
    extendSig (name, Nothing, opt) = do
        _ <- symbol name
        return (opt, name)
    builtinTheory = asum $ map (try . extendSig) builtinsNames

diffbuiltins :: Parser ()
diffbuiltins =
    (symbol "builtins" *> colon *> commaSep1 builtinTheory) Data.Functor.$> ()
  where
    extendSig (name, msig) =
        symbol name *>
        modifyStateSig (`mappend` msig)
    builtinTheory = asum $ map (try . extendSig) builtinsDiffNames


functionType :: Parser ([SapicType], SapicType)
functionType = try (do
                    _  <- opSlash
                    k  <- fromIntegral <$> natural
                    return (replicate k defaultSapicType, defaultSapicType)
                   )
                <|>(do
                    argTypes  <- parens (commaSep typep)
                    _         <- colon
                    outType   <- typep
                    return (argTypes, outType)
                    )

-- | Parse a 'FunctionAttribute'.
functionAttribute :: Parser (Either Privacy Constructability)
functionAttribute = asum
  [ (symbol "private" Data.Functor.$> Left Private)
    <|> (symbol "transparent" Data.Functor.$> Left Transparent)
  , symbol "destructor" Data.Functor.$> Right Destructor
  ]

-- | Add projection destructors and equations for a transparent symbol
transparentLogic :: NoEqSym -> MaudeSig -> Parser ()
transparentLogic fsym sign =
  let (_,(k,_,_)) = fsym
      xs = map (\i -> var "x" i) [1..toInteger k] in
  mapM_ (\k' -> do
    let f = fst fsym
    let fd = BC.pack (BC.unpack f ++ "_proj" ++ show k')
    case lookup f (S.toList $ stFunSyms sign) of
      Just kp' ->
        fail $ "conflicting function symbol " ++
        show kp' ++ " for `" ++ BC.unpack f ++ "`"
      _ -> do
        let fdsym = (fd,(1,Public,Constructor))
        -- let fdsymd = (fd,(1,Public,Destructor))
        modifyStateSig $ addFunSym fdsym
        let rhs = xs !! (k' - 1)
        let rrule = fAppNoEq fdsym [ fAppNoEq fsym xs ] `RRule` rhs
        -- let rruled = fAppNoEq fdsymd [ fAppNoEq fsym xs ] `RRule` rhs
        case rRuleToCtxtStRule rrule of
          Just str -> do
            modifyStateSig $ addCtxtStRule str
              -- modifyStateSig $ addCtxtStRule strd
          _ ->
            fail $ "Not a correct equation: " ++ show rrule)
  [1..k]

function :: Parser SapicFunSym
function =  do
        f   <- BC.pack <$> identifier
        (argTypes,outType) <- functionType
        atts <- option [] $ list functionAttribute
        when (BC.unpack f `elem` reservedBuiltins) $ fail $ "`" ++ BC.unpack f ++ "` is a reserved function name for builtins."
        sign <- sig <$> getState
        let k = length argTypes
        let priv_atts = lefts atts
        let priv = if Private `elem` priv_atts then Private
              else if Transparent `elem` priv_atts then Transparent else Public
        let destr = if Destructor `elem` rights atts then Destructor else Constructor
        let fsym = (f,(k,priv,destr))
        case lookup f (S.toList $ stFunSyms sign) of
          Just kp' | kp' /= snd fsym && BC.unpack f /= "fst" && BC.unpack f /= "snd" ->
            fail $ "conflicting arities/private " ++
                   show kp' ++ " and " ++ show (snd fsym) ++
                   " for `" ++ BC.unpack f
          Just kp' | BC.unpack f == "fst" || BC.unpack f == "snd" -> do
                return ((f,kp'),argTypes,outType)
          _ -> do
                modifyStateSig $ addFunSym fsym
                when (priv == Transparent) $ transparentLogic (f,(k,Public,destr)) sign
                return ((f,(k,priv,destr)),argTypes,outType)


functions :: Parser [SapicFunSym]
functions =
    (try (symbol "functions") <|> symbol "function") *> colon *> commaSep1 function


equations :: Parser ()
equations =
      (symbol "equations" *> colon *> commaSep1 equation) Data.Functor.$> ()
    where
      equation = do
        rrule <- RRule <$> term llitNoPub True <*> (equalSign *> term llitNoPub True)
        case rRuleToCtxtStRule rrule of
          Just str ->
              modifyStateSig (addCtxtStRule str)
          Nothing  ->
              fail $ "Not a correct equation: " ++ show rrule

-- | options
options :: OpenTheory -> Parser OpenTheory
options thy0 =do
            _  <- symbol "options"
            _  <- colon
            l <- commaSep1 builtinTheory -- l is list of lenses to set options to true with
                                         -- builtinTheory modifies signature in state.
            return $ foldl setOption' thy0 l
  where
    setOption' thy Nothing  = thy
    setOption' thy (Just l) = setOption l thy
    builtinTheory = asum
      [  try 
         (symbol "translation-progress") Data.Functor.$> Just transProgress
        , symbol "translation-allow-pattern-lookups" Data.Functor.$> Just transAllowPatternMatchinginLookup
        , symbol "translation-state-optimisation" Data.Functor.$> Just stateChannelOpt
        , symbol "translation-asynchronous-channels" Data.Functor.$> Just asynchronousChannels
        , symbol "translation-compress-events" Data.Functor.$> Just compressEvents
      ]

predicate :: Parser Predicate
predicate = do
           f <- fact' lvar
           _ <- symbol "<=>"
           Predicate f <$> plainFormula
           <?> "predicate declaration"

preddeclaration :: OpenTheory -> Parser OpenTheory
preddeclaration thy = do
                    _          <- try (symbol "predicates" <|> symbol "predicate")
                    _          <- colon
                    predicates <- commaSep1 predicate
                    foldM liftedAddPredicate thy predicates
                    <?> "predicate block"

-- | parse an export declaration
export :: OpenTheory -> Parser OpenTheory
export thy = do
                    _          <- try (symbol "export")
                    tag          <- identifier
                    _          <- colon
                    text       <- doubleQuoted $ many bodyChar -- TODO Gotta use some kind of text.
                    let ei = ExportInfo tag text
                    return (addExportInfo ei thy)
                    <?> "export block"
              where
                bodyChar = try $ do
                  c <- anyChar
                  case c of
                    '\\' -> char '\\' <|> char '"'
                    '"'  -> mzero
                    _    -> return c


heuristic :: Bool -> Maybe FilePath -> Parser [GoalRanking ProofContext]
heuristic diff workDir = symbol "heuristic" *> char ':' *> skipMany (char ' ') *> (concat <$> many1 (goalRanking diff workDir)) <* lexeme spaces

goalRanking :: Bool -> Maybe FilePath -> Parser [GoalRanking ProofContext]
goalRanking diff workDir = try oracleRanking <|> internalTacticRanking <|> regularRanking <?> "goal ranking"
   where
       regularRanking = filterHeuristic diff <$> many1 letter <* skipMany (char ' ')

       internalTacticRanking = do
            _ <- string "{" <* skipMany (char ' ')
            goal <- toGoalRanking <$> pure ("{.}")
            tacticName <- optionMaybe (many1 (noneOf "\"\n\r{}") <* char '}' <* skipMany (char ' '))

            return $ [mapInternalTacticRanking (maybeSetInternalTacticName tacticName) goal]

       oracleRanking = do
           goal <- toGoalRanking <$> (string "o" <|> string "O") <* skipMany (char ' ')
           relPath <- optionMaybe (char '"' *> many1 (noneOf "\"\n\r") <* char '"' <* skipMany (char ' '))

           return $ [mapOracleRanking (maybeSetOracleRelPath relPath . maybeSetOracleWorkDir workDir) goal]

       toGoalRanking = if diff then stringToGoalRankingDiff False else stringToGoalRanking False

liftedAddPredicate :: Catch.MonadThrow m =>
                      Theory sig c r p TranslationElement
                      -> Predicate -> m (Theory sig c r p TranslationElement)
liftedAddPredicate thy prd = liftMaybeToEx (DuplicateItem (PredicateItem prd)) (addPredicate prd thy)
