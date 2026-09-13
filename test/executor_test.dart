import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flsweep/src/models/project_info.dart';
import 'package:flsweep/src/services/executor.dart';

/// A scriptable fake that records executed commands.
class FakeRunner {
  FakeRunner({this.defaultExitCode = 0, this.failFor = const <String>{}});

  /// Exit code returned to every command unless it matches [failFor].
  final int defaultExitCode;

  /// Argument signatures (`clean`, `pub get`) that should fail.
  final Set<String> failFor;

  final List<({String executable, List<String> arguments, String cwd})>
      calls = <({String executable, List<String> arguments, String cwd})>[];

  /// Whether the runner should emulate a missing `flutter` executable.
  bool throwNotFound = false;

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls.add((
      executable: executable,
      arguments: List<String>.of(arguments),
      cwd: workingDirectory ?? p.current,
    ));
    if (throwNotFound) {
      throw ProcessException(executable, arguments, 'flutter not found');
    }
    final signature = arguments.join(' ');
    final exitCode = failFor.contains(signature) ? 1 : defaultExitCode;
    return ProcessResult(0, exitCode, 'stdout', exitCode == 0 ? '' : 'boom');
  }

  bool ranOnce(String signature) =>
      calls.any((call) => call.arguments.join(' ') == signature);
}

/// Makes a minimal on-disk Flutter project fixture.
ProjectInfo makeProject(Directory root, String name) {
  final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
  File(p.join(dir.path, 'pubspec.yaml')).writeAsStringSync(
    'name: $name\nflutter:\n  uses-material-design: true\n',
  );
  return ProjectInfo(path: dir.path, name: name);
}

