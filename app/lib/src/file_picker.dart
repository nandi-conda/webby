// Pages' <input type=file> pickers, answered with the system file chooser (see webby_view_file_picker_request in
// webby_ffi.h).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'bindings.dart';

class PageFilePicker {
  PageFilePicker._(this._request, this._respond);

  /// Null with a runtime that predates file pickers; pages' pickers then do nothing, as before.
  static PageFilePicker? of(WebbyBindings bindings) {
    final lib = bindings.library;
    if (!lib.providesSymbol('webby_view_file_picker_request')) return null;
    return PageFilePicker._(
      lib.lookupFunction<Pointer<Utf8> Function(ViewPtr), Pointer<Utf8> Function(ViewPtr)>(
          'webby_view_file_picker_request'),
      lib.lookupFunction<Void Function(ViewPtr, Pointer<Utf8>), void Function(ViewPtr, Pointer<Utf8>)>(
          'webby_view_file_picker_respond'),
    );
  }

  final Pointer<Utf8> Function(ViewPtr) _request;
  final void Function(ViewPtr, Pointer<Utf8>) _respond;
  ViewPtr _shownView = nullptr;
  String _shown = '';

  /// Call when the view's state changes: opens the chooser when the page asked for one. [currentView] gives the view
  /// to answer once the chooser closes (it may have been discarded meanwhile).
  void check(ViewPtr view, ViewPtr Function() currentView) {
    final json = _request(view).toDartString();
    // A recreated view (a discarded tab coming back) numbers its requests afresh.
    if (view != _shownView) {
      _shownView = view;
      _shown = '';
    }
    if (json == _shown) return;
    _shown = json;
    if (json.isEmpty) return;
    _pick(jsonDecode(json) as Map<String, Object?>).then((paths) async {
      final target = currentView();
      if (target == view && _request(view).toDartString() == json) {
        final encoded = jsonEncode(paths);
        final s = encoded.toNativeUtf8();
        try {
          _respond(view, s);
        } finally {
          malloc.free(s);
        }
      }
      // The native side holds the files open now, so Android's copies in the app cache can go.
      if (Platform.isAndroid && paths.isNotEmpty) {
        try {
          await FilePicker.clearTemporaryFiles();
        } catch (_) {}
      }
    });
  }

  static Future<List<String>> _pick(Map<String, Object?> request) async {
    final accept = (request['accept'] as List? ?? const []).whereType<String>().map((a) => a.toLowerCase()).toList();
    var type = FileType.any;
    List<String>? extensions;
    if (accept.isNotEmpty && accept.every((a) => a.startsWith('.'))) {
      type = FileType.custom;
      extensions = [for (final a in accept) a.substring(1)];
    } else if (accept.isNotEmpty && accept.every((a) => a.startsWith('image/'))) {
      type = FileType.image;
    } else if (accept.isNotEmpty && accept.every((a) => a.startsWith('video/'))) {
      type = FileType.video;
    } else if (accept.isNotEmpty && accept.every((a) => a.startsWith('audio/'))) {
      type = FileType.audio;
    } else if (accept.isNotEmpty && accept.every((a) => a.startsWith('image/') || a.startsWith('video/'))) {
      type = FileType.media;
    }
    try {
      final result = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: extensions,
        allowMultiple: request['multiple'] == true,
        lockParentWindow: true,
      );
      return [for (final file in result?.files ?? const <PlatformFile>[]) if (file.path != null) file.path!];
    } catch (error) {
      debugPrint('webby: file chooser failed: $error');
      return const [];
    }
  }
}
