## GTK 3 / GDK / GLib / cairo declarations for webby-nim. Widgets and events are opaque pointers; event fields
## are read through GDK's accessor functions. Add what a feature needs here, or declare it in the feature's own
## module (repeating a declaration in another module is fine).

{.passC: gorge("pkg-config --cflags gtk+-3.0").}
{.passL: gorge("pkg-config --libs gtk+-3.0").}

type
  Widget* = pointer
  GEvent* = pointer
  Cairo* = pointer
  gboolean* = cint

const
  GTK_WINDOW_TOPLEVEL* = 0.cint
  GTK_ORIENTATION_HORIZONTAL* = 0.cint
  GTK_ORIENTATION_VERTICAL* = 1.cint
  GTK_RELIEF_NONE* = 2.cint
  GTK_POLICY_ALWAYS* = 0.cint
  GTK_POLICY_AUTOMATIC* = 1.cint
  GTK_POLICY_NEVER* = 2.cint
  GTK_ALIGN_FILL* = 0.cint
  GTK_ALIGN_START* = 1.cint
  GTK_ALIGN_END* = 2.cint
  GTK_ALIGN_CENTER* = 3.cint
  GTK_ICON_SIZE_MENU* = 1.cint
  GTK_ICON_SIZE_SMALL_TOOLBAR* = 2.cint
  GTK_ICON_SIZE_BUTTON* = 4.cint
  PANGO_ELLIPSIZE_END* = 3.cint
  CAIRO_FORMAT_ARGB32* = 0.cint
  CAIRO_OPERATOR_SOURCE* = 1.cint
  GDK_POINTER_MOTION_MASK* = 1 shl 2
  GDK_BUTTON_PRESS_MASK* = 1 shl 8
  GDK_BUTTON_RELEASE_MASK* = 1 shl 9
  GDK_KEY_PRESS_MASK* = 1 shl 10
  GDK_KEY_RELEASE_MASK* = 1 shl 11
  GDK_LEAVE_NOTIFY_MASK* = 1 shl 13
  GDK_FOCUS_CHANGE_MASK* = 1 shl 14
  GDK_SCROLL_MASK* = 1 shl 21
  GDK_SMOOTH_SCROLL_MASK* = 1 shl 23
  GDK_SHIFT_MASK* = 1'u32
  GDK_CONTROL_MASK* = 1'u32 shl 2
  GDK_MOD1_MASK* = 1'u32 shl 3
  GDK_BUTTON1_MASK* = 1'u32 shl 8
  GDK_BUTTON2_MASK* = 1'u32 shl 9
  GDK_BUTTON3_MASK* = 1'u32 shl 10
  GDK_SUPER_MASK* = 1'u32 shl 26
  GDK_BUTTON_PRESS* = 4.cint
  GDK_2BUTTON_PRESS* = 5.cint
  GDK_3BUTTON_PRESS* = 6.cint
  GDK_SCROLL_UP* = 0.cint
  GDK_SCROLL_DOWN* = 1.cint
  GDK_SCROLL_LEFT* = 2.cint
  GDK_SCROLL_RIGHT* = 3.cint
  GTK_MESSAGE_INFO* = 0.cint
  GTK_MESSAGE_WARNING* = 1.cint
  GTK_MESSAGE_QUESTION* = 2.cint
  GTK_BUTTONS_NONE* = 0.cint
  GTK_BUTTONS_OK* = 1.cint
  GTK_BUTTONS_YES_NO* = 4.cint
  GTK_BUTTONS_OK_CANCEL* = 5.cint
  GTK_RESPONSE_NONE* = -1.cint
  GTK_RESPONSE_ACCEPT* = -3.cint
  GTK_RESPONSE_DELETE_EVENT* = -4.cint
  GTK_RESPONSE_OK* = -5.cint
  GTK_RESPONSE_CANCEL* = -6.cint
  GTK_RESPONSE_CLOSE* = -7.cint
  GTK_RESPONSE_YES* = -8.cint
  GTK_RESPONSE_NO* = -9.cint
  GTK_DIALOG_MODAL* = 1.cint
  GTK_DIALOG_DESTROY_WITH_PARENT* = 2.cint
  GTK_FILE_CHOOSER_ACTION_OPEN* = 0.cint
  GTK_FILE_CHOOSER_ACTION_SAVE* = 1.cint
  GTK_POS_LEFT* = 0.cint
  GTK_POS_RIGHT* = 1.cint
  GTK_POS_TOP* = 2.cint
  GTK_POS_BOTTOM* = 3.cint
  GTK_SELECTION_NONE* = 0.cint
  GTK_SELECTION_SINGLE* = 1.cint
  GTK_STYLE_PROVIDER_PRIORITY_APPLICATION* = 600.cuint

