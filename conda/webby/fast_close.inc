  // Flutter's quit leaves the windows mapped until the process exits, so they stay on screen while Ladybird and the
  // engine tear down. Hide them now (the framework already agreed to exit) and flush so the close looks instant.
  for (GList* l = gtk_window_list_toplevels(); l != nullptr; l = g_list_delete_link(l, l))
    gtk_widget_hide(GTK_WIDGET(l->data));
  gdk_display_flush(gdk_display_get_default());
  // Then exit without running static destructors: Ladybird's ~Application crashes once the event loop is gone (a
  // SIGILL core dump on every quit), and WebContent and the other helpers exit on their own when their sockets close.
  fflush(nullptr);
  _exit(0);
