// Pages' alert(), confirm() and prompt() (see webby_view_dialog in webby_ffi.h).

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

import 'bindings.dart';
import 'site_settings.dart';
import 'ui.dart';
import 'web_view.dart';

class PageDialog {
  const PageDialog({required this.id, required this.type, required this.message, this.defaultText = ''});

  factory PageDialog.fromJson(Map<String, Object?> json) => PageDialog(
        id: (json['id'] as num?)?.toInt() ?? 0,
        type: json['type'] as String? ?? 'alert',
        message: json['message'] as String? ?? '',
        defaultText: json['default'] as String? ?? '',
      );

  final int id;

  /// "alert", "confirm" or "prompt".
  final String type;
  final String message;
  final String defaultText;
}

/// The native side of page dialogs; null with a runtime that predates them (dialogs then hang the page, as before).
class PageDialogs {
  PageDialogs._(this._dialog, this._respond);

  static PageDialogs? of(WebbyBindings bindings) {
    final lib = bindings.library;
    if (!lib.providesSymbol('webby_view_dialog')) return null;
    return PageDialogs._(
      lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>('webby_view_dialog'),
      lib.lookupFunction<Void Function(ViewPtr, Uint64, Int32, Pointer<Utf8>), void Function(ViewPtr, int, int, Pointer<Utf8>)>(
          'webby_view_dialog_respond'),
    );
  }

  final Pointer<Utf8> Function(ViewPtr) _dialog;
  final void Function(ViewPtr, int, int, Pointer<Utf8>) _respond;
  String _json = '';
  PageDialog? current;

  /// Call when the view's state changes; returns whether [current] changed.
  bool check(ViewPtr view) {
    final json = _dialog(view).toDartString();
    if (json == _json) return false;
    _json = json;
    current = json.isEmpty ? null : PageDialog.fromJson(jsonDecode(json) as Map<String, Object?>);
    return true;
  }

  void respond(ViewPtr view, int id, {required bool accepted, String? text}) {
    final s = text?.toNativeUtf8() ?? nullptr;
    try {
      _respond(view, id, accepted ? 1 : 0, s);
    } finally {
      if (s != nullptr) malloc.free(s);
    }
  }

  void reset() {
    _json = '';
    current = null;
  }
}

/// Shows [dialog] for [controller]'s page, Chrome style ("example.com says"), and answers it when closed.
Future<void> showPageDialog(BuildContext context, WebbyController controller, PageDialog dialog) async {
  var answered = false;
  final field = TextEditingController(text: dialog.defaultText);
  void answer(BuildContext dialogContext, bool accepted) {
    if (answered) return;
    answered = true;
    controller.respondToDialog(dialog.id, accepted: accepted, text: dialog.type == 'prompt' ? field.text : null);
    Navigator.of(dialogContext).pop();
  }

  final uri = Uri.tryParse(controller.url);
  final site = uri != null && uri.hasAuthority ? siteName(uri.origin) : 'This page';
  await showWebbyDialog<void>(context, (dialogContext) => KitDialog(
        title: '$site says',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (dialog.message.isNotEmpty) SelectableText(dialog.message),
            if (dialog.type == 'prompt') ...[
              const SizedBox(height: 10),
              KitTextField(controller: field, autofocus: true, onSubmitted: (_) => answer(dialogContext, true)),
            ],
          ],
        ),
        actions: [
          if (dialog.type != 'alert') KitButton('Cancel', onPressed: () => answer(dialogContext, false)),
          KitButton.primary('OK', autofocus: dialog.type != 'prompt', onPressed: () => answer(dialogContext, true)),
        ],
      ));
  // Closed some other way (Esc, a tap outside): that's Cancel.
  if (!answered) controller.respondToDialog(dialog.id, accepted: false);
  field.dispose();
}