{.push cdecl, importc.}
# main loop, signals, memory
proc gtk_init*(argc: pointer, argv: pointer)
proc gtk_main*()
proc gtk_main_quit*()
proc gtk_events_pending*(): gboolean
proc gtk_main_iteration*(): gboolean
proc g_signal_connect_data*(instance: pointer, signal: cstring, handler, data, destroy: pointer, flags: cint): culong
proc g_signal_handler_block*(instance: pointer, id: culong)
proc g_signal_handler_unblock*(instance: pointer, id: culong)
proc g_timeout_add*(ms: cuint, fn, data: pointer): cuint
proc g_idle_add*(fn, data: pointer): cuint
proc g_source_remove*(id: cuint): gboolean
proc g_free*(p: pointer)
proc g_object_ref*(p: pointer): pointer
proc g_object_unref*(p: pointer)
proc g_object_set_data*(o: pointer, key: cstring, data: pointer)
proc g_object_get_data*(o: pointer, key: cstring): pointer
proc g_get_user_data_dir*(): cstring
proc g_get_user_config_dir*(): cstring

# windows and containers
proc gtk_window_new*(kind: cint): Widget
proc gtk_window_set_title*(w: Widget, title: cstring)
proc gtk_window_set_default_size*(w: Widget, width, height: cint)
proc gtk_window_set_transient_for*(w, parent: Widget)
proc gtk_window_set_modal*(w: Widget, modal: gboolean)
proc gtk_window_set_icon_name*(w: Widget, name: cstring)
proc gtk_window_set_icon_from_file*(w: Widget, file: cstring, err: pointer): gboolean
proc gtk_window_present*(w: Widget)
proc gtk_window_close*(w: Widget)
proc gtk_window_get_size*(w: Widget, width, height: ptr cint)
proc gtk_window_maximize*(w: Widget)
proc gtk_container_add*(c, w: Widget)
proc gtk_container_remove*(c, w: Widget)
proc gtk_container_get_children*(c: Widget): pointer   # GList*, free with g_list_free
proc gtk_container_set_border_width*(c: Widget, w: cuint)
proc g_list_free*(l: pointer)
proc gtk_box_new*(orientation, spacing: cint): Widget
proc gtk_box_pack_start*(box, child: Widget, expand, fill: gboolean, padding: cuint)
proc gtk_box_pack_end*(box, child: Widget, expand, fill: gboolean, padding: cuint)
proc gtk_box_reorder_child*(box, child: Widget, position: cint)
proc gtk_paned_new*(orientation: cint): Widget
proc gtk_paned_pack1*(p, child: Widget, resize, shrink: gboolean)
proc gtk_paned_pack2*(p, child: Widget, resize, shrink: gboolean)
proc gtk_paned_set_position*(p: Widget, pos: cint)
proc gtk_paned_get_position*(p: Widget): cint
proc gtk_scrolled_window_new*(h, v: pointer): Widget
proc gtk_scrolled_window_set_policy*(s: Widget, h, v: cint)
proc gtk_scrolled_window_set_min_content_width*(s: Widget, w: cint)
proc gtk_scrolled_window_set_min_content_height*(s: Widget, h: cint)
proc gtk_overlay_new*(): Widget
proc gtk_overlay_add_overlay*(o, w: Widget)
proc gtk_overlay_set_overlay_pass_through*(o, w: Widget, pass: gboolean)
proc gtk_grid_new*(): Widget
proc gtk_grid_attach*(g, child: Widget, left, top, width, height: cint)
proc gtk_grid_set_row_spacing*(g: Widget, s: cuint)
proc gtk_grid_set_column_spacing*(g: Widget, s: cuint)
proc gtk_stack_new*(): Widget
proc gtk_stack_add_named*(s, child: Widget, name: cstring)
proc gtk_stack_set_visible_child_name*(s: Widget, name: cstring)
proc gtk_separator_new*(orientation: cint): Widget
proc gtk_revealer_new*(): Widget
proc gtk_revealer_set_reveal_child*(r: Widget, reveal: gboolean)
proc gtk_frame_new*(label: cstring): Widget
proc gtk_event_box_new*(): Widget

