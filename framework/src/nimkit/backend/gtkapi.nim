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
  GDK_KEY_PRESS_MASK* = 1.cint shl 10
  GDK_KEY_RELEASE_MASK* = 1.cint shl 11
  GDK_LEAVE_NOTIFY_MASK* = 1.cint shl 13
  GDK_FOCUS_CHANGE_MASK* = 1.cint shl 14
  GDK_SCROLL_MASK* = 1.cint shl 21
  GDK_SMOOTH_SCROLL_MASK* = 1.cint shl 23
  GDK_SHIFT_MASK* = 1'u32
  GDK_CONTROL_MASK* = 1'u32 shl 2
  GDK_MOD1_MASK* = 1'u32 shl 3
  GDK_BUTTON1_MASK* = 1'u32 shl 8
  GDK_BUTTON2_MASK* = 1'u32 shl 9
  GDK_BUTTON3_MASK* = 1'u32 shl 10
  GDK_SUPER_MASK* = 1'u32 shl 26
  GDK_BUTTON_PRESS* = 4.cint
  GDK_SCROLL_UP* = 0.cint
  GDK_SCROLL_DOWN* = 1.cint
  GDK_SCROLL_LEFT* = 2.cint
  GDK_SCROLL_RIGHT* = 3.cint
  CAIRO_OPERATOR_SOURCE* = 1.cint

const
  GTK_RELIEF_NONE* = 2.cint
  GTK_DIALOG_MODAL* = 1.cint
  GTK_DIALOG_DESTROY_WITH_PARENT* = 2.cint
  GDK_GRAVITY_NORTH_WEST* = 1.cint
  GDK_GRAVITY_SOUTH_WEST* = 7.cint
  GTK_STYLE_PROVIDER_PRIORITY_APPLICATION* = 600.cuint

type
  GdkRectangle* {.bycopy.} = object
    x*, y*, width*, height*: cint
  GdkRGBA* {.bycopy.} = object
    r*, g*, b*, a*: cdouble

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
proc gtk_toggle_button_new_with_label*(text: cstring): GtkWidget
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
proc gdk_event_get_state*(e: pointer, state: ptr uint32): gboolean
proc gdk_event_get_event_type*(e: pointer): cint
proc gdk_event_get_time*(e: pointer): uint32
proc gdk_event_get_scroll_deltas*(e: pointer, dx, dy: ptr cdouble): gboolean
proc gdk_event_get_scroll_direction*(e: pointer, dir: ptr cint): gboolean
proc gdk_event_get_keyval*(e: pointer, keyval: ptr cuint): gboolean
proc gdk_keyval_to_unicode*(keyval: cuint): uint32
proc gtk_widget_get_scale_factor*(w: GtkWidget): cint
proc cairo_scale*(cr: pointer, sx, sy: cdouble)
proc cairo_set_operator*(cr: pointer, op: cint)
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
proc gtk_widget_show*(w: GtkWidget)
proc gtk_box_pack_end*(b, w: GtkWidget, expand, fill: gboolean, padding: cuint)
proc gtk_button_new*(): GtkWidget
proc gtk_widget_set_visible*(w: GtkWidget, on: gboolean)
proc gtk_widget_set_no_show_all*(w: GtkWidget, on: gboolean)
proc gtk_widget_set_tooltip_text*(w: GtkWidget, text: cstring)
proc gtk_widget_get_style_context*(w: GtkWidget): pointer
proc gtk_widget_get_toplevel*(w: GtkWidget): GtkWidget
proc gtk_widget_get_window*(w: GtkWidget): pointer
proc gtk_widget_get_screen*(w: GtkWidget): pointer
proc gtk_widget_translate_coordinates*(src, dest: GtkWidget, x, y: cint, dx, dy: ptr cint): gboolean
proc gtk_widget_set_halign*(w: GtkWidget, align: cint)
proc gtk_widget_set_valign*(w: GtkWidget, align: cint)
proc gtk_widget_queue_resize*(w: GtkWidget)
proc gtk_style_context_add_class*(c: pointer, name: cstring)
proc gtk_style_context_remove_class*(c: pointer, name: cstring)
proc gtk_style_context_get_state*(c: pointer): cint
proc gtk_style_context_get_color*(c: pointer, state: cint, color: ptr GdkRGBA)
proc gtk_css_provider_new*(): pointer
proc gtk_css_provider_load_from_data*(p: pointer, data: cstring, len: int, err: pointer): gboolean
proc gtk_style_context_add_provider_for_screen*(screen, provider: pointer, priority: cuint)
proc gdk_screen_get_default*(): pointer
proc gtk_button_set_relief*(b: GtkWidget, relief: cint)
proc gtk_button_set_image*(b, image: GtkWidget)
proc gtk_button_set_always_show_image*(b: GtkWidget, on: gboolean)
proc gtk_bin_get_child*(b: GtkWidget): GtkWidget
proc gtk_separator_new*(orientation: cint): GtkWidget
proc gtk_entry_set_visibility*(e: GtkWidget, visible: gboolean)
proc gtk_editable_select_region*(e: GtkWidget, start, stop: cint)
proc gtk_label_set_use_markup*(l: GtkWidget, on: gboolean)
proc gtk_label_set_markup*(l: GtkWidget, text: cstring)
proc gtk_menu_new*(): GtkWidget
proc gtk_menu_item_new*(): GtkWidget
proc gtk_menu_item_set_submenu*(item, menu: GtkWidget)
proc gtk_check_menu_item_new*(): GtkWidget
proc gtk_check_menu_item_set_active*(item: GtkWidget, on: gboolean)
proc gtk_separator_menu_item_new*(): GtkWidget
proc gtk_menu_shell_append*(m, item: GtkWidget)
proc gtk_menu_popup_at_pointer*(m: GtkWidget, event: pointer)
proc gtk_menu_popup_at_widget*(m, w: GtkWidget, wAnchor, mAnchor: cint, event: pointer)
proc gtk_menu_popup_at_rect*(m: GtkWidget, window: pointer, rect: ptr GdkRectangle, rAnchor, mAnchor: cint,
                             event: pointer)
