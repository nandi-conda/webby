## Strong passwords for new accounts.

import crypto

const
  lower = "abcdefghijkmnopqrstuvwxyz"
  upper = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  digits = "23456789"
  symbols = "-_.!@#%+="

proc secureBelow(n: int): int =
  ## Uniform in 0 ..< n (n <= 256) from OpenSSL's CSPRNG, by rejection.
  let limit = 256 - 256 mod n
  while true:
    let b = randomBytes(1)[0].int
    if b < limit: return b mod n

proc generatePassword*(length = 20): string =
  ## `length` characters with at least one lowercase letter, uppercase letter, digit and symbol. Look-alikes
  ## (l, I, O, 0, 1) are left out. 20 characters from this set is about 120 bits.
  assert length >= 8
  const all = lower & upper & digits & symbols
  proc pick(s: string): char = s[secureBelow(s.len)]
  result = $pick(lower) & pick(upper) & pick(digits) & pick(symbols)
  for _ in 4 ..< length: result.add pick(all)
  for i in countdown(result.high, 1):   # Fisher-Yates
    swap(result[i], result[secureBelow(i + 1)])