# widgets
proc gtk_entry_new*(): Widget
proc gtk_entry_set_text*(e: Widget, text: cstring)
proc gtk_entry_get_text*(e: Widget): cstring
proc gtk_entry_set_placeholder_text*(e: Widget, text: cstring)
proc gtk_entry_set_visibility*(e: Widget, visible: gboolean)
proc gtk_entry_set_activates_default*(e: Widget, on: gboolean)
proc gtk_entry_set_width_chars*(e: Widget, n: cint)
proc gtk_editable_select_region*(e: Widget, start, stop: cint)
proc gtk_editable_set_position*(e: Widget, pos: cint)
proc gtk_search_entry_new*(): Widget
proc gtk_button_new*(): Widget
proc gtk_button_new_with_label*(label: cstring): Widget
proc gtk_button_new_from_icon_name*(name: cstring, size: cint): Widget
proc gtk_button_set_label*(b: Widget, label: cstring)
proc gtk_button_set_relief*(b: Widget, relief: cint)
proc gtk_button_set_image*(b, image: Widget)
proc gtk_button_get_image*(b: Widget): Widget
proc gtk_button_set_always_show_image*(b: Widget, on: gboolean)
proc gtk_toggle_button_new_with_label*(label: cstring): Widget
proc gtk_toggle_button_set_active*(b: Widget, on: gboolean)
proc gtk_toggle_button_get_active*(b: Widget): gboolean
proc gtk_check_button_new_with_label*(label: cstring): Widget
proc gtk_switch_new*(): Widget
proc gtk_switch_set_active*(s: Widget, on: gboolean)
proc gtk_switch_get_active*(s: Widget): gboolean
proc gtk_menu_button_new*(): Widget
proc gtk_menu_button_set_popup*(b, menu: Widget)
proc gtk_label_new*(text: cstring): Widget
proc gtk_label_set_text*(l: Widget, text: cstring)
proc gtk_label_set_markup*(l: Widget, markup: cstring)
proc gtk_label_get_text*(l: Widget): cstring
proc gtk_label_set_xalign*(l: Widget, x: cfloat)
proc gtk_label_set_ellipsize*(l: Widget, mode: cint)
proc gtk_label_set_width_chars*(l: Widget, n: cint)
proc gtk_label_set_max_width_chars*(l: Widget, n: cint)
proc gtk_label_set_line_wrap*(l: Widget, wrap: gboolean)
proc gtk_label_set_selectable*(l: Widget, on: gboolean)
proc g_markup_escape_text*(text: cstring, len: int): cstring   # g_free the result
proc gtk_bin_get_child*(b: Widget): Widget
proc gtk_image_new_from_icon_name*(name: cstring, size: cint): Widget
proc gtk_image_new_from_file*(file: cstring): Widget
proc gtk_image_new_from_pixbuf*(pixbuf: pointer): Widget
proc gtk_image_set_from_pixbuf*(image, pixbuf: pointer)
proc gtk_image_set_from_icon_name*(image: Widget, name: cstring, size: cint)
proc gdk_pixbuf_new_from_file_at_size*(file: cstring, w, h: cint, err: pointer): pointer
proc gdk_pixbuf_new_from_data*(data: pointer, colorspace: cint, alpha: gboolean, bits, w, h, stride: cint,
                              destroy, destroyData: pointer): pointer
