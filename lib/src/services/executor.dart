import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/project_info.dart';
import 'metrics.dart';

/// Signature of the process runner used to invoke `flutter` commands.
///
/// Injectable so tests can substitute a fake runner instead of requiring a
/// real Flutter SDK on the machine.
typedef CommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
});

/// Signature of the destructive deep-clean delete operation.
///
/// Injectable so tests can observe (or stub) deletions.
typedef DeepDelete = void Function(String targetPath);

/// Runs an executable in [workingDirectory], defaulting to `Process.run`.
Future<ProcessResult> defaultCommandRunner(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) {
  return Process.run(executable, arguments, workingDirectory: workingDirectory);
}

/// Deletes a file or directory recursively, silently ignoring failures.
///
/// This is deliberately forgiving: a partially locked `build` folder on
/// Windows must never crash the whole sweep.
void defaultDeepDelete(String targetPath) {
  try {
    final type = FileSystemEntity.typeSync(targetPath, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        Directory(targetPath).deleteSync(recursive: true);
      case FileSystemEntityType.file:
      case FileSystemEntityType.link:
        File(targetPath).deleteSync();
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.unixDomainSock:
      case FileSystemEntityType.pipe:
        return;
    }
  } on FileSystemException {
    // Best-effort deletion; the post-clean measurement will reflect what
    // actually happened on disk.
  }
}

/// Returns `true` when [targetPath] is a legal deep-clean target inside
/// [projectRoot].
///
/// The safety net enforces all of the following:
///
/// * [targetPath] must resolve *inside* [projectRoot] (never a sibling or
///   parent directory).
/// * It must be one of the explicitly whitelisted artifact names
///   (`build`, `.dart_tool`, `.gradle`, `Pods`, `Podfile.lock`).
/// * It must never live under a `.pub-cache` segment, and must never be the
///   user's home directory or the filesystem root.
///
/// These checks are what make flsweep's destructive mode safe to point at
/// arbitrary workspaces.
bool isSafeToDelete(String targetPath, String projectRoot) {
  final canonicalTarget = p.canonicalize(targetPath);
  final canonicalRoot = p.canonicalize(projectRoot);

  // Never delete the root itself, the home directory, or the filesystem root.
  if (canonicalTarget == canonicalRoot) {
    return false;
  }
  if (canonicalTarget == p.canonicalize(p.current) ||
      canonicalTarget == p.canonicalize(homeDirPath())) {
    return false;
  }
  if (p.split(canonicalTarget).length <= 2) {
    // Refuse anything at (or immediately below) the filesystem root.
    return false;
  }

  // Must be inside the project root.
  final relative = p.relative(canonicalTarget, from: canonicalRoot);
  if (relative == '.' || relative.startsWith('..')) {
    return false;
  }

  // Refuse anything under a pub cache.
  for (final segment in p.split(relative)) {
    if (segment == '.pub-cache') {
      return false;
    }
  }

  // Only whitelisted artifact names may ever be deleted.
  const allowed = <String>{
    kBuildDirName,
    kDartToolDirName,
    kGradleDirName,
  };
  final allowedLower = <String>{
    ...allowed,
    kPodsDirName.toLowerCase(),
    kPodfileLockName.toLowerCase(),
  };
  final segments = p.split(relative);
  // Case-insensitive: on Windows NTFS canonicalize lowercases every path, so
  // `ios/Pods` becomes `ios/pods`; compare against lowercased names so the
  // whitelist works identically on Linux, macOS, and Windows.
  return segments
      .map((segment) => segment.toLowerCase())
      .any(allowedLower.contains);
}

/// Best-effort path to the user's home directory across platforms.
String homeDirPath() {
  final env = Platform.environment;
  if (!Platform.isWindows) {
    return env['HOME'] ?? '/';
  }
  return env['USERPROFILE'] ?? env['HOME'] ?? '/';
}

/// Per-project outcome of a sweep run.
class SweepResult {
  const SweepResult({
    required this.project,
    required this.cleanOk,
    required this.pubGetOk,
    this.deepCleaned = false,
    this.skippedPubGet = false,
    this.dryRun = false,
    this.error,
  });

  /// The project that was processed.
  final ProjectInfo project;

  /// Whether `flutter clean` succeeded (or was skipped in dry-run mode).
  final bool cleanOk;

  /// Whether `flutter pub get` succeeded (or was intentionally skipped).
  final bool pubGetOk;

  /// Whether deep-clean artifacts were found and removed.
  final bool deepCleaned;

