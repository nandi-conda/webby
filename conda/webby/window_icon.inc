  // Window icon: data/webby.png next to the executable (installed by conda/webby/build.sh).
  {
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    if (exe != nullptr) {
      g_autofree gchar* dir = g_path_get_dirname(exe);
      g_autofree gchar* icon = g_build_filename(dir, "data", "webby.png", nullptr);
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }
  // Installed web apps (webby --app, see app/lib/src/pwa/app_store.dart): the launcher passes the app's name and icon.
  {
    const gchar* app_name = g_getenv("WEBBY_APP_NAME");
    if (app_name != nullptr && *app_name != '\0') {
      gtk_window_set_title(window, app_name);
      GtkWidget* titlebar = gtk_window_get_titlebar(window);
      if (titlebar != nullptr && GTK_IS_HEADER_BAR(titlebar))
        gtk_header_bar_set_title(GTK_HEADER_BAR(titlebar), app_name);
    }
    const gchar* app_icon = g_getenv("WEBBY_APP_ICON");
    if (app_icon != nullptr && *app_icon != '\0')
      gtk_window_set_icon_from_file(window, app_icon, nullptr);
  }