proc gdk_pixbuf_scale_simple*(src: pointer, w, h: cint, interp: cint): pointer
proc gtk_drawing_area_new*(): Widget
proc gtk_text_view_new*(): Widget
proc gtk_text_view_get_buffer*(v: Widget): pointer
proc gtk_text_view_set_wrap_mode*(v: Widget, mode: cint)
proc gtk_text_view_set_editable*(v: Widget, on: gboolean)
proc gtk_text_view_set_cursor_visible*(v: Widget, on: gboolean)
proc gtk_text_view_set_left_margin*(v: Widget, m: cint)
proc gtk_text_view_set_right_margin*(v: Widget, m: cint)
proc gtk_text_buffer_set_text*(b: pointer, text: cstring, len: cint)
proc gtk_text_buffer_get_end_iter*(b: pointer, iter: pointer)
proc gtk_text_buffer_insert*(b: pointer, iter: pointer, text: cstring, len: cint)
proc gtk_text_buffer_insert_markup*(b: pointer, iter: pointer, markup: cstring, len: cint)
proc gtk_spinner_new*(): Widget
proc gtk_spinner_start*(s: Widget)
proc gtk_spinner_stop*(s: Widget)
proc gtk_progress_bar_new*(): Widget
proc gtk_progress_bar_set_fraction*(p: Widget, f: cdouble)
proc gtk_progress_bar_pulse*(p: Widget)

# list box
proc gtk_list_box_new*(): Widget
proc gtk_list_box_insert*(l, child: Widget, pos: cint)
proc gtk_list_box_set_selection_mode*(l: Widget, mode: cint)
proc gtk_list_box_row_new*(): Widget
proc gtk_list_box_get_row_at_index*(l: Widget, i: cint): Widget
proc gtk_list_box_row_get_index*(r: Widget): cint
proc gtk_list_box_select_row*(l, row: Widget)
proc gtk_list_box_get_selected_row*(l: Widget): Widget

# menus and popovers
proc gtk_menu_new*(): Widget
proc gtk_menu_item_new_with_label*(label: cstring): Widget
proc gtk_menu_item_set_submenu*(item, menu: Widget)
proc gtk_check_menu_item_new_with_label*(label: cstring): Widget
proc gtk_check_menu_item_set_active*(item: Widget, on: gboolean)
proc gtk_check_menu_item_get_active*(item: Widget): gboolean
proc gtk_separator_menu_item_new*(): Widget
proc gtk_menu_shell_append*(m, item: Widget)
proc gtk_menu_popup_at_pointer*(m: Widget, event: GEvent)
proc gtk_menu_popup_at_widget*(m, w: Widget, wAnchor, mAnchor: cint, event: GEvent)
proc gtk_menu_attach_to_widget*(m, w: Widget, detach: pointer)
proc gtk_popover_new*(relative: Widget): Widget
proc gtk_popover_popup*(p: Widget)
proc gtk_popover_popdown*(p: Widget)
proc gtk_popover_set_position*(p: Widget, pos: cint)
proc gtk_popover_set_pointing_to*(p: Widget, rect: pointer)

# dialogs
proc gtk_message_dialog_new*(parent: Widget, flags, kind, buttons: cint, fmt: cstring): Widget {.varargs.}
proc gtk_message_dialog_format_secondary_text*(d: Widget, fmt: cstring) {.varargs.}
proc gtk_dialog_new_with_buttons*(title: cstring, parent: Widget, flags: cint, first: cstring): Widget {.varargs.}
proc gtk_dialog_get_content_area*(d: Widget): Widget
proc gtk_dialog_add_button*(d: Widget, text: cstring, response: cint): Widget
proc gtk_dialog_set_default_response*(d: Widget, response: cint)
proc gtk_dialog_run*(d: Widget): cint
proc gtk_file_chooser_dialog_new*(title: cstring, parent: Widget, action: cint, first: cstring): Widget {.varargs.}
proc gtk_file_chooser_set_select_multiple*(c: Widget, on: gboolean)
proc gtk_file_chooser_get_filename*(c: Widget): cstring          # g_free
proc gtk_file_chooser_get_filenames*(c: Widget): pointer          # GSList* of g_free'd strings
proc gtk_file_chooser_set_current_name*(c: Widget, name: cstring)
proc gtk_file_chooser_set_do_overwrite_confirmation*(c: Widget, on: gboolean)
proc gtk_file_chooser_add_filter*(c: Widget, filter: pointer)
proc gtk_file_filter_new*(): pointer
proc gtk_file_filter_set_name*(f: pointer, name: cstring)
proc gtk_file_filter_add_pattern*(f: pointer, pattern: cstring)
proc gtk_file_filter_add_mime_type*(f: pointer, mime: cstring)
proc g_slist_free*(l: pointer)

