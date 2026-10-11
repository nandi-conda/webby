import 'dart:async';
import 'dart:io';

import 'web_view.dart';

/// Frame costs the controller records while it shows pages.
class FrameStats {
  int frames = 0;
  int dartMicros = 0;
  int latencyMicros = 0;

  /// [dartMicros]: time spent on the Dart thread handing the frame over. [latencyMicros]: from picking the frame
  /// up to it being ready to draw (only the image path has a gap here; the texture is ready on return).
  void add(int dartMicros, int latencyMicros) {
    frames++;
    this.dartMicros += dartMicros;
    this.latencyMicros += latencyMicros;
  }

  void reset() => frames = dartMicros = latencyMicros = 0;
}

/// WEBBY_BENCH=N: once the first page has loaded, scroll it steadily for N seconds, print one line of frame
/// costs and exit. Used to compare the texture and image paths (WEBBY_TEXTURE=0 forces images).
void maybeStartBench(WebbyController controller) {
  final seconds = int.tryParse(Platform.environment['WEBBY_BENCH'] ?? '');
  if (seconds == null || seconds <= 0) return;

  Timer.periodic(const Duration(milliseconds: 100), (wait) {
    if (!controller.isAttached || controller.isLoading || controller.frameWidth == 0) return;
    wait.cancel();
    // Let late layout and images settle before measuring.
    Timer(const Duration(seconds: 2), () => _run(controller, seconds));
  });
}

void _run(WebbyController controller, int seconds) {
  controller.stats.reset();
  final cpuStart = _cpuMillis();
  final wall = Stopwatch()..start();
  final scroll = Timer.periodic(const Duration(milliseconds: 16), (_) => controller.runJavaScript('window.scrollBy(0, 6)'));

  Timer(Duration(seconds: seconds), () {
    scroll.cancel();
    final elapsed = wall.elapsedMilliseconds / 1000;
    final cpu = _cpuMillis() - cpuStart;
    final s = controller.stats;
    String per(num total) => s.frames == 0 ? '-' : (total / s.frames).toStringAsFixed(2);
    stdout.writeln('webby-bench renderer=${controller.textureId != null ? 'texture' : 'image'} '
        'size=${controller.frameWidth}x${controller.frameHeight} seconds=${elapsed.toStringAsFixed(1)} '
        'frames=${s.frames} fps=${(s.frames / elapsed).toStringAsFixed(1)} '
        'dart_ms_per_frame=${per(s.dartMicros / 1000)} latency_ms=${per(s.latencyMicros / 1000)} '
        'cpu_ms_per_frame=${per(cpu)} cpu_pct=${(cpu / 10 / elapsed).toStringAsFixed(0)}');
    exit(0);
  });
}

/// User + system CPU time of this process (the Flutter app, not Ladybird's helper processes).
int _cpuMillis() {
  final stat = File('/proc/self/stat').readAsStringSync();
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // Fields 14 and 15 of proc(5), in clock ticks (100 per second on Linux).
  return (int.parse(fields[11]) + int.parse(fields[12])) * 10;
}
