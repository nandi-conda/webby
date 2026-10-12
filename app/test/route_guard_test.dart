import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webby/src/route_guard.dart';

/// What Android's FlutterActivity sends for a link opened from another app while deep linking is on.
Future<void> pushLink(WidgetTester tester, String url) async {
  final message = const JSONMethodCodec().encodeMethodCall(MethodCall('pushRouteInformation', {'location': url}));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('flutter/navigation', message, (_) {});
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('without the guard a link push stacks a second home page', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const Text('browser')));
    await pushLink(tester, 'https://example.com');
    expect(find.text('browser', skipOffstage: false), findsNWidgets(2));
  });

  testWidgets('with the guard links pushed by the platform leave the page alone', (tester) async {
    PlatformRouteGuard.install();
    await tester.pumpWidget(MaterialApp(home: const Text('browser')));
    await pushLink(tester, 'https://example.com');
    await pushLink(tester, 'https://example.org/some/page');
    expect(find.text('browser', skipOffstage: false), findsOneWidget);
  });
}
