import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flatkit/flatkit.dart';
import 'package:flutter/material.dart';

/// Incognito windows: a separate webby process (`webby --incognito [url]`) whose Ladybird keeps nothing on disk.
///
/// Ladybird's cookie jar, storage, caches and RequestServer belong to the process, so an incognito window runs its own
/// engine with a temporary profile (deleted on exit), the SQL database off (cookies, localStorage and IndexedDB stay in
/// memory) and no HTTP disk cache. The app side skips everything that writes: no password or passkey saving, no
/// bookmarking, no sync, no tabs published to other devices, no web app installs.
class Incognito {
  Incognito._();

  /// Whether this process is an incognito window.
  static bool active = false;

  /// The command-line flag that starts an incognito window.
  static const flag = '--incognito';

  /// Ladybird flags for an engine that forgets everything when the window closes.
  static const engineFlags = ['--temporary-profile', '--disable-sql-database', '--disable-http-disk-cache'];

  /// Turns this process into an incognito window. Must run before Ladybird starts (WebbyBindings.open), since
  /// webby_init reads its flags from $WEBBY_LADYBIRD_ARGS.
  static void enable() {
    active = true;
    final args = ladybirdArgs(Platform.environment['WEBBY_LADYBIRD_ARGS'] ?? '');
    final name = 'WEBBY_LADYBIRD_ARGS'.toNativeUtf8();
    final value = args.toNativeUtf8();
    try {
      final setenv = DynamicLibrary.process()
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('setenv');
      setenv(name, value, 1);
    } finally {
      malloc.free(name);
      malloc.free(value);
    }
  }

  /// [existing] Ladybird flags with any profile choice swapped for [engineFlags].
  static String ladybirdArgs(String existing) {
    final kept = <String>[];
    final words = existing.split(' ').where((w) => w.isNotEmpty).toList();
    for (var i = 0; i < words.length; i++) {
      final word = words[i];
      if (word == '--profile' || word == '--profile-path') {
        i++; // and its value
        continue;
      }
      if (word.startsWith('--profile=') ||
          word.startsWith('--profile-path=') ||
          word == '--force-new-process' ||
          engineFlags.contains(word)) {
        continue;
      }
      kept.add(word);
    }
    return [...kept, ...engineFlags].join(' ');
  }

  /// Incognito windows' own dark look, whatever the desktop theme, so they can't be mistaken for normal ones.
  static const colors = KitColors(
    brightness: Brightness.dark,
    background: Color(0xFF202124),
    surface: Color(0xFF35363A),
    hover: Color(0xFF45464B),
    pressed: Color(0xFF515257),
    border: Color(0xFF4A4B50),
    borderStrong: Color(0xFF65666C),
    text: Color(0xFFE8EAED),
    textDim: Color(0xFFA8ABB0),
    accent: Color(0xFFA990F0),
    accentHover: Color(0xFFB8A3F4),
    accentPressed: Color(0xFF9479E2),
    onAccent: Color(0xFF1B1530),
    danger: Color(0xFFE5484D),
    dangerHover: Color(0xFFEC5F63),
    onDanger: Color(0xFFFFFFFF),
    success: Color(0xFF3DBE7F),
    focus: Color(0xFFA990F0),
    shadow: Color(0x66000000),
  );
}

/// The badge at the start of an incognito window's toolbar.
class IncognitoBadge extends StatelessWidget {
  const IncognitoBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return KitTooltip(
      message: 'Incognito: cookies, site data, cache and permissions are forgotten when this window closes',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.accent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(kitRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_outlined, size: 15, color: c.accent),
            const SizedBox(width: 5),
            Text('Incognito', style: KitText.small(context, color: c.accent)),
          ],
        ),
      ),
    );
  }
}

/// What an incognito window shows on a blank tab.
class IncognitoNewTab extends StatelessWidget {
  const IncognitoNewTab({super.key});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return ColoredBox(
      color: c.background,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.visibility_off_outlined, size: 56, color: c.textDim),
                const SizedBox(height: 16),
                Text("You've gone incognito", style: KitText.heading(context)),
                const SizedBox(height: 12),
                Text(
                  "Pages you open in this window won't be remembered. Cookies, site data, cached files and site "
                  'permissions live only in memory and are gone when you close the window. Webby won\'t offer to save '
                  "passwords or bookmarks here, and these tabs aren't shared with your other devices.\n\n"
                  'Downloads you save stay on disk, and the sites you visit, your network and your employer can still '
                  'see your activity.',
                  textAlign: TextAlign.center,
                  style: KitText.dim(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
