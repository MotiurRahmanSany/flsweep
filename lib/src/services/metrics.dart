import 'dart:io';

import 'package:path/path.dart' as p;

/// Top-level artifact directories/files that flsweep treats as cleanable.
const String kBuildDirName = 'build';
const String kDartToolDirName = '.dart_tool';
const String kGradleDirName = '.gradle';
const String kPodsDirName = 'Pods';
const String kPodfileLockName = 'Podfile.lock';

/// Returns `true` when [path] is a directory that actually exists on disk.
bool directoryExists(String path) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: true) ==
        FileSystemEntityType.directory;
  } on FileSystemException {
    return false;
  }
}

/// Returns the names of cleanable artifacts present inside [projectPath].
///
/// Reported names follow the constants above (`build`, `.dart_tool`,
/// `.gradle`, `Pods`, `Podfile.lock`). `.gradle`/`Pods`/`Podfile.lock` are
/// only reported when their parent platform folder (`android` / `ios`)
/// exists, matching where `flutter clean`-adjacent artifacts actually live.
List<String> detectCleanableTargets(String projectPath) {
  final targets = <String>[];

  void addDir(String fsPath, String label) {
    if (directoryExists(fsPath)) {
      targets.add(label);
    }
  }

  addDir(p.join(projectPath, kBuildDirName), kBuildDirName);
  addDir(p.join(projectPath, kDartToolDirName), kDartToolDirName);
  addDir(
    p.join(projectPath, 'android', kGradleDirName),
    kGradleDirName,
  );
  addDir(p.join(projectPath, 'ios', kPodsDirName), kPodsDirName);

  final podfileLock = p.join(projectPath, 'ios', kPodfileLockName);
  if (FileSystemEntity.typeSync(podfileLock, followLinks: true) ==
      FileSystemEntityType.file) {
    targets.add(kPodfileLockName);
  }

  return targets;
}

/// Computes the total size in bytes of [targetPath] recursively.
///
/// Returns 0 when the path does not exist, is a file (for the directory-only
/// contract use [pathSize]), or cannot be read. Symlinks are *not* followed,
/// so a stray symlink pointing at a huge external directory can never blow up
/// the reported size — nor can symlink loops cause infinite recursion.
int directorySize(String targetPath) {
  return pathSize(targetPath, followLinks: false);
}

/// Computes the size in bytes of [targetPath], either recursively for
/// directories or the file size for a single file.
///
/// [followLinks] is `false` by default: symlinks count as themselves, never
/// as their targets. Unreadable entries contribute 0 bytes and are skipped
/// silently — flsweep reports best-effort numbers, it never crashes on a
/// permission error in a third-party folder.
int pathSize(String targetPath, {bool followLinks = false}) {
  try {
    final type = FileSystemEntity.typeSync(targetPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return 0;
    }
    if (type == FileSystemEntityType.link) {
      // The link itself; its target is only counted when the caller asked.
      if (!followLinks) {
        return 0;
      }
      final real = FileSystemEntity.typeSync(targetPath, followLinks: true);
      if (real == FileSystemEntityType.file) {
        return File(targetPath).lengthSync();
      }
      if (real == FileSystemEntityType.directory) {
        return pathSize(targetPath, followLinks: true);
      }
      return 0;
    }
    if (type == FileSystemEntityType.file) {
      return File(targetPath).lengthSync();
    }
    if (type == FileSystemEntityType.directory) {
      var total = 0;
      final List<FileSystemEntity> entities;
      try {
        entities = Directory(targetPath).listSync(followLinks: false);
      } on FileSystemException {
        return total;
      }
      for (final entity in entities) {
        total += pathSize(entity.path, followLinks: followLinks);
      }
      return total;
    }
    return 0;
  } on FileSystemException {
    return 0;
  }
}

/// Sums the sizes of the standard cleanable artifacts in [projectPath].
///
/// This is the number reported as "pre-clean size" for a project.
int measureCleanableSize(String projectPath) {
  var total = 0;
  for (final target in detectCleanableTargets(projectPath)) {
    total += _targetSize(projectPath, target);
  }
  return total;
}

/// Computes the size of a single named target inside [projectPath].
int _targetSize(String projectPath, String target) {
  switch (target) {
    case kBuildDirName:
      return directorySize(p.join(projectPath, kBuildDirName));
    case kDartToolDirName:
      return directorySize(p.join(projectPath, kDartToolDirName));
    case kGradleDirName:
      return directorySize(p.join(projectPath, 'android', kGradleDirName));
    case kPodsDirName:
      return directorySize(p.join(projectPath, 'ios', kPodsDirName));
    case kPodfileLockName:
      return pathSize(p.join(projectPath, 'ios', kPodfileLockName));
    default:
      return 0;
  }
}

/// Human-readable size formatting used across the whole CLI.
///
/// * Below 1024 bytes → `123 B`
/// * Below 1 MiB → `45.2 KB`
/// * Below 1 GiB → `678.9 MB`
/// * Otherwise → `2.45 GB`
String formatBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  if (unit == 0) {
    return '${bytes}B';
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : (value >= 10 ? 1 : 2))} ${units[unit]}';
}
