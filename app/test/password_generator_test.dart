import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/passwords/generator.dart';

void main() {
  test('generated passwords have every character class and no look-alikes', () {
    final random = Random(1);
    for (var i = 0; i < 500; i++) {
      final password = generatePassword(random: random);
      expect(password.length, 20);
      expect(password, matches(RegExp('[a-z]')));
      expect(password, matches(RegExp('[A-Z]')));
      expect(password, matches(RegExp('[0-9]')));
      expect(password, matches(RegExp(r'[-_.!@#%+=]')));
      expect(password, isNot(matches(RegExp('[lIO01]'))));
    }
  });

  test('length is configurable and passwords differ', () {
    expect(generatePassword(length: 32).length, 32);
    expect(generatePassword(), isNot(generatePassword()));
  });
}
