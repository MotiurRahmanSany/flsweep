import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flsweep/src/services/metrics.dart';

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('flsweep_metrics_test_');
  });

  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  /// Creates [relativePath] (file) filled with [kb] kilobytes of content.
  void writeKbFile(String relativePath, {int kb = 1}) {
    final file = File(p.join(workspace.path, relativePath))
      ..parent.createSync(recursive: true);
    file.writeAsStringSync('x' * (kb * 1024));
  }

  group('detectCleanableTargets', () {
    test('detects build and .dart_tool at project root', () {
      Directory(p.join(workspace.path, 'build')).createSync();
      Directory(p.join(workspace.path, '.dart_tool')).createSync();

      expect(
        detectCleanableTargets(workspace.path),
        containsAll(['build', '.dart_tool']),
      );
    });

    test('detects android/.gradle and ios/Pods', () {
      Directory(p.join(workspace.path, 'android', '.gradle'))
          .createSync(recursive: true);
      Directory(p.join(workspace.path, 'ios', 'Pods'))
          .createSync(recursive: true);

      final targets = detectCleanableTargets(workspace.path);
      expect(targets, contains('.gradle'));
      expect(targets, contains('Pods'));
    });

    test('detects ios/Podfile.lock', () {
      writeKbFile('ios/Podfile.lock', kb: 2);
      expect(detectCleanableTargets(workspace.path), contains('Podfile.lock'));
    });

    test('empty project reports no targets', () {
      expect(detectCleanableTargets(workspace.path), isEmpty);
    });
  });

  group('pathSize / directorySize', () {
    test('sums file sizes recursively', () {
      writeKbFile('build/app.so', kb: 4);
      writeKbFile('build/cache/blob.bin', kb: 2);
      writeKbFile('build/empty_dir/.keep', kb: 1);

      expect(directorySize(p.join(workspace.path, 'build')), 7 * 1024);
    });

    test('returns 0 for a missing path', () {
      expect(
        directorySize(p.join(workspace.path, 'ghost')),
        0,
      );
    });

    test('returns file size for a single file via pathSize', () {
      writeKbFile('build/single.bin', kb: 3);
      expect(
        pathSize(p.join(workspace.path, 'build', 'single.bin')),
        3 * 1024,
      );
    });

    test('does not follow symlinks when measuring', () {
      writeKbFile('build/real.bin', kb: 5);
      final outside = File(p.join(workspace.path, 'outside.bin'))
        ..writeAsStringSync('y' * (10 * 1024));
      Link(p.join(workspace.path, 'build', 'link.bin'))
          .createSync(outside.path);

      expect(directorySize(p.join(workspace.path, 'build')), 5 * 1024);
    });
  });

  group('measureCleanableSize', () {
    test('sums all present cleanable artifacts', () {
      writeKbFile('build/out.bin', kb: 4);
      writeKbFile('.dart_tool/data.json', kb: 2);
      writeKbFile('android/.gradle/cache.bin', kb: 8);

      expect(measureCleanableSize(workspace.path), 14 * 1024);
    });

    test('returns 0 when nothing cleanable exists', () {
      writeKbFile('lib/main.dart', kb: 1);
      expect(measureCleanableSize(workspace.path), 0);
    });
  });

  group('formatBytes', () {
    test('formats bytes', () {
      expect(formatBytes(123), '123B');
    });

    test('formats kilobytes', () {
      expect(formatBytes(1024), '1.00 KB');
      expect(formatBytes(45 * 1024), '45.0 KB');
    });

    test('formats megabytes', () {
      expect(formatBytes(1024 * 1024), '1.00 MB');
    });

    test('formats gigabytes', () {
      expect(formatBytes(1024 * 1024 * 1024), '1.00 GB');
      expect(formatBytes((2.45 * 1024 * 1024 * 1024).round()), '2.45 GB');
    });
  });
}