# widget basics
proc gtk_widget_add_events*(w: Widget, events: cint)
proc gtk_widget_set_can_focus*(w: Widget, can: gboolean)
proc gtk_widget_grab_focus*(w: Widget)
proc gtk_widget_has_focus*(w: Widget): gboolean
proc gtk_widget_set_sensitive*(w: Widget, on: gboolean)
proc gtk_widget_show*(w: Widget)
proc gtk_widget_show_all*(w: Widget)
proc gtk_widget_hide*(w: Widget)
proc gtk_widget_set_visible*(w: Widget, on: gboolean)
proc gtk_widget_get_visible*(w: Widget): gboolean
proc gtk_widget_set_no_show_all*(w: Widget, on: gboolean)
proc gtk_widget_destroy*(w: Widget)
proc gtk_widget_queue_draw*(w: Widget)
proc gtk_widget_get_allocated_width*(w: Widget): cint
proc gtk_widget_get_allocated_height*(w: Widget): cint
proc gtk_widget_get_scale_factor*(w: Widget): cint
proc gtk_widget_get_window*(w: Widget): pointer
proc gtk_widget_get_toplevel*(w: Widget): Widget
proc gtk_widget_get_display*(w: Widget): pointer
proc gtk_widget_get_style_context*(w: Widget): pointer
proc gtk_widget_set_tooltip_text*(w: Widget, text: cstring)
proc gtk_widget_set_size_request*(w: Widget, width, height: cint)
proc gtk_widget_set_halign*(w: Widget, a: cint)
proc gtk_widget_set_valign*(w: Widget, a: cint)
proc gtk_widget_set_hexpand*(w: Widget, on: gboolean)
proc gtk_widget_set_vexpand*(w: Widget, on: gboolean)
proc gtk_widget_set_margin_start*(w: Widget, m: cint)
proc gtk_widget_set_margin_end*(w: Widget, m: cint)
proc gtk_widget_set_margin_top*(w: Widget, m: cint)
proc gtk_widget_set_margin_bottom*(w: Widget, m: cint)
proc gtk_widget_set_name*(w: Widget, name: cstring)
proc gtk_widget_translate_coordinates*(src, dest: Widget, x, y: cint, dx, dy: ptr cint): gboolean
proc gtk_style_context_add_class*(c: pointer, name: cstring)
proc gtk_style_context_remove_class*(c: pointer, name: cstring)
proc gtk_css_provider_new*(): pointer
proc gtk_css_provider_load_from_data*(p: pointer, data: cstring, len: int, err: pointer): gboolean
proc gtk_style_context_add_provider_for_screen*(screen, provider: pointer, priority: cuint)
proc gdk_screen_get_default*(): pointer
proc gtk_settings_get_default*(): pointer
proc g_object_get*(o: pointer, first: cstring) {.varargs.}
proc g_object_set*(o: pointer, first: cstring) {.varargs.}

