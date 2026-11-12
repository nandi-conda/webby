import std/[json, os, strutils]
import ../../../nim/src/features/sync/[doc, keys]
let now = 2000000000'i64
let a = docFromJson(parseJson(readFile("a.json")))
let b = docFromJson(parseJson(readFile("b.json")))
var o = newJObject()
o["canonA"] = %canonical(a)
o["canonB"] = %canonical(b)
o["mergeAB"] = %canonical(mergeDocs(a, b, now))
o["mergeBA"] = %canonical(mergeDocs(b, a, now))
var key = ""
for i in 0..31: key.add chr(i * 7 + 3)
let code = codeFor(key)
o["code"] = %code
let k = deriveKeys(code)
o["blobId"] = %k.blobId
o["bookmarksBlobId"] = %k.bookmarksBlobId
o["tabsBlobId"] = %k.tabsBlobId
o["secretsBlobId"] = %k.secretsBlobId
o["authToken"] = %k.authToken
o["encKey"] = %k.encryptionKey.toHex.toLowerAscii
o["sealed"] = %k.seal(mergeDocs(a, b, now))
o["normalized"] = %normalizeCode(code.toLowerAscii.replace("-", " ").replace("o", "0"))
var doubles = newJArray()
for x in [1.0, 0.1, 1e21, 1e20, 1.5e-7, 1e-6, 123456789.123, -2.5, 5e-324, 1.7976931348623157e308, 100.0, 0.000001234]: doubles.add %dartDouble(x)
o["doubles"] = doubles
if paramCount() > 0:
  let sealed = readFile(paramStr(1))
  o["openedCpp"] = %canonical(k.open(sealed))
echo o.pretty
