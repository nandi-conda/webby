## HTTP requests and one-shot timers for the features (sync blobs, site icons, web app manifests), from nimkit's
## services (framework/src/nimkit/services.nim): GIO and GLib through nimkit's GTK backend on the desktop,
## its Android backend on Android.

import nimkit/services
export services.Response, services.Timer, services.header, services.after, services.cancel

proc request*(meth, url: string, headers: openArray[(string, string)], body: string,
              onDone: proc (r: Response)) =
  services.request(meth, url, onDone, @headers, body)
