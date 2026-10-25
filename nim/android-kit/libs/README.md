`zxing-core-3.5.3.jar`: ZXing's core library (Apache License 2.0, https://github.com/zxing/zxing), unchanged from
Maven Central (`com.google.zxing:core:3.5.3`, sha256 8d8064c1…09fd82, checked by build.sh). QrScan.java uses its QR
decoder for Sync's Scan QR code; d8 dexes it into the APK. Kept in the repo so builds don't depend on Maven.
