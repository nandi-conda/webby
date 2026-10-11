  // Installed web apps get their own application id (WEBBY_APP_ID, set by their launcher), which becomes the Wayland
  // app id and the X11 WM_CLASS, so docks match the window to the app's .desktop file and icon instead of webby's.
  const gchar* webby_app_id = g_getenv("WEBBY_APP_ID");
  if (webby_app_id == nullptr || !g_application_id_is_valid(webby_app_id))
    webby_app_id = APPLICATION_ID;
  gdk_set_program_class(webby_app_id);