  /// Whether `pub get` was skipped (dry-run mode).
  final bool skippedPubGet;

  /// Whether this run was a dry run (nothing was deleted or executed).
  final bool dryRun;

  /// Human-readable failure reason when either step failed.
  final String? error;

  /// Whether every requested step succeeded.
  bool get isSuccess => cleanOk && (pubGetOk || skippedPubGet);
}

/// Emitted whenever a project changes state, so the TUI can repaint.
class SweepEvent {
  const SweepEvent({required this.project, required this.status, this.detail});

  /// Project whose state changed.
  final ProjectInfo project;

  /// New status.
  final ProjectStatus status;

  /// Optional detail line (e.g. a step label or error text).
  final String? detail;
}

/// Concurrent sweep executor.
///
/// Processes projects through the pipeline
/// `measure → flutter clean → (deep clean) → flutter pub get → measure`,
/// running at most [concurrency] projects in parallel. Every project is
/// isolated: a failure there marks only that project [ProjectStatus.failed]
/// and the remaining projects keep processing — flsweep never crashes.
class SweepExecutor {
  /// Creates an executor.
  ///
  /// [concurrency] caps parallel projects (roadmap default: 4). [deep]
  /// enables removal of `android/.gradle`, `ios/Pods`, `ios/Podfile.lock`,
  /// and `.dart_tool`. [dryRun] measures and reports without deleting or
  /// running any command. [commandRunner] and [deepDelete] are injectable
  /// seams for tests.
  SweepExecutor({
    this.concurrency = 4,
    this.deep = false,
    this.dryRun = false,
    this.runPubGet = true,
    this.commandRunner = defaultCommandRunner,
    this.deepDelete = defaultDeepDelete,
    void Function(SweepEvent event)? onEvent,
  }) : _onEvent = onEvent;

  /// Maximum number of projects processed in parallel.
  final int concurrency;

  /// Whether deep-clean routines run after `flutter clean`.
  final bool deep;

  /// Whether this is a measurement-only run.
  final bool dryRun;

  /// Whether `flutter pub get` runs after a successful clean.
  final bool runPubGet;

  /// Injectable process runner.
  final CommandRunner commandRunner;

  /// Injectable delete routine.
  final DeepDelete deepDelete;

  final void Function(SweepEvent event)? _onEvent;

  void _emit(SweepEvent event) => _onEvent?.call(event);

  /// Name of the flutter executable for the host platform.
  String get flutterExecutable =>
      Platform.isWindows ? 'flutter.bat' : 'flutter';