proc gtk_menu_attach_to_widget*(m, w: GtkWidget, detach: pointer)
proc gtk_get_current_event*(): pointer
proc gdk_event_free*(e: pointer)
proc gtk_dialog_new*(): GtkWidget
proc gtk_dialog_get_content_area*(d: GtkWidget): GtkWidget
proc gtk_dialog_add_button*(d: GtkWidget, text: cstring, response: cint): GtkWidget
proc gtk_dialog_set_default_response*(d: GtkWidget, response: cint)
proc gtk_window_set_transient_for*(w, parent: GtkWidget)
proc gtk_window_set_modal*(w: GtkWidget, on: gboolean)
proc gtk_window_set_destroy_with_parent*(w: GtkWidget, on: gboolean)
proc gtk_window_set_resizable*(w: GtkWidget, on: gboolean)
proc g_idle_add*(fn: proc (data: pointer): gboolean {.cdecl.}, data: pointer): cuint
proc cairo_save*(cr: pointer)
proc cairo_restore*(cr: pointer)
proc cairo_translate*(cr: pointer, x, y: cdouble)
proc cairo_set_source_rgba*(cr: pointer, r, g, b, a: cdouble)
proc cairo_new_path*(cr: pointer)
proc cairo_move_to*(cr: pointer, x, y: cdouble)
proc cairo_line_to*(cr: pointer, x, y: cdouble)
proc cairo_curve_to*(cr: pointer, x1, y1, x2, y2, x3, y3: cdouble)
proc cairo_close_path*(cr: pointer)
proc cairo_fill*(cr: pointer)
{.pop.}

proc connect*(instance: pointer, signal: string, handler: pointer, data: pointer) =
  discard g_signal_connect_data(instance, signal.cstring, handler, data, nil, 0)

proc gtkInit*() = gtk_init(nil, nil)