# clipboard, cursors, events
proc gtk_clipboard_get*(selection: pointer): pointer
proc gtk_clipboard_set_text*(cb: pointer, text: cstring, len: cint)
proc gtk_clipboard_wait_for_text*(cb: pointer): cstring
proc gtk_clipboard_request_contents*(cb, target: pointer, callback, data: pointer)  # (cb, GtkSelectionData*, data)
proc gtk_clipboard_request_image*(cb: pointer, callback, data: pointer)            # (cb, GdkPixbuf* or nil, data)
proc gtk_selection_data_get_data*(sd: pointer): pointer
proc gtk_selection_data_get_length*(sd: pointer): cint
proc gdk_pixbuf_save_to_buffer*(pb: pointer, buf: ptr pointer, size: ptr csize_t, kind: cstring, err: pointer): gboolean {.varargs.}  # g_free buf
proc gdk_atom_intern*(name: cstring, onlyIfExists: gboolean): pointer
proc gdk_window_set_cursor*(w, cursor: pointer)
proc gdk_cursor_new_from_name*(display: pointer, name: cstring): pointer
proc gdk_event_get_event_type*(e: GEvent): cint
proc gdk_event_get_coords*(e: GEvent, x, y: ptr cdouble): gboolean
proc gdk_event_get_root_coords*(e: GEvent, x, y: ptr cdouble): gboolean
proc gdk_event_get_button*(e: GEvent, button: ptr cuint): gboolean
proc gdk_event_get_state*(e: GEvent, state: ptr uint32): gboolean
proc gdk_event_get_time*(e: GEvent): uint32
proc gdk_event_get_scroll_direction*(e: GEvent, dir: ptr cint): gboolean
proc gdk_event_get_scroll_deltas*(e: GEvent, dx, dy: ptr cdouble): gboolean
proc gdk_event_get_keyval*(e: GEvent, keyval: ptr cuint): gboolean
proc gdk_keyval_to_unicode*(keyval: cuint): uint32
proc gtk_get_current_event*(): GEvent
proc gdk_event_free*(e: GEvent)

# cairo
proc cairo_image_surface_create_for_data*(data: pointer, format, width, height, stride: cint): pointer
proc cairo_surface_destroy*(s: pointer)
proc cairo_set_source_surface*(cr: Cairo, s: pointer, x, y: cdouble)
proc cairo_set_source_rgb*(cr: Cairo, r, g, b: cdouble)
proc cairo_set_operator*(cr: Cairo, op: cint)
proc cairo_scale*(cr: Cairo, sx, sy: cdouble)
proc cairo_paint*(cr: Cairo)
proc cairo_rectangle*(cr: Cairo, x, y, w, h: cdouble)
proc cairo_fill*(cr: Cairo)
{.pop.}

# --- small helpers -------------------------------------------------------------------------------------------

proc connect*(w: pointer, signal: string, handler: pointer, data: pointer = nil): culong {.discardable.} =
  g_signal_connect_data(w, signal.cstring, handler, data, nil, 0)

proc addClass*(w: Widget, name: string) = gtk_style_context_add_class(gtk_widget_get_style_context(w), name.cstring)
proc removeClass*(w: Widget, name: string) =
  gtk_style_context_remove_class(gtk_widget_get_style_context(w), name.cstring)

proc escapeMarkup*(s: string): string =
  let p = g_markup_escape_text(s.cstring, s.len)
  result = $p
  g_free(p)

proc children*(container: Widget): seq[Widget] =
  ## The container's children (GList walked by hand: data, next, prev).
  type GList = object
    data: pointer
    next, prev: ptr GList
  let list = cast[ptr GList](gtk_container_get_children(container))
  var node = list
  while node != nil:
    result.add node.data
    node = node.next
  g_list_free(list)

proc clearChildren*(container: Widget) =
  for c in children(container): gtk_widget_destroy(c)

proc fileChooserFilenames*(chooser: Widget): seq[string] =
  type GSList = object
    data: pointer
    next: ptr GSList
  let list = cast[ptr GSList](gtk_file_chooser_get_filenames(chooser))
  var node = list
  while node != nil:
    result.add $cast[cstring](node.data)
    g_free(node.data)
    node = node.next
  g_slist_free(list)

proc systemClipboard*(): pointer = gtk_clipboard_get(gdk_atom_intern("CLIPBOARD", 0))

proc loadCss*(css: string) =
  let p = gtk_css_provider_new()
  discard gtk_css_provider_load_from_data(p, css.cstring, css.len, nil)
  gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), p, GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
