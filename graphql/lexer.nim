# nim-graphql
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[unicode, strutils],
  faststreams/inputs,
  ./common/[names, errors, types]

type
  TokKind* = enum
    tokError       = ":error:"
    tokEof         = "EOF"
    tokName        = "Name"
    tokInt         = "Int"
    tokFloat       = "Float"
    tokString      = "String"
    tokBlockString = "String"

    tokBang        = "'!'"
    tokDollar      = "'$'"
    tokColon       = "':'"
    tokEqual       = "'='"
    tokAt          = "'@'"
    tokPipe        = "'|'"
    tokEllipsis    = "'...'"
    tokLParen      = "'('"
    tokRParen      = "')'"
    tokLBracket    = "'['"
    tokRBracket    = "']'"
    tokLCurly      = "'{'"
    tokRCurly      = "'}'"
    tokAmp         = "'&'"

  LexerError = enum
    errNone                = "no error"
    errInvalidBOM          = "Invalid Byter Order Mark"
    errNoDigitAfterZero    = "No digits allowed after zero"
    errNoDotOrName         = "No dot or name allowed after number"
    errUnterminatedString  = "Please terminate string with '\"'"
    errUnterminatedBlockString  = "Please terminate string with '\"\"\"'"
    errInvalidEscape       = "Invalid escape char '$1'"
    errInvalidUnicode      = "Invalid unicode sequence '$1'"
    errInvalidChar         = "Invalid char '$1'"
    errLoopLimit           = "loop limit $1 reached for $2"

  LexConf* = object
    maxIdentChars* : int
    maxDigits*     : int
    maxStringChars*: int

  LexConfInternal = object
    maxIdentChars : LoopGuard
    maxDigits     : LoopGuard
    maxStringChars: LoopGuard

  Lexer* = object
    stream*    : InputStream
    names*     : NameCache
    line*      : int
    lineStart* : int
    tokenStart*: int
    tok*       : TokKind
    token*     : string
    name*      : Name
    error*     : LexerError
    err*       : ErrorDesc
    conf       : LexConfInternal

proc defaultLexConf*(): LexConf =
  result.maxIdentChars  = 128
  result.maxDigits      = 128
  result.maxStringChars = 2048

proc toInternalConf(conf: LexConf): LexConfInternal =
  result.maxIdentChars  = LoopGuard(maxLoop: conf.maxIdentChars , desc: "max chars in ident")
  result.maxDigits      = LoopGuard(maxLoop: conf.maxDigits     , desc: "max digits in number")
  result.maxStringChars = LoopGuard(maxLoop: conf.maxStringChars, desc: "max chars in string")

proc init*(T: type Lexer, stream: InputStream, names: NameCache, conf = defaultLexConf()): T =
  result = Lexer(
    stream: stream,
    names: names,
    line: 1,
    conf: toInternalConf(conf)
  )

template peek(s: InputStream): char =
  char inputs.peek(s)

template read(s: InputStream): char =
  char inputs.read(s)

func peekSpecial(lex: Lexer): string =
  "\\" & $int(lex.stream.peek)

proc col*(lex: Lexer): int =
  lex.stream.pos - lex.lineStart

proc tokenStartCol*(lex: Lexer): int =
  1 + lex.tokenStart - lex.lineStart

func pos*(lex: Lexer): Pos =
  Pos(line: lex.line.uint16, col: lex.tokenStartCol.uint16)

proc lexerError(lex: var Lexer, errKind: LexerError, args: varargs[string, `$`]) =
  lex.error = errKind
  lex.tok = tokError
  lex.tokenStart = lex.stream.pos
  lex.name = lex.names.emptyName
  lex.token.setLen(0)

  lex.err.pos = lex.pos
  lex.err.level = elError
  lex.err.message = $errKind

  case errKind
  of errInvalidEscape, errInvalidUnicode, errInvalidChar:
    lex.err.message = $errKind % [args[0]]
  of errLoopLimit:
    lex.err.message = $errKind % [args[0], args[1]]
  else:
    lex.err.message = $errKind

template safePeek(lex: Lexer, x: char): bool =
  lex.stream.readable and lex.stream.peek == x

template safePeek(lex: Lexer, x: set[char]): bool =
  lex.stream.readable and lex.stream.peek in x

template safePeekNotIn(lex: Lexer, x: set[char]): bool =
  lex.stream.readable and lex.stream.peek notin x

proc skipBOM*(lex: var Lexer): bool =
  if lex.stream.peek == char(0xFE):
    advance lex.stream
    if lex.stream.peek == char(0xFF):
      advance lex.stream
      return true
    else:
      lex.lexerError(errInvalidBOM)
      return false
  else:
    return true

