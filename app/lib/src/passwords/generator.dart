import 'dart:math';

const _lower = 'abcdefghijkmnopqrstuvwxyz';
const _upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '23456789';
const _symbols = '-_.!@#%+=';

/// A random password for a new account: [length] characters from Random.secure() with at least one lowercase letter,
/// uppercase letter, digit and symbol, so it passes the usual site rules. Look-alike characters (l, I, O, 0, 1) are
/// left out so it can be read off the screen. 20 characters from this set is about 120 bits.
String generatePassword({int length = 20, Random? random}) {
  assert(length >= 8);
  final rng = random ?? Random.secure();
  const all = _lower + _upper + _digits + _symbols;
  String pick(String set) => set[rng.nextInt(set.length)];
  final chars = [
    pick(_lower),
    pick(_upper),
    pick(_digits),
    pick(_symbols),
    for (var i = 4; i < length; i++) pick(all),
  ]..shuffle(rng);
  return chars.join();
}
