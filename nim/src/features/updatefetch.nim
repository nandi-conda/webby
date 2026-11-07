## The release lookups of update.nim (AppImage) and apkupdate.nim (Android) go to api.github.com, which now and then
## answers 502/503/504 (its gateway timing out) or doesn't answer at all. A check then asked again a few seconds
## later almost always works, so these are retried before the check gives up.

import nimkit/services

const retryAfterMs = [2_000, 6_000, 15_000]

proc transient*(r: Response): bool =
  ## A failure worth asking again: no answer, a timeout, or the server's gateway giving up.
  r.status == 0 or r.status in [408, 429, 500, 502, 503, 504]

proc getRetrying*(url: string, headers: seq[(string, string)], onDone: proc (r: Response), attempt = 0) =
  ## GET `url`; on a transient failure tries again after 2, 6 and 15 s. `onDone` gets the last answer.
  request("GET", url, proc (r: Response) =
    if transient(r) and attempt < retryAfterMs.len:
      log("webby: " & url & ": " & $r.status & " " & r.error & ", asking again")
      discard after(retryAfterMs[attempt], proc () = getRetrying(url, headers, onDone, attempt + 1))
    else: onDone(r),
    headers = headers)

proc failureText*(r: Response): string =
  ## For the "Could not check for updates" toast.
  if r.error.len > 0: r.error
  elif r.status in 500 .. 599: "GitHub answered " & $r.status & ", try again in a few minutes"
  else: $r.status
