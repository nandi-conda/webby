import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/omnibox.dart';

void main() {
  const google = 'https://www.google.com/search?q=';

  test('addresses load as they are', () {
    for (final input in [
      'https://example.com',
      'http://localhost:8080/x',
      'example.com',
      'news.ycombinator.com/item?id=1',
      'localhost',
      'localhost:3000',
      '192.168.1.1',
      '10.0.0.1:8000/path',
      'about:blank',
      'file:///etc/hosts',
      'user@example.com/',
    ]) {
      expect(addressToUrl(input), input, reason: input);
    }
  });

  test('naked queries search Google', () {
    expect(addressToUrl('flutter tabs'), '${google}flutter+tabs');
    expect(addressToUrl('ladybird'), '${google}ladybird');
    expect(addressToUrl('what is 1+1?'), '${google}what+is+1%2B1%3F');
    expect(addressToUrl('foo.bar baz'), '${google}foo.bar+baz');
    expect(addressToUrl('c++'), '${google}c%2B%2B');
    expect(addressToUrl('1.5'), '${google}1.5');
  });
}
