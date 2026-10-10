import 'package:flutter/services.dart';

/// Modifier bits as Ladybird defines them (Web::UIEvents::KeyModifier).
const int modAlt = 1, modCtrl = 2, modShift = 4, modSuper = 8;

int modifiersFromKeyboard(HardwareKeyboard keyboard) {
  var result = 0;
  if (keyboard.isAltPressed) result |= modAlt;
  if (keyboard.isControlPressed) result |= modCtrl;
  if (keyboard.isShiftPressed) result |= modShift;
  if (keyboard.isMetaPressed) result |= modSuper;
  return result;
}

class LadybirdKey {
  const LadybirdKey(this.keyCode, this.codePoint);
  final int keyCode;
  final int codePoint;
}

// Web::UIEvents::KeyCode values for keys that are not letters or digits.
final Map<LogicalKeyboardKey, int> _special = {
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.tab: 0x09,
  LogicalKeyboardKey.enter: 0x0D,
  LogicalKeyboardKey.numpadEnter: 0x0D,
  LogicalKeyboardKey.shiftLeft: 0x10,
  LogicalKeyboardKey.shiftRight: 0xB0,
  LogicalKeyboardKey.controlLeft: 0x11,
  LogicalKeyboardKey.controlRight: 0xB1,
  LogicalKeyboardKey.altLeft: 0x12,
  LogicalKeyboardKey.altRight: 0xB2,
  LogicalKeyboardKey.capsLock: 0x14,
  LogicalKeyboardKey.escape: 0x1B,
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.delete: 0x2E,
  LogicalKeyboardKey.insert: 0x7E,
  LogicalKeyboardKey.f1: 0x70,
  LogicalKeyboardKey.f2: 0x71,
  LogicalKeyboardKey.f3: 0x72,
  LogicalKeyboardKey.f4: 0x73,
  LogicalKeyboardKey.f5: 0x74,
  LogicalKeyboardKey.f6: 0x75,
  LogicalKeyboardKey.f7: 0x76,
  LogicalKeyboardKey.f8: 0x77,
  LogicalKeyboardKey.f9: 0x78,
  LogicalKeyboardKey.f10: 0x79,
  LogicalKeyboardKey.f11: 0x7A,
  LogicalKeyboardKey.f12: 0x7B,
  LogicalKeyboardKey.metaLeft: 0x92,
  LogicalKeyboardKey.metaRight: 0xAC,
};

const Map<String, int> _punctuation = {
  ')': 0x60, '!': 0x61, '@': 0x62, '#': 0x63, r'$': 0x64, '%': 0x65, '^': 0x66, '&': 0x67, '*': 0x68,
  '(': 0x69, '+': 0x6A, '-': 0x6B, '/': 0x6C, ',': 0x6D, '.': 0x6E, ':': 0x6F, '"': 0x7C, "'": 0x7D,
  ';': 0x7F, '<': 0x80, '=': 0x81, '>': 0x82, '?': 0x83, '[': 0x84, ']': 0x85, r'\': 0x86, '_': 0x87,
  '{': 0x88, '}': 0x89, '|': 0x8A, '~': 0x8B, '`': 0x8C,
};

/// Maps a Flutter key event to a Ladybird key code plus the text it types, or null if it means nothing to a page.
LadybirdKey? ladybirdKeyFor(KeyEvent event) {
  final logical = event.logicalKey;
  final character = event.character;
  var codePoint = 0;
  if (character != null && character.isNotEmpty) {
    final rune = character.runes.first;
    // Control characters are carried by the key code; only printable text is typed.
    if (rune >= 0x20 && rune != 0x7F) codePoint = rune;
  }
  if (logical == LogicalKeyboardKey.enter || logical == LogicalKeyboardKey.numpadEnter) {
    codePoint = event is KeyUpEvent ? 0 : 0x0A;
  }

  final special = _special[logical];
  if (special != null) return LadybirdKey(special, codePoint);

  final label = logical.keyLabel;
  if (label.length == 1) {
    final unit = label.toUpperCase().codeUnitAt(0);
    if ((unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A)) return LadybirdKey(unit, codePoint);
    final punctuation = _punctuation[label];
    if (punctuation != null) return LadybirdKey(punctuation, codePoint);
  }

  if (codePoint != 0) return LadybirdKey(0, codePoint);
  return null;
}
