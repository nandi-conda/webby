import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../ui.dart';

/// Scans a sync QR code with the camera and returns its text, or null when the user backs out.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    final text = capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (text == null || text.isEmpty) return;
    _done = true;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return KitPage(
      title: 'Scan sync code',
      body: MobileScanner(
        controller: _controller,
        onDetect: _detected,
        errorBuilder: (context, error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              error.errorCode == MobileScannerErrorCode.permissionDenied
                  ? 'Webby needs the camera to scan the code. Allow it in Android settings, or type the code instead.'
                  : 'The camera is not available (${error.errorCode.name}). Type the code instead.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
