import 'dart:io';

import 'package:webby_sync_server/webby_sync_server.dart';

Future<void> main() async {
  final dataDir = Directory(Platform.environment['DATA_DIR'] ?? 'data');
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8080;
  final http = await serve(SyncServer(dataDir), port: port);
  stdout.writeln('webby-sync listening on :${http.port}, data in ${dataDir.path}');
  ProcessSignal.sigterm.watch().listen((_) async {
    await http.close();
    exit(0);
  });
}