proc handleLF(lex: var Lexer) {.inline.} =
  advance lex.stream
  lex.line += 1
  lex.lineStart = lex.stream.pos

proc skipWhitespace(lex: var Lexer) =
  const SkipableChars = {'\t', ' ', ','}

  template handleCR =
    advance lex.stream
    if not lex.stream.readable: return
    if lex.stream.peek == '\n': advance lex.stream
    lex.line += 1
    lex.lineStart = lex.stream.pos

  while lex.stream.readable:
    case lex.stream.peek
    of SkipableChars:
      # also skip insignificants commas
      advance lex.stream
    of '#':
      # skip comments until EOL
      advance lex.stream
      while true:
        if not lex.stream.readable: return
        case lex.stream.peek
        of '\r':
          handleCR()
          break
        of '\n':
          lex.handleLF()
          break
        else:
          advance lex.stream
    of '\r':
      handleCR()
    of '\n':
      lex.handleLF()
    else:
      break

const
  Digits = {'0'..'9'}
  IdentStart = {'a'..'z', 'A'..'Z', '_'}
  IdentChars = IdentStart + Digits
  NotNumberChars = IdentStart + {'.'}
  HexDigits = {'0'..'9', 'a'..'f', 'A'..'F'}
  InvalidChars = {'\0'..'\x19'} - {'\t', '\r', '\n'}

template loopGuard(loopCounter: int, maxLoop: int, desc: string) =
  inc loopCounter
  if loopCounter > maxLoop:
    lex.lexerError(errLoopLimit, maxLoop, desc)
    return

template safeLoop(lg: LoopGuard, cond: untyped, body: untyped) =
  var loopCounter = 0
  while cond:
    body
    loopGuard(loopCounter, lg.maxLoop, lg.desc)

proc scanName(lex: var Lexer) =
  lex.token.setLen(0)
  lex.tok = tokName
  lex.token.add lex.stream.read
  safeLoop(lex.conf.maxIdentChars, lex.safePeek IdentChars):
    lex.token.add lex.stream.read

  lex.name = lex.names.insert(lex.token)

proc scanNumber(lex: var Lexer) =
  lex.token.setLen(0)

  lex.tok = tokInt
  if lex.safePeek '-':
    lex.token.add lex.stream.read

  if lex.safePeek '0':
    lex.token.add lex.stream.read

    if lex.safePeek Digits:
      lex.lexerError(errNoDigitAfterZero)
      return
  else:
    safeLoop(lex.conf.maxDigits, lex.safePeek Digits):
      lex.token.add lex.stream.read

  if lex.safePeek '.':
    lex.tok = tokFloat
    lex.token.add lex.stream.read
    safeLoop(lex.conf.maxDigits, lex.safePeek Digits):
      lex.token.add lex.stream.read

  if lex.safePeek {'e', 'E'}:
    lex.tok = tokFloat
    lex.token.add lex.stream.read

    if lex.safePeek {'-', '+'}:
      lex.token.add lex.stream.read

    safeLoop(lex.conf.maxDigits, lex.safePeek Digits):
      lex.token.add lex.stream.read

  if lex.safePeek NotNumberChars:
    lex.lexerError(errNoDotOrName)
    return

func charTo(T: type, c: char): T {.inline.} =
  case c
  of {'0'..'9'}: result = T(c) - T('0')
  of {'a'..'f'}: result = T(c) - T('a') + T(10)
  of {'A'..'F'}: result = T(c) - T('A') + T(10)
  else: doAssert(false, "should never executed")

proc scanHexDigits(lex: var Lexer, value: var int): int =
  safeLoop(lex.conf.maxDigits, lex.safePeek HexDigits):
    inc result
    value = value * 16 + charTo(int, lex.stream.read)

proc scanUnicode(lex: var Lexer): bool =
  var code: int
  if lex.scanHexDigits(code) != 4:
    lex.lexerError(errInvalidUnicode, code)
    return false

  lex.token.add unicode.toUTF8(Rune(code))
  return true

proc scanEscapeChar(lex: var Lexer): bool =
  if not lex.stream.readable:
    lex.lexerError(errInvalidEscape, tokEof)
    return false

  case lex.stream.peek
  of 'b':
    advance lex.stream
    lex.token.add "\b"
  of 't':
    advance lex.stream
    lex.token.add "\t"
  of 'n':
    advance lex.stream
    lex.token.add "\n"
  of 'f':
    advance lex.stream
    lex.token.add "\f"
  of 'r':
    advance lex.stream
    lex.token.add "\r"
  of '\"':
    advance lex.stream
    lex.token.add "\""
  of '\\':
    advance lex.stream
    lex.token.add "\\"
  of '/':
    advance lex.stream
    lex.token.add "/"
  of 'u':
    advance lex.stream
    return lex.scanUnicode()
  else:
    lex.lexerError(errInvalidEscape, lex.stream.peek)
    return false
  return true