  /// Sweeps [projects] with the configured concurrency.
  ///
  /// Returns results in the same order as [projects], regardless of
  /// completion order.
  Future<List<SweepResult>> runAll(List<ProjectInfo> projects) async {
    final results = List<SweepResult?>.filled(projects.length, null);
    final workerCount = concurrency < 1 ? 1 : concurrency;
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= projects.length) {
          return;
        }
        results[index] = await _processProject(projects[index]);
      }
    }

    await Future.wait(
      <Future<void>>[for (var i = 0; i < workerCount; i++) worker()],
    );
    return List<SweepResult>.unmodifiable(
      results.map<SweepResult>((r) => r!),
    );
  }

  /// Runs the full pipeline for a single project, swallowing all errors.
  Future<SweepResult> _processProject(ProjectInfo project) async {
    try {
      // 1. Measure pre-clean state.
      project
        ..status = ProjectStatus.queued
        ..preCleanSize = measureCleanableSize(project.path);
      _emit(SweepEvent(project: project, status: ProjectStatus.queued));

      if (dryRun) {
        project
          ..status = ProjectStatus.completed
          ..postCleanSize = project.preCleanSize;
        _emit(
          SweepEvent(
            project: project,
            status: ProjectStatus.completed,
            detail: 'dry run',
          ),
        );
        return SweepResult(
          project: project,
          cleanOk: true,
          pubGetOk: false,
          skippedPubGet: true,
          dryRun: true,
        );
      }

      // 2. flutter clean.
      project.status = ProjectStatus.cleaning;
      _emit(SweepEvent(project: project, status: ProjectStatus.cleaning));
      final cleanOk = await runFlutterClean(project);
      if (!cleanOk) {
        final message =
            project.error ?? 'flutter clean failed in ${project.path}';
        project
          ..status = ProjectStatus.failed
          ..error = message;
        _emit(SweepEvent(
          project: project,
          status: ProjectStatus.failed,
          detail: message,
        ));
        return SweepResult(
          project: project,
          cleanOk: false,
          pubGetOk: false,
          error: message,
        );
      }

      // 3. Optional deep clean.
      var deepCleaned = false;
      if (deep) {
        project.status = ProjectStatus.deepCleaning;
        _emit(
          SweepEvent(project: project, status: ProjectStatus.deepCleaning),
        );
        deepCleaned = runDeepClean(project);
      }

      // 4. flutter pub get (zero-break sync).
      var pubGetOk = false;
      var skipped = false;
      if (runPubGet) {
        project.status = ProjectStatus.syncing;
        _emit(SweepEvent(project: project, status: ProjectStatus.syncing));
        pubGetOk = await runPubGet_(project);
        if (!pubGetOk) {
          final message =
              project.error ?? 'flutter pub get failed in ${project.path}';
          project
            ..status = ProjectStatus.failed
            ..error = message;
          _emit(SweepEvent(
            project: project,
            status: ProjectStatus.failed,
            detail: message,
          ));
          return SweepResult(
            project: project,
            cleanOk: true,
            pubGetOk: false,
            deepCleaned: deepCleaned,
            error: message,
          );
        }
      } else {
        skipped = true;
      }

      // 5. Measure post-clean state.
      project
        ..status = ProjectStatus.completed
        ..postCleanSize = measureCleanableSize(project.path)
        ..cleanableTargets.addAll(
          detectCleanableTargets(project.path),
        );
      _emit(SweepEvent(project: project, status: ProjectStatus.completed));
      return SweepResult(
        project: project,
        cleanOk: true,
        pubGetOk: pubGetOk,
        deepCleaned: deepCleaned,
        skippedPubGet: skipped,
      );
    } catch (error, stackTrace) {
      // Absolute last-resort isolation: no single project may ever crash the
      // sweep. Convert the failure into a per-project status.
      final message = '$error';
      project
        ..status = ProjectStatus.failed
        ..error = message;
      _emit(SweepEvent(
        project: project,
        status: ProjectStatus.failed,
        detail: message,
      ));
      assert(() {
        // Debug-mode visibility only; never in release runs.
        // ignore: avoid_print
        print('flsweep: unexpected failure on ${project.path}\n$stackTrace');
        return true;
      }());
      return SweepResult(
        project: project,
        cleanOk: false,
        pubGetOk: false,
        error: message,
      );
    }
  }

  /// Runs `flutter clean` inside the project. Returns success.
  Future<bool> runFlutterClean(ProjectInfo project) async {
    return _runCommand(
      project,
      const <String>['clean'],
      failurePrefix: 'flutter clean failed',
    );
  }

  /// Runs `flutter pub get` inside the project. Returns success.
  Future<bool> runPubGet_(ProjectInfo project) {
    return _runCommand(
      project,
      const <String>['pub', 'get'],
      failurePrefix: 'flutter pub get failed',
    );
  }

  Future<bool> _runCommand(
    ProjectInfo project,
    List<String> arguments, {
    required String failurePrefix,
  }) async {
    try {
      final result = await commandRunner(
        flutterExecutable,
        arguments,
        workingDirectory: project.path,
      );
      if (result.exitCode == 0) {
        return true;
      }
      project.error =
          '$failurePrefix (exit ${result.exitCode}): ${_stderrOf(result)}';
      return false;
    } catch (error) {
      // Missing SDK, permission error, signal — all isolated here.
      project.error = '$failurePrefix: $error';
      return false;
    }
  }

  /// Removes deep-clean artifacts, honoring the safety whitelist.
  ///
  /// Returns `true` when at least one artifact was actually removed.
  bool runDeepClean(ProjectInfo project) {
    var removedAny = false;

    void remove(String targetPath) {
      if (!isSafeToDelete(targetPath, project.path)) {
        return;
      }
      final existed = FileSystemEntity.typeSync(
            targetPath,
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound;
      if (!existed) {
        return;
      }
      deepDelete(targetPath);
      removedAny = true;
    }

    remove(p.join(project.path, 'android', kGradleDirName));
    remove(p.join(project.path, 'ios', kPodsDirName));
    remove(p.join(project.path, 'ios', kPodfileLockName));
    remove(p.join(project.path, kDartToolDirName));

    return removedAny;
  }

  static String _stderrOf(ProcessResult result) {
    final stderr = result.stderr;
    if (stderr is String && stderr.trim().isNotEmpty) {
      final lines = stderr.trim().split('\n');
      return lines.length <= 3
          ? lines.join(' ')
          : '${lines.take(3).join(' ')}…';
    }
    return 'no stderr output';
  }
}
