import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The canonical set of directory names that are never traversed during a
/// scan.
///
/// These paths may hold tens of gigabytes and hundreds of thousands of
/// package directories; crawling them is slow and — for system caches like
/// `.pub-cache` — explicitly forbidden by flsweep's safety rules.
const Set<String> kDefaultIgnoredDirectories = <String>{
  '.pub-cache',
  '.cache',
  '.local',
  '.git',
  'node_modules',
  'build',
};

/// Name of the file that marks a directory as a Dart/Flutter project.
const String kPubspecFileName = 'pubspec.yaml';

/// A Flutter project discovered in the workspace.
///
/// Kept as a lightweight record so the scanner never allocates heavy state;
/// the mutable run model lives in `package:flsweep/src/models/project_info.dart`.
class ScannedProject {
  const ScannedProject({required this.path, required this.name});

  /// Canonical absolute path to the project root (the directory holding
  /// `pubspec.yaml`).
  final String path;

  /// The `name:` declared at the top level of `pubspec.yaml`.
  final String name;

  @override
  String toString() => 'ScannedProject($name @ $path)';
}

/// Result of scanning a workspace root for Flutter projects.
class ScanResult {
  const ScanResult({required this.projects, required this.ignoredDirectories});

  /// All discovered Flutter projects, deterministically ordered by path.
  final List<ScannedProject> projects;

  /// Directories that were skipped because their name matched
  /// [Scanner.ignoredNames] (aggregate counts, not per-instance paths).
  final List<String> ignoredDirectories;

  /// Number of Flutter projects found.
  int get count => projects.length;

  /// Whether no projects were found at all.
  bool get isEmpty => projects.isEmpty;
}

/// Recursively discovers Flutter projects under a workspace root.
///
/// A directory counts as a Flutter project when it contains a `pubspec.yaml`
/// whose top level declares a `flutter:` block (e.g. `flutter: uses-material-
/// design: true` or `flutter: assets:`). Plain Dart packages are excluded by
/// this rule. The scan stops descending at any directory named in
/// [ignoredNames] or matching [ignorePredicate], and never follows symlinks
/// (this prevents loops and prevents crawling into system caches).
class Scanner {
  /// Creates a scanner rooted at [rootPath].
  ///
  /// [exclusions] accepts directory names (`build`, `legacy_tools`) or paths
  /// relative/absolute (`packages/legacy`, `/home/me/skipme`); entries whose
  /// base name matches are always skipped, which is what users intuitively
  /// expect from `--exclude`. [ignorePredicate] lets callers filter
  /// programmatically (e.g. hidden-directory handling is implemented with it).
  Scanner({
    required this.rootPath,
    Iterable<String> exclusions = const <String>[],
    this.maxDepth = 12,
    this.ignorePredicate,
  }) : exclusions = _normalizeExclusions(exclusions);

  /// Workspace root to crawl. Canonicalized in the constructor.
  final String rootPath;

  /// Normalized exclusion entries (see the constructor docs).
  final Set<String> exclusions;

  /// Directory names that are always skipped during traversal.
  ///
  /// Defaults to [kDefaultIgnoredDirectories]. Callers may extend (never
  /// shrink) this set for custom scans; the safety-critical entries such as
  /// `.pub-cache` and `.git` are re-merged in [ignoredNames] so they can
  /// never be removed by a subclass or an API misuse.
  final Set<String> ignoredNames = <String>{...kDefaultIgnoredDirectories};

  /// Maximum directory depth to descend from [rootPath].
  ///
  /// Flutter workspaces are shallow; the cap keeps scans on pathological
  /// trees (and mistake-mounted network shares) fast.
  final int maxDepth;

  /// Optional hook to veto traversal of a directory by its entity.
  final bool Function(FileSystemEntity entity)? ignorePredicate;

  /// Names that are skipped during traversal, including safety-critical
  /// entries that can never be removed.
  Set<String> get ignoredNamesSafe => <String>{
        ...ignoredNames,
        ...kDefaultIgnoredDirectories,
      };