proc scanMultiLineString(lex: var Lexer) =
  template handleCR =
    lex.token.add lex.stream.read
    if not lex.stream.readable: return
    if lex.stream.peek == '\n':
      lex.token.add lex.stream.read
    lex.line += 1
    lex.lineStart = lex.stream.pos

  safeLoop(lex.conf.maxStringChars, lex.stream.readable):
    case lex.stream.peek
    of '"':
      advance lex.stream
      if lex.safePeek '"':
        advance lex.stream
        if lex.safePeek '"':
          advance lex.stream
          if lex.token.len > 0 and lex.token[^1] == '\\':
            lex.token.setLen(lex.token.len-1)
            lex.token.add "\"\"\"" # Escape Triple-Quote (\""")
          else:
            return
        else:
          lex.token.add '"'
          lex.token.add '"'
      else:
        lex.token.add '"'

    of InvalidChars:
      lex.lexerError(errInvalidChar, lex.peekSpecial)
      advance lex.stream
      return
    of '\r':
      handleCR()
    of '\n':
      lex.handleLF()
      lex.token.add "\n"
    of '\\':
      lex.token.add lex.stream.read
    else:
      # FIXME: this is not a valid UTF-16 lexer
      lex.token.add lex.stream.read

  lex.lexerError(errUnterminatedBlockString)

proc scanSingleLineString(lex: var Lexer) =
  safeLoop(lex.conf.maxStringChars, lex.safePeekNotIn {'\r', '\n'}):
    case lex.stream.peek
    of InvalidChars:
      lex.lexerError(errInvalidChar, lex.peekSpecial)
      advance lex.stream
      return
    of '"':
      advance lex.stream
      return
    of '\\':
      advance lex.stream
      if not lex.scanEscapeChar():
        return
      continue
    else:
      # FIXME: this is not a valid UTF-16 lexer
      lex.token.add lex.stream.read

  lex.lexerError(errUnterminatedString)

proc scanString(lex: var Lexer) =
  lex.token.setLen(0)
  lex.tok = tokString
  # we already check the first '"'
  advance lex.stream

  if lex.safePeek '"':
    advance lex.stream

    # We have two possibilities here:
    if lex.safePeek '"':
      # (1) block string.
      advance lex.stream
      lex.tok = tokBlockString
      lex.scanMultiLineString()
      return

    # (2) the empty string
  else:
    lex.scanSingleLineString()

proc next*(lex: var Lexer) =
  lex.skipWhitespace()

  if not lex.stream.readable:
    lex.tokenStart = lex.stream.pos
    lex.tok = tokEof
    lex.name = lex.names.emptyName
    lex.token.setLen(0)
    return

  lex.tokenStart = lex.stream.pos
  let c = lex.stream.peek()
  case c
  of '!':
    advance lex.stream
    lex.tok = tokBang
  of '$':
    advance lex.stream
    lex.tok = tokDollar
  of '(':
    advance lex.stream
    lex.tok = tokLParen
  of ')':
    advance lex.stream
    lex.tok = tokRParen
  of '[':
    advance lex.stream
    lex.tok = tokLBracket
  of ']':
    advance lex.stream
    lex.tok = tokRBracket
  of '{':
    advance lex.stream
    lex.tok = tokLCurly
  of '}':
    advance lex.stream
    lex.tok = tokRCurly
  of ':':
    advance lex.stream
    lex.tok = tokColon
  of '=':
    advance lex.stream
    lex.tok = tokEqual
  of '@':
    advance lex.stream
    lex.tok = tokAt
  of '|':
    advance lex.stream
    lex.tok = tokPipe
  of '&':
    advance lex.stream
    lex.tok = tokAmp
  of '.':
    advance lex.stream
    if not lex.stream.readable or lex.stream.peek != '.':
      lex.lexerError(errInvalidChar, lex.peekSpecial)
      return
    advance lex.stream
    if not lex.stream.readable or lex.stream.peek != '.':
      lex.lexerError(errInvalidChar, lex.peekSpecial)
      return
    advance lex.stream
    lex.tok = tokEllipsis
  of IdentStart:
    lex.scanName()
  of '-', '0'..'9':
    lex.scanNumber()
  of '"':
    lex.scanString()
  else:
    lex.lexerError(errInvalidChar, lex.peekSpecial)
    advance lex.stream
