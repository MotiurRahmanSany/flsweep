/// Data model describing a Flutter project discovered by the scanner.
///
/// A [ProjectInfo] instance carries the immutable identity of a project
/// (its canonical [path] and its declared [name]) together with mutable,
/// run-scoped state: the size of its cleanable artifacts before and after
/// cleaning, its lifecycle [status], and the error message when a step
/// fails.
library;

/// Lifecycle status of a project during a sweep run.
enum ProjectStatus {
  /// Discovered by the scanner and validated as a Flutter project.
  discovered,

  /// Waiting for a free worker slot.
  queued,

  /// `flutter clean` is currently running for this project.
  cleaning,

  /// Deep-clean routines (gradle/pods/dart_tool) are running.
  deepCleaning,

  /// `flutter pub get` is currently running for this project.
  syncing,

  /// All steps finished successfully.
  completed,

  /// At least one step failed; see [ProjectInfo.error].
  failed,

  /// Skipped (e.g. by the user in the interactive checklist).
  skipped,
}

/// Human-friendly rendering of a [ProjectStatus].
String projectStatusLabel(ProjectStatus status) {
  switch (status) {
    case ProjectStatus.discovered:
      return 'Discovered';
    case ProjectStatus.queued:
      return 'Queued';
    case ProjectStatus.cleaning:
      return 'Cleaning';
    case ProjectStatus.deepCleaning:
      return 'Deep cleaning';
    case ProjectStatus.syncing:
      return 'Syncing';
    case ProjectStatus.completed:
      return 'Completed';
    case ProjectStatus.failed:
      return 'Failed';
    case ProjectStatus.skipped:
      return 'Skipped';
  }
}

/// A single Flutter project discovered inside a workspace.
class ProjectInfo {
  /// Creates a project description rooted at [path].
  ///
  /// The [path] should already be canonicalized by the scanner. [name] is the
  /// `name:` field declared in the project's `pubspec.yaml`.
  ProjectInfo({
    required this.path,
    required this.name,
    this.preCleanSize = 0,
    this.postCleanSize = 0,
    this.status = ProjectStatus.discovered,
    this.error,
    List<String> cleanableTargets = const <String>[],
  }) : cleanableTargets = List<String>.of(cleanableTargets);

  /// Canonical, absolute path of the project root directory.
  final String path;

  /// Project name as declared in `pubspec.yaml`.
  final String name;

  /// Size in bytes of cleanable artifacts measured before cleaning.
  int preCleanSize;

  /// Size in bytes of the same artifacts measured after cleaning.
  int postCleanSize;

  /// Current lifecycle status of the project within a sweep run.
  ProjectStatus status;

  /// Error message if any execution step failed for this project.
  String? error;

  /// Names of cleanable artifact directories/files actually present on disk
  /// when the project was measured (e.g. `build`, `.dart_tool`).
  final List<String> cleanableTargets;

  /// Base name of [path]; handy for compact terminal output.
  String get directoryName {
    final segments = path.split('/');
    return segments.isEmpty ? path : segments.last;
  }

  /// Bytes recovered by cleaning: `preCleanSize - postCleanSize`.
  ///
  /// Never negative; a post-clean regrowth larger than the pre-clean size
  /// still reports zero.
  int get freedBytes {
    final freed = preCleanSize - postCleanSize;
    return freed > 0 ? freed : 0;
  }

  /// Whether this project finished its sweep successfully.
  bool get isSuccess => status == ProjectStatus.completed;

  /// Whether any step failed for this project.
  bool get isFailed => status == ProjectStatus.failed;

  /// Serializes the model, useful for `--json` style machine output.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'name': name,
        'preCleanSize': preCleanSize,
        'postCleanSize': postCleanSize,
        'freedBytes': freedBytes,
        'status': status.name,
        'error': error,
        'cleanableTargets': List<String>.of(cleanableTargets),
      };

  @override
  String toString() => 'ProjectInfo($name, $path, $status)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProjectInfo &&
          other.runtimeType == runtimeType &&
          other.path == path;

  @override
  int get hashCode => path.hashCode;
}