  /// Normalizes user-supplied exclusions:
  ///
  /// * Trims whitespace and drops empties.
  /// * Canonicalizes anything that looks like a path (contains a separator)
  ///   so `./build` and `build` behave the same relative to the root.
  static Set<String> _normalizeExclusions(Iterable<String> raw) {
    final normalized = <String>{};
    for (final entry in raw) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.contains('/') || trimmed.contains(r'\')) {
        normalized.add(p.normalize(trimmed));
      } else {
        normalized.add(trimmed);
      }
    }
    return normalized;
  }

  /// Recursively [scan]s the workspace and awaits the full result.
  ///
  /// Convenience wrapper around [scanStream] for callers that just want the
  /// final list.
  Future<ScanResult> scan() async {
    final projects = <ScannedProject>[];
    await for (final project in scanStream()) {
      projects.add(project);
    }
    return ScanResult(projects: projects, ignoredDirectories: const <String>[]);
  }

  /// Scans the workspace, yielding projects as they are discovered.
  ///
  /// Streaming lets the TUI paint progress while deep workspaces are still
  /// being crawled.
  Stream<ScannedProject> scanStream() async* {
    final root = p.canonicalize(rootPath);
    final rootDir = Directory(root);
    if (!rootDir.existsSync()) {
      return;
    }

    final dirs = ListQueue<String>()..add(root);
    while (dirs.isNotEmpty) {
      final current = dirs.removeFirst();
      final currentDepth = _depthBelowRoot(root, current);
      if (currentDepth >= maxDepth) {
        continue;
      }

      final Directory dir = Directory(current);
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } on FileSystemException {
        continue; // Unreadable directory: skip silently.
      }

      String? pubspecCandidate;
      final childDirs = <String>[];

      for (final entity in entries) {
        final base = p.basename(entity.path);
        if (_isIgnoredEntity(entity, base)) {
          continue;
        }
        final type = entity
            .statSync()
            .type; // followLinks: false → links resolve to themselves
        if (type == FileSystemEntityType.directory) {
          childDirs.add(entity.path);
        } else if (type == FileSystemEntityType.file &&
            base == kPubspecFileName) {
          pubspecCandidate = entity.path;
        }
      }

      // When this directory is itself a Flutter project, report it and stop
      // descending: nested flutter apps are rare and nested Flutter project
      // scans produce duplicated nested clean operations.
      if (pubspecCandidate != null) {
        final name = extractFlutterProjectName(pubspecCandidate);
        if (name != null) {
          yield ScannedProject(path: p.canonicalize(current), name: name);
          continue;
        }
      }

      dirs.addAll(childDirs);
    }
  }

  /// Whether traversal of [entity] (basename [base]) is vetoed.
  bool _isIgnoredEntity(FileSystemEntity entity, String base) {
    if (ignoredNamesSafe.contains(base)) {
      return true;
    }
    // Hidden directories (starting with a dot) are skipped except the root
    // itself, which is never evaluated here (only children are).
    if (base.startsWith('.') && base.length > 1) {
      return true;
    }
    if (exclusions.isNotEmpty) {
      if (exclusions.contains(base)) {
        return true;
      }
      final relative = p.relative(entity.path, from: rootPath);
      if (exclusions.contains(p.normalize(relative))) {
        return true;
      }
    }
    final predicate = ignorePredicate;
    if (predicate != null && predicate(entity)) {
      return true;
    }
    return false;
  }

  static int _depthBelowRoot(String root, String dir) {
    final rel = p.relative(dir, from: root);
    if (rel == '.') {
      return 0;
    }
    final parts = p.split(rel);
    return parts.length;
  }
}

/// Reads [pubspecPath] and returns the top-level `name:` value when the
/// top level also declares a `flutter:` block; returns `null` otherwise.
///
/// Robust against malformed YAML: any read/parse failure yields `null`
/// rather than throwing, because a broken pubspec in an unrelated folder must
/// never crash a whole workspace scan.
String? extractFlutterProjectName(String pubspecPath) {
  final File file = File(pubspecPath);
  List<String> lines;
  try {
    lines = file.readAsLinesSync();
  } on FileSystemException {
    return null;
  }

  String? name;
  bool hasFlutterBlock = false;

  for (final rawLine in lines) {
    final line = rawLine.trimRight();
    // Top-level keys start at column 0.
    final isTopLevel =
        line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#');
    if (!isTopLevel) {
      continue;
    }

    if (line.startsWith('flutter:')) {
      hasFlutterBlock = true;
      continue;
    }

    if (line.startsWith('name:')) {
      final value = line.substring('name:'.length).trim();
      if (value.isNotEmpty) {
        name = _stripQuotes(value);
      }
      continue;
    }

    // Document separator — stop scanning the document.
    if (line == '---') {
      break;
    }
  }

  if (!hasFlutterBlock || name == null || name.isEmpty) {
    return null;
  }
  return name;
}

String _stripQuotes(String value) {
  final trimmed = value.trim();
  if (trimmed.length >= 2 &&
      ((trimmed.startsWith("'") && trimmed.endsWith("'")) ||
          (trimmed.startsWith('"') && trimmed.endsWith('"')))) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}
