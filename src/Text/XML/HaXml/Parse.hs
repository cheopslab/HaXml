-- | A non-validating XML parser.  For the input grammar, see
--   <http://www.w3.org/TR/REC-xml>.
module Text.XML.HaXml.Parse
  (
  -- * Parse a whole document
    xmlParse, xmlParse'
  -- * Parse just a DTD
  , dtdParse, dtdParse'
  -- * These functions are exported because they are needed by the SAX parser
  , emptySTs, XParser
  , elemtag, name, tok
  , comment, chardata
  , reference, doctypedecl
  , processinginstruction
  -- * This general utility functions don't belong here
  , fst3, snd3, thd3
  ) where

-- An XML parser, written using a slightly extended version of the
-- Hutton/Meijer parser combinators.  The input is tokenised internally
-- by the lexer xmlLex.  Whilst parsing, we gather a symbol
-- table of entity references.  PERefs must be defined before use, so we
-- expand their uses as we encounter them, forcing the remainder of the
-- input to be re-lexed and re-parsed.  GERefs are simply stored for
-- later retrieval.

import Prelude hiding (either,maybe,sequence)
import qualified Prelude (either)
import Maybe hiding (maybe)
import List (intersperse)       -- debugging only
import Char (isSpace,isDigit,isHexDigit)
import Monad hiding (sequence)
import Numeric (readDec,readHex)

import Text.XML.HaXml.Types
import Text.XML.HaXml.Posn
import Text.XML.HaXml.Lex
import Text.ParserCombinators.Poly


#if defined(__GLASGOW_HASKELL__) && ( __GLASGOW_HASKELL__ > 502 )
import System.IO.Unsafe (unsafePerformIO)
#elif defined(__GLASGOW_HASKELL__) || defined(__HUGS__)
import IOExts (unsafePerformIO)
#elif defined(__NHC__) && ( __NHC__ > 114 )
import System.IO.Unsafe (unsafePerformIO)
#elif defined(__NHC__)
import IOExtras (unsafePerformIO)
#elif defined(__HBC__)
import UnsafePerformIO
#endif

--  #define DEBUG

#if defined(DEBUG)
#  if ( defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ > 502 ) || \
      ( defined(__NHC__) && __NHC__ > 114 )
import Debug.Trace(trace)
#  elif defined(__GLASGOW_HASKELL__) || defined(__HUGS__)
import IOExts(trace)
#  elif defined(__NHC__) || defined(__HBC__)
import NonStdTrace
#  endif
debug :: a -> String -> a
v `debug` s = trace s v
#else
v `debug` s = v
#endif


-- | To parse a whole document, @xmlParse file content@ takes a filename
--   (for generating error reports) and the string content of that file.
--   A parse error causes program failure, with message to stderr.
xmlParse :: String -> String -> Document Posn

-- | To parse a whole document, @xmlParse' file content@ takes a filename
--   (for generating error reports) and the string content of that file.
--   Any parse error message is passed back to the caller through the
--   @Either@ type.
xmlParse' :: String -> String -> Either String (Document Posn)

-- | To parse just a DTD, @dtdParse file content@ takes a filename
--   (for generating error reports) and the string content of that
--   file.  If no DTD was found, you get @Nothing@ rather than an error.
--   However, if a DTD is found but contains errors, the program crashes.
dtdParse  :: String -> String -> Maybe DocTypeDecl

-- | To parse just a DTD, @dtdParse' file content@ takes a filename
--   (for generating error reports) and the string content of that
--   file.  If no DTD was found, you get @Right Nothing@.
--   If a DTD was found but contains errors, you get a @Left message@.
dtdParse' :: String -> String -> Either String (Maybe DocTypeDecl)

xmlParse  name  = Prelude.either error id . xmlParse' name
dtdParse  name  = Prelude.either error id . dtdParse' name

xmlParse' name  = fst3 . runParser (toEOF document) emptySTs . xmlLex name
dtdParse' name  = fst3 . runParser justDTD  emptySTs . xmlLex name

toEOF = id

---- Symbol table stuff ----

