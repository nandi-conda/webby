  // Window icon: data/webby.png next to the executable (installed by conda/webby/build.sh).
  {
    g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
    if (exe != nullptr) {
      g_autofree gchar* dir = g_path_get_dirname(exe);
      g_autofree gchar* icon = g_build_filename(dir, "data", "webby.png", nullptr);
      gtk_window_set_icon_from_file(window, icon, nullptr);
    }
  }
