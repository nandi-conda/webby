## nimkit: one Nim app for the Linux desktop (GTK 3), Android and the web, grown out of webby's Nim front ends.
##
##   import nimkit
##   let hello = label("Hello")
##   run("Demo", column(hello, button("Click", proc () = hello.text = "Clicked")))
##
## The backend is picked by the build target: `nim js` gives the web backend, `--os:android` the Android one, and
## anything else GTK. See framework/README.md for building each.

import nimkit/[core, services]
export core, services

when defined(js):
  import nimkit/backend/web
  export web
elif defined(android):
  import nimkit/backend/android
  export android
else:
  import nimkit/backend/gtk
  export gtk