void main() {
  late Directory workspace;
  late FakeRunner runner;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('flsweep_executor_test_');
    runner = FakeRunner();
  });

  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup.
    }
  });

  group('SweepExecutor pipeline', () {
    test('runs flutter clean then flutter pub get in order', () async {
      final project = makeProject(workspace, 'happy_app');
      final executor = SweepExecutor(
        concurrency: 1,
        commandRunner: runner.run,
      );

      final results = await executor.runAll([project]);

      expect(results.single.isSuccess, isTrue);
      expect(runner.ranOnce('clean'), isTrue);
      expect(runner.ranOnce('pub get'), isTrue);

      // Order matters: clean must precede pub get.
      final signatures =
          runner.calls.map((call) => call.arguments.join(' ')).toList();
      expect(signatures.indexOf('clean'), lessThan(signatures.indexOf('pub get')));
    });

    test('all commands run inside the project directory', () async {
      final project = makeProject(workspace, 'cwd_app');
      final executor = SweepExecutor(commandRunner: runner.run);

      await executor.runAll([project]);

      for (final call in runner.calls) {
        expect(call.cwd, project.path);
      }
    });

    test('reports freed bytes for a project with build artifacts', () async {
      final project = makeProject(workspace, 'big_app');
      final buildDir = Directory(p.join(project.path, 'build'))
        ..createSync(recursive: true);
      File(p.join(buildDir.path, 'out.bin')).writeAsBytesSync(
        List<int>.filled(4096, 1),
      );

      // Emulate flutter clean's disk effect: it removes build/ and .dart_tool.
      Future<ProcessResult> cleaningRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        if (arguments.join(' ') == 'clean' && workingDirectory != null) {
          for (final name in ['build', '.dart_tool']) {
            final dir = Directory(p.join(workingDirectory, name));
            if (dir.existsSync()) {
              dir.deleteSync(recursive: true);
            }
          }
        }
        return runner.run(executable, arguments, workingDirectory: workingDirectory);
      }

      final executor = SweepExecutor(commandRunner: cleaningRunner);
      final results = await executor.runAll([project]);

      expect(results.single.isSuccess, isTrue);
      expect(project.preCleanSize, greaterThan(0));
      expect(project.freedBytes, greaterThan(0));
    });

    test('skips everything in dry-run mode', () async {
      final project = makeProject(workspace, 'dry_app');
      final executor = SweepExecutor(
        dryRun: true,
        commandRunner: runner.run,
      );

      final results = await executor.runAll([project]);

      expect(runner.calls, isEmpty);
      expect(results.single.dryRun, isTrue);
      expect(results.single.isSuccess, isTrue);
      expect(project.status, ProjectStatus.completed);
    });

    test('runPubGet=false skips the sync step', () async {
      final project = makeProject(workspace, 'nosync_app');
      final executor = SweepExecutor(
        runPubGet: false,
        commandRunner: runner.run,
      );

      final results = await executor.runAll([project]);

      expect(runner.ranOnce('clean'), isTrue);
      expect(runner.ranOnce('pub get'), isFalse);
      expect(results.single.skippedPubGet, isTrue);
    });
  });

  group('failure isolation', () {
    test('a failed clean marks only that project as failed', () async {
      final good = makeProject(workspace, 'good_app');
      final bad = makeProject(workspace, 'bad_app');

      // Fails flutter clean only inside bad_app.
      Future<ProcessResult> selectiveRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        if (arguments.join(' ') == 'clean' &&
            p.basename(workingDirectory ?? '') == 'bad_app') {
          return ProcessResult(0, 1, '', 'clean exploded');
        }
        return runner.run(executable, arguments, workingDirectory: workingDirectory);
      }

      final executor = SweepExecutor(commandRunner: selectiveRunner);
      final results = await executor.runAll([bad, good]);

      expect(results[0].isSuccess, isFalse);
      expect(results[0].error, isNotNull);
      expect(bad.status, ProjectStatus.failed);

      // The remaining project still processed.
      expect(results[1].isSuccess, isTrue);
      expect(good.status, ProjectStatus.completed);
      expect(runner.ranOnce('pub get'), isTrue);
    });

    test('a failed pub get marks the project failed', () async {
      final project = makeProject(workspace, 'sync_fail_app');
      final failing = FakeRunner(failFor: {'pub get'});

      final executor = SweepExecutor(commandRunner: failing.run);
      final results = await executor.runAll([project]);

      expect(results.single.isSuccess, isFalse);
      expect(results.single.cleanOk, isTrue);
      expect(results.single.pubGetOk, isFalse);
      expect(results.single.error, contains('pub get'));
    });

    test('a missing flutter executable is isolated, not fatal', () async {
      final project = makeProject(workspace, 'nosdk_app');
      runner.throwNotFound = true;

      final executor = SweepExecutor(commandRunner: runner.run);
      final results = await executor.runAll([project]);

      expect(results.single.isSuccess, isFalse);
      expect(results.single.error, isNotNull);
    });

    test('sweep never throws even for a nonexistent project path', () async {
      final ghost = ProjectInfo(
        path: p.join(workspace.path, 'does_not_exist'),
        name: 'ghost',
      );

      // Real Process.run throws when the working directory is missing;
      // emulate that so the executor's isolation is genuinely exercised.
      Future<ProcessResult> cwdAwareRunner(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        if (workingDirectory != null &&
            !Directory(workingDirectory).existsSync()) {
          throw ProcessException(
            executable,
            arguments,
            'Working directory does not exist',
          );
        }
        return runner.run(executable, arguments, workingDirectory: workingDirectory);
      }

      final executor = SweepExecutor(commandRunner: cwdAwareRunner);
      final results = await executor.runAll([ghost]);

      // The command fails but nothing escapes the executor.
      expect(results.single.isSuccess, isFalse);
    });
  });

  group('concurrency', () {
    test('processes many projects with a bounded worker pool', () async {
      final projects = <ProjectInfo>[
        for (var i = 0; i < 10; i++) makeProject(workspace, 'p_$i'),
      ];

      var inFlight = 0;
      var peak = 0;
      final tracked = FakeRunner();
      Future<ProcessResult> track(
        String executable,
        List<String> arguments, {
        String? workingDirectory,
      }) async {
        inFlight++;
        if (inFlight > peak) {
          peak = inFlight;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final result = await tracked.run(
          executable,
          arguments,
          workingDirectory: workingDirectory,
        );
        inFlight--;
        return result;
      }

      final executor = SweepExecutor(
        concurrency: 4,
        commandRunner: track,
      );
      final results = await executor.runAll(projects);

      expect(results.length, 10);
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(projects.every((pr) => pr.isSuccess), isTrue);
      // Concurrency cap respected (each project spawns 2 commands).
      expect(peak, lessThanOrEqualTo(4));
      // All 20 commands executed.
      expect(tracked.calls.length, 20);
    });

    test('preserves input order in results regardless of completion',
        () async {
      final projects = <ProjectInfo>[
        for (var i = 0; i < 6; i++) makeProject(workspace, 'ordered_$i'),
      ];

      final executor = SweepExecutor(
        concurrency: 6,
        commandRunner: runner.run,
      );
      final results = await executor.runAll(projects);

      for (var i = 0; i < projects.length; i++) {
        expect(results[i].project.path, projects[i].path);
      }
    });
  });

  group('deep clean', () {
    test('removes .gradle, Pods, Podfile.lock, and .dart_tool with --deep',
        () async {
      final project = makeProject(workspace, 'deep_app');
      Directory(p.join(project.path, 'android', '.gradle'))
          .createSync(recursive: true);
      Directory(p.join(project.path, 'ios', 'Pods')).createSync(recursive: true);
      File(p.join(project.path, 'ios', 'Podfile.lock'))
          .writeAsStringSync('PODS:\n');
      Directory(p.join(project.path, '.dart_tool')).createSync();

      final executor = SweepExecutor(
        deep: true,
        commandRunner: runner.run,
      );
      final results = await executor.runAll([project]);

      expect(results.single.deepCleaned, isTrue);
      expect(
        Directory(p.join(project.path, 'android', '.gradle')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(project.path, 'ios', 'Pods')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(project.path, 'ios', 'Podfile.lock')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(project.path, '.dart_tool')).existsSync(),
        isFalse,
      );
    });

    test('without --deep nothing inside android/ios is touched', () async {
      final project = makeProject(workspace, 'shallow_app');
      Directory(p.join(project.path, 'android', '.gradle'))
          .createSync(recursive: true);
      Directory(p.join(project.path, 'ios', 'Pods')).createSync(recursive: true);

      final executor = SweepExecutor(commandRunner: runner.run);
      await executor.runAll([project]);

      expect(
        Directory(p.join(project.path, 'android', '.gradle')).existsSync(),
        isTrue,
      );
      expect(
        Directory(p.join(project.path, 'ios', 'Pods')).existsSync(),
        isTrue,
      );
    });
  });

  group('isSafeToDelete (safety whitelist)', () {
    test('accepts artifact paths inside the project', () {
      final root = p.canonicalize(workspace.path);
      expect(isSafeToDelete(p.join(root, 'build'), root), isTrue);
      expect(isSafeToDelete(p.join(root, '.dart_tool'), root), isTrue);
      expect(
        isSafeToDelete(p.join(root, 'android', '.gradle'), root),
        isTrue,
      );
      expect(isSafeToDelete(p.join(root, 'ios', 'Pods'), root), isTrue);
      expect(
        isSafeToDelete(p.join(root, 'ios', 'Podfile.lock'), root),
        isTrue,
      );
    });

    test('rejects the project root itself', () {
      final root = p.canonicalize(workspace.path);
      expect(isSafeToDelete(root, root), isFalse);
    });

    test('rejects non-whitelisted names', () {
      final root = p.canonicalize(workspace.path);
      expect(isSafeToDelete(p.join(root, 'lib'), root), isFalse);
      expect(isSafeToDelete(p.join(root, 'lib', 'main.dart'), root), isFalse);
    });

    test('rejects paths outside the project root', () {
      final root = p.canonicalize(workspace.path);
      final outside = p.canonicalize(Directory.systemTemp.path);
      expect(isSafeToDelete(p.join(outside, 'build'), root), isFalse);
      expect(isSafeToDelete(p.join(root, '..', 'build'), root), isFalse);
    });

    test('rejects anything under .pub-cache', () {
      final root = p.canonicalize(workspace.path);
      final sneaky = p.join(root, '.dart_tool', 'pub', 'cache', 'x');
      // Not under .pub-cache by name, still fine:
      expect(isSafeToDelete(sneaky, root), isTrue);
      final pubCache = p.join(root, 'build', '.pub-cache', 'hosted');
      expect(isSafeToDelete(pubCache, root), isFalse);
    });
  });

  group('events', () {
    test('emits lifecycle events for each project', () async {
      final project = makeProject(workspace, 'eventful_app');
      final statuses = <ProjectStatus>[];
      final executor = SweepExecutor(
        commandRunner: runner.run,
        onEvent: (event) => statuses.add(event.status),
      );

      await executor.runAll([project]);

      expect(statuses, contains(ProjectStatus.queued));
      expect(statuses, contains(ProjectStatus.cleaning));
      expect(statuses, contains(ProjectStatus.syncing));
      expect(statuses.last, ProjectStatus.completed);
    });
  });
}
