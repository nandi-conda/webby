## The GTK 3 / GLib / cairo functions the GTK backend uses, declared by hand (as in webby's nim/src/gtk.nim): no
## binding package, just pkg-config for the flags.

{.passC: gorge("pkg-config --cflags gtk+-3.0").}
{.passL: gorge("pkg-config --libs gtk+-3.0").}

type
  GtkWidget* = pointer
  gboolean* = cint

const
  GTK_WINDOW_TOPLEVEL* = 0.cint
  GTK_ORIENTATION_HORIZONTAL* = 0.cint
  GTK_ORIENTATION_VERTICAL* = 1.cint
  GTK_POLICY_AUTOMATIC* = 1.cint
  GTK_POLICY_NEVER* = 2.cint
  GTK_POS_BOTTOM* = 3.cint
  CAIRO_FORMAT_ARGB32* = 0.cint
  GDK_POINTER_MOTION_MASK* = 1.cint shl 2
  GDK_BUTTON_PRESS_MASK* = 1.cint shl 8
  GDK_BUTTON_RELEASE_MASK* = 1.cint shl 9
  GDK_TOUCH_MASK* = 1.cint shl 22

{.push cdecl, importc.}
proc gtk_init(argc: ptr cint, argv: ptr cstringArray)
proc gtk_main*()
proc gtk_main_quit*()
proc gtk_window_new*(kind: cint): GtkWidget
proc gtk_window_set_title*(w: GtkWidget, title: cstring)
proc gtk_window_set_default_size*(w: GtkWidget, width, height: cint)
proc gtk_widget_show_all*(w: GtkWidget)
proc gtk_widget_destroy*(w: GtkWidget)
proc gtk_widget_set_sensitive*(w: GtkWidget, on: gboolean)
proc gtk_widget_set_hexpand*(w: GtkWidget, on: gboolean)
proc gtk_widget_set_vexpand*(w: GtkWidget, on: gboolean)
proc gtk_widget_set_size_request*(w: GtkWidget, width, height: cint)
proc gtk_widget_add_events*(w: GtkWidget, events: cint)
proc gtk_widget_queue_draw*(w: GtkWidget)
proc gtk_widget_get_allocated_width*(w: GtkWidget): cint
proc gtk_widget_get_allocated_height*(w: GtkWidget): cint
proc gtk_widget_grab_focus*(w: GtkWidget)
proc gtk_widget_set_can_focus*(w: GtkWidget, on: gboolean)
proc gtk_container_add*(c, w: GtkWidget)
proc gtk_container_remove*(c, w: GtkWidget)
proc gtk_container_set_border_width*(c: GtkWidget, width: cuint)
proc gtk_box_new*(orientation: cint, spacing: cint): GtkWidget
proc gtk_box_set_spacing*(b: GtkWidget, spacing: cint)
proc gtk_box_pack_start*(b, w: GtkWidget, expand, fill: gboolean, padding: cuint)
proc gtk_box_reorder_child*(b, w: GtkWidget, position: cint)
proc gtk_label_new*(text: cstring): GtkWidget
proc gtk_label_set_text*(l: GtkWidget, text: cstring)
proc gtk_label_set_xalign*(l: GtkWidget, x: cfloat)
proc gtk_label_set_line_wrap*(l: GtkWidget, on: gboolean)
proc gtk_button_new_with_label*(text: cstring): GtkWidget
proc gtk_button_set_label*(b: GtkWidget, text: cstring)
proc gtk_entry_new*(): GtkWidget
proc gtk_entry_set_text*(e: GtkWidget, text: cstring)
proc gtk_entry_get_text*(e: GtkWidget): cstring
proc gtk_entry_set_placeholder_text*(e: GtkWidget, text: cstring)
proc gtk_check_button_new_with_label*(text: cstring): GtkWidget
proc gtk_toggle_button_set_active*(b: GtkWidget, on: gboolean)
proc gtk_toggle_button_get_active*(b: GtkWidget): gboolean
proc gtk_scrolled_window_new*(h, v: pointer): GtkWidget
proc gtk_scrolled_window_set_policy*(s: GtkWidget, h, v: cint)
proc gtk_drawing_area_new*(): GtkWidget
proc gtk_scale_new_with_range*(orientation: cint, min, max, step: cdouble): GtkWidget
proc gtk_scale_set_draw_value*(s: GtkWidget, on: gboolean)
proc gtk_scale_add_mark*(s: GtkWidget, value: cdouble, position: cint, markup: cstring)
proc gtk_scale_clear_marks*(s: GtkWidget)
proc gtk_range_set_range*(r: GtkWidget, min, max: cdouble)
proc gtk_range_set_increments*(r: GtkWidget, step, page: cdouble)
proc gtk_range_set_value*(r: GtkWidget, value: cdouble)
proc gtk_range_get_value*(r: GtkWidget): cdouble
proc gtk_combo_box_text_new*(): GtkWidget
proc gtk_combo_box_text_append_text*(c: GtkWidget, text: cstring)
proc gtk_combo_box_text_remove_all*(c: GtkWidget)
proc gtk_combo_box_set_active*(c: GtkWidget, index: cint)
proc gtk_combo_box_get_active*(c: GtkWidget): cint
proc gtk_progress_bar_new*(): GtkWidget
proc gtk_progress_bar_set_fraction*(p: GtkWidget, fraction: cdouble)
proc gdk_event_get_coords*(e: pointer, x, y: ptr cdouble): gboolean
proc gdk_event_get_button*(e: pointer, button: ptr cuint): gboolean
proc g_signal_connect_data*(instance: pointer, signal: cstring, handler: pointer, data: pointer,
                            destroy: pointer, flags: cint): culong
proc g_timeout_add*(ms: cuint, fn: proc (data: pointer): gboolean {.cdecl.}, data: pointer): cuint
proc g_source_remove*(id: cuint): gboolean
proc g_object_ref*(o: pointer): pointer
proc g_object_unref*(o: pointer)
proc cairo_image_surface_create_for_data*(data: pointer, format: cint, width, height, stride: cint): pointer
proc cairo_set_source_surface*(cr, surface: pointer, x, y: cdouble)
proc cairo_paint*(cr: pointer)
proc cairo_surface_destroy*(s: pointer)
{.pop.}

proc connect*(instance: pointer, signal: string, handler: pointer, data: pointer) =
  discard g_signal_connect_data(instance, signal.cstring, handler, data, nil, 0)

proc gtkInit*() = gtk_init(nil, nil)
