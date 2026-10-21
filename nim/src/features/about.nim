## About: ⋮ > About Webby shows which build this is (the git commit it was built from, the package version and the
## Ladybird runtime's version), with a Copy button that puts all of it on the clipboard for bug reports.
##
## The commit and version are baked in at build time: scripts/pixi_nim.sh, conda/webby/build.sh and
## nim/android-kit/build.sh pass -d:webbyCommit (with "-dirty" when nim/, framework/ or icons/ had uncommitted
## changes) and -d:webbyVersion. A plain `nim c` asks git itself.

import std/[os, strutils]
import ../browser
from ../ffi import ladybirdPrefix
from nimkit/core as kit import nil

const
  webbyCommit {.strdefine.} = ""
  webbyVersion {.strdefine.} = ""   ## the conda package's or APK's version; empty for a local build
  webbyRuntime {.strdefine.} = ""   ## Android: the native part's version (scripts/android/native.env)
  repoUrl = "https://github.com/nandi-conda/webby"
  commit = (if webbyCommit.len > 0: webbyCommit
            else: staticExec("git -C " & quoteShell(currentSourcePath().parentDir) & " rev-parse HEAD 2>/dev/null").strip)

proc runtimeVersion(): string =
  ## webby-ladybird's version from the env's conda-meta (the runtime lives in <env>/lib/webby-ladybird).
  when defined(android):
    result = if webbyRuntime.len > 0: "webby-android-native " & webbyRuntime else: "unknown"
  else:
    let prefix = ladybirdPrefix()
    for f in walkFiles(prefix / ".." / ".." / "conda-meta" / "webby-ladybird-*.json"):
      let parts = f.extractFilename.changeFileExt("").split('-')   # webby-ladybird-<version>-<build>
      if parts.len >= 4: return "webby-ladybird " & parts[2] & " (" & parts[3] & ")"
    result = "custom runtime at " & prefix

proc buildInfo(): tuple[version, commit, runtime: string] =
  result.version = if webbyVersion.len > 0: webbyVersion else: "local build"
  result.commit = if commit.len > 0: commit else: "unknown"
  result.runtime = runtimeVersion()

proc showAbout() =
  let b = buildInfo()
  let short = if b.commit.len >= 12 and b.commit[0 .. 11].allCharsInSet(HexDigits): b.commit[0 .. 11] else: b.commit
  let sha = b.commit.split('-')[0]
  let commitMarkup =
    if sha.len == 40: "<a href=\"" & repoUrl & "/commit/" & sha & "\"><tt>" & kit.escapeRich(b.commit) & "</tt></a>"
    else: "<tt>" & kit.escapeRich(b.commit) & "</tt>"
  let commitLabel = kit.richLabel("Commit " & commitMarkup, selectable = true)
  commitLabel.onLink = proc (url: string): bool = (discard openTab(url); true)   # in a tab here, not another browser
  let content = kit.column(
    kit.richLabel("<b>Webby " & kit.escapeRich(b.version) & "</b>", selectable = true),
    commitLabel,
    kit.richLabel("Engine " & kit.escapeRich(b.runtime), selectable = true))
  let text = "webby " & b.version & " (" & short & ")\ncommit " & b.commit & "\nengine " & b.runtime
  discard kit.dialog("About Webby", content, @["Close", "Copy"], proc (i: int) =
    if i == 1:
      copyText(text)
      kit.toast("Build info copied"))

proc install*() =
  # From a window hook, and installed last, so it comes after the other features' items (they add theirs there too).
  windowHooks.add proc () =
    addMenuSeparator()
    addMenuItem("About Webby", showAbout)