type SymTabs = (SymTab PEDef, SymTab EntityDef)

emptySTs :: SymTabs
emptySTs = (emptyST, emptyST)

addPE :: String -> PEDef -> SymTabs -> SymTabs
addPE n v (pe,ge) = (addST n v pe, ge)

addGE :: String -> EntityDef -> SymTabs -> SymTabs
addGE n v (pe,ge) = let newge = addST n v ge in newge `seq` (pe, newge)

lookupPE :: String -> SymTabs -> Maybe PEDef
lookupPE s (pe,ge) = lookupST s pe

flattenEV :: EntityValue -> String
flattenEV (EntityValue evs) = concatMap flatten evs
  where
    flatten (EVString s)          = s
    flatten (EVRef (RefEntity r)) = "&" ++r++";"
    flatten (EVRef (RefChar r))   = "&#"++show r++";"
 -- flatten (EVPERef n)           = "%" ++n++";"


---- Misc ----

fst3 (a,_,_) = a
snd3 (_,a,_) = a
thd3 (_,_,a) = a


---- Auxiliary Parsing Functions ----
type XParser a = Parser SymTabs (Posn,TokenT) a

tok :: TokenT -> XParser TokenT
tok t = do (p,t') <- next
           if t==t' then return t
                    else fail ("Expected a "++show t++" but found a "++show t'
                              ++"\n  at "++show p)
nottok :: [TokenT] -> XParser TokenT
nottok ts = do (p,t) <- next
               if t`elem`ts then fail ("Expected no "++show t++" but found one"
                                      ++"\n  at "++show p)
                            else return t

name :: XParser Name
name = do {(p,TokName s) <- next; return s}

string, freetext :: XParser String
string   = do {(p,TokName s) <- next; return s}
freetext = do {(p,TokFreeText s) <- next; return s}

maybe :: XParser a -> XParser (Maybe a)
maybe p =
    ( p >>= return . Just) `onFail`
    ( return Nothing)

either :: XParser a -> XParser b -> XParser (Either a b)
either p q =
    ( p >>= return . Left) `onFail`
    ( q >>= return . Right)

word :: String -> XParser ()
word s = do { x <- next
            ; case x of
                (p,TokName n)     | s==n -> return ()
                (p,TokFreeText n) | s==n -> return ()
                (p,t) -> failP ("Expected "++show s++" but found "++show t)
            }

posn = do { x@(p,_) <- next
          ; reparse [x]
          ; return p
          }

failP :: String -> XParser a
failP msg = do { p <- posn
               ; fail (msg++"\n    at "++show p) }

adjustErrP :: XParser a -> (String->String) -> XParser a
p `adjustErrP` f = p `onFail` do pn <- posn
                                 (p `adjustErr` f) `adjustErr` (++show pn)

nmtoken :: XParser NmToken
nmtoken = (string `onFail` freetext)

peRef :: XParser a -> XParser a
peRef p =
    p `onFail`
    do pn <- posn
       n <- pereference
       tr <- stQuery (lookupPE n) `debug` ("Looking up %"++n)
       case tr of
           Just (PEDefEntityValue ev) ->
                      do reparse (xmlReLex (posInNewCxt ("macro %"++n++";")
                                                        (Just pn))
                                           (flattenEV ev))
                               `debug` ("  defn:  "++flattenEV ev)
                         peRef p
           Just (PEDefExternalID (PUBLIC _ (SystemLiteral f))) ->
                      do let val = unsafePerformIO (readFile f)
                         reparse (xmlReLex (posInNewCxt ("file "++f)
                                                        (Just pn)) val)
                               `debug` ("  reading from file "++f)
                         peRef p
           Just (PEDefExternalID (SYSTEM (SystemLiteral f))) ->
                      do let val = unsafePerformIO (readFile f)
                         reparse (xmlReLex (posInNewCxt ("file "++f)
                                                        (Just pn)) val)
                               `debug` ("  reading from file "++f)
                         peRef p
           Nothing -> fail ("PEReference use before definition: "++"%"++n++";"
                           ++"\n    at "++show pn)

blank :: XParser a -> XParser a
blank p =
    p `onFail`
    do n <- pereference
       tr <- stQuery (lookupPE n) `debug` ("Looking up %"++n++" (is blank?)")
       case tr of
           Just (PEDefEntityValue ev)
                    | all isSpace (flattenEV ev)  ->
                            do blank p `debug` "Empty macro definition"
           Just _  -> failP ("expected a blank PERef macro: "++"%"++n++";")
           Nothing -> failP ("PEReference use before definition: "++"%"++n++";")



---- XML Parsing Functions ----

justDTD :: XParser (Maybe DocTypeDecl)
justDTD =
  do (ExtSubset _ ds) <- extsubset `debug` "Trying external subset"
     if null ds then fail "empty"
         else return (Just (DTD "extsubset" Nothing (concatMap extract ds)))
  `onFail`
  do (Prolog _ _ dtd _) <- prolog
     return dtd
 where extract (ExtMarkupDecl m) = [m]
       extract (ExtConditionalSect (IncludeSect i)) = concatMap extract i
       extract (ExtConditionalSect (IgnoreSect i)) = []

document :: XParser (Document Posn)
document = do
    p <- prolog `onFail` failP "unrecognisable XML prolog"
    e <- element
    ms <- many misc
    (_,ge) <- stGet
    return (Document p ge e ms)

comment :: XParser Comment
comment = do
    bracket (tok TokCommentOpen) (tok TokCommentClose) freetext

processinginstruction :: XParser ProcessingInstruction
processinginstruction = do
    tok TokPIOpen
    n <- string  `onFail` failP "processing instruction has no target"
    f <- freetext
    tok TokPIClose `onFail` failP "missing ?>"
    return (n, f)

cdsect :: XParser CDSect
cdsect = do
    tok TokSectionOpen
    bracket (tok (TokSection CDATAx)) (tok TokSectionClose) chardata

prolog :: XParser Prolog
prolog = do
    x   <- maybe xmldecl
    m1  <- many misc
    dtd <- maybe doctypedecl
    m2  <- many misc
    return (Prolog x m1 dtd m2)

xmldecl :: XParser XMLDecl
xmldecl = do
    tok TokPIOpen
    (word "xml" `onFail` word "XML")
    p <- posn
    s <- freetext
    tok TokPIClose `onFail` failP "missing ?> in <?xml ...?>"
    raise ((runParser aux emptySTs . xmlReLex p) s)
  where
    aux = do
        v <- versioninfo  `onFail` failP "missing XML version info"
        e <- maybe encodingdecl
        s <- maybe sddecl
        return (XMLDecl v e s)
    raise (Left err, _, _) = failP err
    raise (Right ok, _, _) = return ok

versioninfo :: XParser VersionInfo
versioninfo = do
    (word "version" `onFail` word "VERSION")
    tok TokEqual
    bracket (tok TokQuote) (tok TokQuote) freetext

misc :: XParser Misc
misc =
    ( comment >>= return . Comment) `onFail`
    ( processinginstruction >>= return . PI)

doctypedecl :: XParser DocTypeDecl
doctypedecl = do
    tok TokSpecialOpen
    tok (TokSpecial DOCTYPEx)
    n   <- name
    eid <- maybe externalid
    es  <- maybe (bracket (tok TokSqOpen) (tok TokSqClose)
                          (many (peRef markupdecl)))
    blank (tok TokAnyClose)  `onFail` failP "missing > in DOCTYPE decl"
    return (DTD n eid (case es of { Nothing -> []; Just e -> e }))

markupdecl :: XParser MarkupDecl
markupdecl =
  oneOf [ ( elementdecl  >>= return . Element)
        , ( attlistdecl  >>= return . AttList)
        , ( entitydecl   >>= return . Entity)
        , ( notationdecl >>= return . Notation)
        , ( misc         >>= return . MarkupMisc)
        ]
    `adjustErrP`
          (++"\nLooking for a markup decl:\n\  
          \  (ELEMENT, ATTLIST, ENTITY, NOTATION, <!--comment-->, or <?PI?>")

extsubset :: XParser ExtSubset
extsubset = do
    td <- maybe textdecl
    ds <- many (peRef extsubsetdecl)
    return (ExtSubset td ds)

extsubsetdecl :: XParser ExtSubsetDecl
extsubsetdecl =
    ( markupdecl >>= return . ExtMarkupDecl) `onFail`
    ( conditionalsect >>= return . ExtConditionalSect)

sddecl :: XParser SDDecl
sddecl = do
    (word "standalone" `onFail` word "STANDALONE")
    tok TokEqual `onFail` failP "missing = in 'standalone' decl"
    bracket (tok TokQuote) (tok TokQuote)
            ( (word "yes" >> return True) `onFail`
              (word "no" >> return False) `onFail`
              failP "'standalone' decl requires 'yes' or 'no' value" )

element :: XParser (Element Posn)
element = do
    tok TokAnyOpen
    (ElemTag n as) <- elemtag
    (( do tok TokEndClose
          return (Elem n as [])) `onFail`
     ( do tok TokAnyClose
          cs <- many content
          p  <- posn
          m  <- bracket (tok TokEndOpen) (tok TokAnyClose) name
          checkmatch p n m
          return (Elem n as cs))
     `onFail` failP "missing > or /> in element tag")

checkmatch :: Posn -> Name -> Name -> XParser ()
checkmatch p n m =
  if n == m then return ()
  else failP ("tag <"++n++"> terminated by </"++m++">")

elemtag :: XParser ElemTag
elemtag = do
    n  <- name `onFail` failP "malformed element tag"
    as <- many attribute
    return (ElemTag n as)

attribute :: XParser Attribute
attribute = do
    n <- name
    tok TokEqual `onFail` failP "missing = in attribute"
    v <- attvalue `onFail` failP "missing attvalue"
    return (n,v)

content :: XParser (Content Posn)
content =
  do { p  <- posn
     ; c' <- content'
     ; return (c' p)
     }
  where content' = oneOf [ ( element >>= return . CElem)
                         , ( chardata >>= return . CString False)
                         , ( reference >>= return . CRef)
                         , ( cdsect >>= return . CString True)
                         , ( misc >>= return . CMisc)
                         ] `adjustErrP` (++"\nLooking for content:\n\ 
\    (element, text, reference, CDATA section, <!--comment-->, or <?PI?>")

elementdecl :: XParser ElementDecl
elementdecl = do
    tok TokSpecialOpen
    tok (TokSpecial ELEMENTx)
    n <- peRef name `onFail` failP "missing identifier in ELEMENT decl"
    c <- peRef contentspec `onFail` failP "missing content spec in ELEMENT decl"
    blank (tok TokAnyClose) `onFail` failP
       ("expected > terminating ELEMENT decl"
       ++"\n    element name was "++show n
       ++"\n    contentspec was "++(\ (ContentSpec p)-> show p) c)
    return (ElementDecl n c)

contentspec :: XParser ContentSpec
contentspec =
    oneOf [ ( peRef (word "EMPTY") >> return EMPTY)
          , ( peRef (word "ANY") >> return ANY)
          , ( peRef mixed >>= return . Mixed)
          , ( peRef cp >>= return . ContentSpec)
          ]
      `adjustErr` (++"\nLooking for content spec (EMPTY, ANY, mixed, etc)")

choice :: XParser [CP]
choice = do
    bracket (tok TokBraOpen `debug` "Trying choice")
            (blank (tok TokBraClose `debug` "Succeeded with choice"))
            (peRef cp `sepBy1` blank (tok TokPipe))

sequence :: XParser [CP]
sequence = do
    bracket (tok TokBraOpen `debug` "Trying sequence")
            (blank (tok TokBraClose `debug` "Succeeded with sequence"))
            (peRef cp `sepBy1` blank (tok TokComma))

cp :: XParser CP
cp = oneOf [ ( do n <- name
                  m <- modifier
                  let c = TagName n m
                  return c `debug` ("ContentSpec: name "++show c))
           , ( do ss <- sequence
                  m <- modifier
                  let c = Seq ss m
                  return c `debug` ("ContentSpec: sequence "++show c))
           , ( do cs <- choice
                  m <- modifier
                  let c = Choice cs m
                  return c `debug` ("ContentSpec: choice "++show c))
           ] `adjustErr` (++"\nLooking for a content particle")

modifier :: XParser Modifier
modifier = oneOf [ ( tok TokStar >> return Star )
                 , ( tok TokQuery >> return Query )
                 , ( tok TokPlus >> return Plus )
                 , ( return None )
                 ]

-- just for debugging
instance Show CP where
    show (TagName n m) = n++show m
    show (Choice cps m) = '(': concat (intersperse "|" (map show cps))
                          ++")"++show m
    show (Seq cps m) = '(': concat (intersperse "," (map show cps))
                          ++")"++show m
instance Show Modifier where
    show None = ""
    show Query = "?"
    show Star = "*"
    show Plus = "+"
----

mixed :: XParser Mixed
mixed = do
    tok TokBraOpen
    peRef (do tok TokHash
              word "PCDATA")
    oneOf [ ( do cs <- many (peRef (do tok TokPipe
                                       peRef name))
                 blank (tok TokBraClose >> tok TokStar)
                 return (PCDATAplus cs))
          , ( blank (tok TokBraClose >> tok TokStar) >> return PCDATA)
          , ( blank (tok TokBraClose) >> return PCDATA)
          ] `adjustErr` (++"\nLooking for mixed content spec (#PCDATA | ...)*")

attlistdecl :: XParser AttListDecl
attlistdecl = do
    tok TokSpecialOpen
    tok (TokSpecial ATTLISTx)
    n <- peRef name `onFail` failP "missing identifier in ATTLIST"
    ds <- peRef (many (peRef attdef))
    blank (tok TokAnyClose) `onFail` failP "missing > terminating ATTLIST"
    return (AttListDecl n ds)

attdef :: XParser AttDef
attdef =
  do n <- peRef name
     t <- peRef atttype `onFail` failP "missing attribute type in attlist defn"
     d <- peRef defaultdecl
     return (AttDef n t d)

atttype :: XParser AttType
atttype =
    oneOf [ ( word "CDATA" >> return StringType)
          , ( tokenizedtype >>= return . TokenizedType)
          , ( enumeratedtype >>= return . EnumeratedType)
          ]
      `adjustErr` (++"\nLooking for ATTTYPE (CDATA, tokenized, or enumerated")

tokenizedtype :: XParser TokenizedType
tokenizedtype =
    oneOf [ ( word "ID" >> return ID)
          , ( word "IDREF" >> return IDREF)
          , ( word "IDREFS" >> return IDREFS)
          , ( word "ENTITY" >> return ENTITY)
          , ( word "ENTITIES" >> return ENTITIES)
          , ( word "NMTOKEN" >> return NMTOKEN)
          , ( word "NMTOKENS" >> return NMTOKENS)
          ] `adjustErr` (++"\nLooking for a tokenized type:\n\ 
\    (ID, IDREF, IDREFS, ENTITY, ENTITIES, NMTOKEN, NMTOKENS)")

enumeratedtype :: XParser EnumeratedType
enumeratedtype =
    oneOf [ ( notationtype >>= return . NotationType)
          , ( enumeration >>= return . Enumeration)
          ]
      `adjustErr` (++"\nLooking for an enumerated or NOTATION type")

notationtype :: XParser NotationType
notationtype = do
    word "NOTATION"
    bracket (tok TokBraOpen) (blank (tok TokBraClose))
            (peRef name `sepBy1` peRef (tok TokPipe))

enumeration :: XParser Enumeration
enumeration =
    bracket (tok TokBraOpen) (blank (tok TokBraClose))
            (peRef nmtoken `sepBy1` blank (peRef (tok TokPipe)))

defaultdecl :: XParser DefaultDecl
defaultdecl =
    oneOf [ ( tok TokHash >> word "REQUIRED" >> return REQUIRED)
          , ( tok TokHash >> word "IMPLIED" >> return IMPLIED)
          , ( do f <- maybe (tok TokHash >> word "FIXED" >> return FIXED)
                 a <- peRef attvalue
                 return (DefaultTo a f))
          ]
      `adjustErr` (++"\nLooking for an attribute default decl:\n\ 
\    (REQUIRED, IMPLIED, FIXED)")

conditionalsect :: XParser ConditionalSect
conditionalsect = oneOf
    [ ( do tok TokSectionOpen
           peRef (tok (TokSection INCLUDEx))
           p <- posn
           tok TokSqOpen `onFail` failP "missing [ after INCLUDE"
           i <- many (peRef extsubsetdecl)
           tok TokSectionClose `onFail` (failP "missing ]]> for INCLUDE section"
                                               ++"\n    begun at "++show p)
           return (IncludeSect i))
    , ( do tok TokSectionOpen
           peRef (tok (TokSection IGNOREx))
           p <- posn
           tok TokSqOpen `onFail` failP "missing [ after IGNORE"
           i <- many newIgnore  -- many ignoresectcontents
           tok TokSectionClose `onFail` (failP "missing ]]> for IGNORE section"
                                               ++"\n    begun at "++show p)
           return (IgnoreSect []))
    ] `adjustErr` (++"\nLooking for an INCLUDE or IGNORE section")

newIgnore :: XParser Ignore
newIgnore =
    ( do tok TokSectionOpen
         many newIgnore `debug` "IGNORING conditional section"
         tok TokSectionClose
         return Ignore `debug` "end of IGNORED conditional section") `onFail`
    ( do t <- nottok [TokSectionOpen,TokSectionClose]
         return Ignore  `debug` ("ignoring: "++show t))

--- obsolete?
ignoresectcontents :: XParser IgnoreSectContents
ignoresectcontents = do
    i <- ignore
    is <- many (do tok TokSectionOpen
                   ic <- ignoresectcontents
                   tok TokSectionClose
                   ig <- ignore
                   return (ic,ig))
    return (IgnoreSectContents i is)

ignore :: XParser Ignore
ignore = do
  is <- many1 (nottok [TokSectionOpen,TokSectionClose])
  return Ignore  `debug` ("ignored all of: "++show is)
----

reference :: XParser Reference
reference = do
    bracket (tok TokAmp) (tok TokSemi) (freetext >>= val)
  where
    val ('#':'x':i) | all isHexDigit i
                    = return . RefChar . fst . head . readHex $ i
    val ('#':i)     | all isDigit i
                    = return . RefChar . fst . head . readDec $ i
    val name        = return . RefEntity $ name

{- -- following is incorrect
reference =
    ( charref >>= return . RefChar) `onFail`
    ( entityref >>= return . RefEntity)

entityref :: XParser EntityRef
entityref = do
    bracket (tok TokAmp) (tok TokSemi) name

charref :: XParser CharRef
charref = do
    bracket (tok TokAmp) (tok TokSemi) (freetext >>= readCharVal)
  where
    readCharVal ('#':'x':i) = return . fst . head . readHex $ i
    readCharVal ('#':i)     = return . fst . head . readDec $ i
    readCharVal _           = mzero
-}

pereference :: XParser PEReference
pereference = do
    bracket (tok TokPercent) (tok TokSemi) nmtoken

entitydecl :: XParser EntityDecl
entitydecl =
    ( gedecl >>= return . EntityGEDecl) `onFail`
    ( pedecl >>= return . EntityPEDecl)

gedecl :: XParser GEDecl
gedecl = do
    tok TokSpecialOpen
    tok (TokSpecial ENTITYx)
    n <- name
    e <- entitydef `onFail` failP "missing entity defn in G ENTITY decl"
    tok TokAnyClose `onFail` failP "expected > terminating G ENTITY decl"
    stUpdate (addGE n e) `debug` ("added GE defn &"++n++";")
    return (GEDecl n e)

pedecl :: XParser PEDecl
pedecl = do
    tok TokSpecialOpen
    tok (TokSpecial ENTITYx)
    tok TokPercent
    n <- name
    e <- pedef `onFail` failP "missing entity defn in P ENTITY decl"
    tok TokAnyClose `onFail` failP "expected > terminating P ENTITY decl"
    stUpdate (addPE n e) `debug` ("added PE defn %"++n++";\n"++show e)
    return (PEDecl n e)

entitydef :: XParser EntityDef
entitydef =
    ( entityvalue >>= return . DefEntityValue) `onFail`
    ( do eid <- externalid
         ndd <- maybe ndatadecl
         return (DefExternalID eid ndd))

pedef :: XParser PEDef
pedef =
    ( entityvalue >>= return . PEDefEntityValue) `onFail`
    ( externalid  >>= return . PEDefExternalID)

externalid :: XParser ExternalID
externalid =
    ( do word "SYSTEM"
         s <- systemliteral
         return (SYSTEM s)) `onFail`
    ( do word "PUBLIC"
         p <- pubidliteral
         s <- systemliteral
         return (PUBLIC p s))

ndatadecl :: XParser NDataDecl
ndatadecl = do
    word "NDATA"
    n <- name
    return (NDATA n)

textdecl :: XParser TextDecl
textdecl = do
    tok TokPIOpen
    (word "xml" `onFail` word "XML")
    v <- maybe versioninfo
    e <- encodingdecl
    tok TokPIClose `onFail` failP "expected ?> terminating text decl"
    return (TextDecl v e)

extparsedent :: XParser (ExtParsedEnt Posn)
extparsedent = do
    t <- maybe textdecl
    c <- content
    return (ExtParsedEnt t c)

extpe :: XParser ExtPE
extpe = do
    t <- maybe textdecl
    e <- many (peRef extsubsetdecl)
    return (ExtPE t e)

encodingdecl :: XParser EncodingDecl
encodingdecl = do
    (word "encoding" `onFail` word "ENCODING")
    tok TokEqual `onFail` failP "expected = in 'encoding' decl"
    f <- bracket (tok TokQuote) (tok TokQuote) freetext
    return (EncodingDecl f)

notationdecl :: XParser NotationDecl
notationdecl = do
    tok TokSpecialOpen
    tok (TokSpecial NOTATIONx)
    n <- name
    e <- either externalid publicid
    tok TokAnyClose `onFail` failP "expected > terminating NOTATION decl"
    return (NOTATION n e)

publicid :: XParser PublicID
publicid = do
    word "PUBLIC"
    p <- pubidliteral
    return (PUBLICID p)

entityvalue :: XParser EntityValue
entityvalue = do
 -- evs <- bracket (tok TokQuote) (tok TokQuote) (many (peRef ev))
    tok TokQuote
    pn <- posn
    evs <- many ev
    tok TokQuote `onFail` failP "expected quote to terminate entityvalue"
    -- quoted text must be rescanned for possible PERefs
    st <- stGet
    Prelude.either fail (return . EntityValue) . fst3 $
                (runParser (many ev) st
                         (reLexEntityValue (\s-> stringify (lookupPE s st))
                                           pn
                                           (flattenEV (EntityValue evs))))
  where
    stringify (Just (PEDefEntityValue ev)) = Just (flattenEV ev)
    stringify _ = Nothing

ev :: XParser EV
ev =
    ( (string`onFail`freetext) >>= return . EVString) `onFail`
    ( reference >>= return . EVRef)

attvalue :: XParser AttValue
attvalue = do
    avs <- bracket (tok TokQuote) (tok TokQuote)
                   (many (either freetext reference))
    return (AttValue avs)

systemliteral :: XParser SystemLiteral
systemliteral = do
    s <- bracket (tok TokQuote) (tok TokQuote) freetext
    return (SystemLiteral s)            -- note: refs &...; not permitted

pubidliteral :: XParser PubidLiteral
pubidliteral = do
    s <- bracket (tok TokQuote) (tok TokQuote) freetext
    return (PubidLiteral s)             -- note: freetext is too liberal here

chardata :: XParser CharData
chardata = freetext

