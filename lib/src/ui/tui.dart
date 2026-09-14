import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/project_info.dart';
import '../services/executor.dart';
import '../services/metrics.dart' show formatBytes;
import 'checklist.dart';
import 'logger.dart';
import 'spinner.dart';

/// Parses a checklist selection expression into zero-based indices.
///
/// Supported syntax:
///
/// * `1,3-5` — single indices and inclusive ranges (1-based, as displayed).
/// * `a` / `all` — every index.
/// * `q` / `quit` — empty selection (abort).
///
/// Out-of-range indices are dropped silently. Anything else raises a
/// [FormatException] so callers can re-prompt.
Set<int> parseSelection(String input, int count) {
  final trimmed = input.trim().toLowerCase();
  if (trimmed.isEmpty) {
    throw const FormatException('Empty selection');
  }
  if (trimmed == 'q' || trimmed == 'quit') {
    return <int>{};
  }
  if (trimmed == 'a' || trimmed == 'all' || trimmed == '*') {
    return <int>{for (var i = 0; i < count; i++) i};
  }

  final selected = <int>{};
  for (final part in trimmed.split(RegExp(r'[,\s]+'))) {
    if (part.isEmpty) {
      continue;
    }
    final rangeMatch = RegExp(r'^(\d+)\s*-\s*(\d+)$').firstMatch(part);
    if (rangeMatch != null) {
      final start = int.parse(rangeMatch.group(1)!);
      final end = int.parse(rangeMatch.group(2)!);
      final lo = start < end ? start : end;
      final hi = start < end ? end : start;
      for (var n = lo; n <= hi; n++) {
        if (n >= 1 && n <= count) {
          selected.add(n - 1);
        }
      }
      continue;
    }
    final n = int.tryParse(part);
    if (n == null) {
      throw FormatException('Invalid selection: "$part"');
    }
    if (n >= 1 && n <= count) {
      selected.add(n - 1);
    }
  }
  return selected;
}

/// Renders the numbered checklist shown by the interactive prompt.
List<String> renderChecklist(List<ProjectInfo> projects) {
  final lines = <String>[];
  for (var i = 0; i < projects.length; i++) {
    final project = projects[i];
    final size = formatBytes(project.preCleanSize);
    final rel = p.basename(project.path);
    lines.add('${i + 1}) ${rel.padRight(24)} $size');
  }
  return lines;
}

/// Interactive terminal UI for flsweep.
///
/// The checklist uses flsweep's first-party arrow-key multi-select (with
/// `a` toggle-all support) when a real terminal is attached and gracefully
/// degrades to a numbered prompt that works over pipes and SSH without a
/// TTY.
class TerminalUI {
  /// Creates a UI bound to [logger].
  TerminalUI({required this.logger, this.useInteractive = true});

  final Logger logger;

  /// Whether the arrow-key checklist may be attempted.
  final bool useInteractive;

  /// Asks the user which projects to sweep.
  ///
  /// Returns the chosen subset (possibly empty = abort). When the checklist
  /// is aborted or nothing is chosen, an empty list is returned.
  List<ProjectInfo> selectProjects(List<ProjectInfo> projects) {
    if (projects.isEmpty) {
      logger.warn('No Flutter projects found — nothing to sweep.');
      return const <ProjectInfo>[];
    }

    logger.header('Flutter projects discovered: ${projects.length}');

    if (_canUseInteractiveChecklist()) {
      try {
        final checklist = MultiSelectChecklist(
          prompt: 'Select projects to sweep',
          options: <String>[
            for (final project in projects)
              '${p.basename(project.path)}  (${formatBytes(project.preCleanSize)})',
          ],
          colorEnabled: logger.colorEnabled,
        );
        final chosen = checklist.interact();
        if (checklist.aborted) {
          return const <ProjectInfo>[];
        }
        return [for (final index in chosen) projects[index]];
      } catch (error) {
        logger.detail(
          'Interactive checklist unavailable (${error.toString().trim()}); '
          'falling back to numbered prompt.',
        );
      }
    }

    return _numberedPrompt(projects);
  }

  bool _canUseInteractiveChecklist() {
    if (!useInteractive) {
      return false;
    }
    try {
      return stdin.hasTerminal && stdout.hasTerminal;
    } on StdoutException {
      return false;
    }
  }

  List<ProjectInfo> _numberedPrompt(List<ProjectInfo> projects) {
    for (final line in renderChecklist(projects)) {
      logger.info(line);
    }
    logger.info(
      'Enter numbers to sweep (e.g. 1,3-5), "a" for all, "q" to quit:',
    );

    while (true) {
      stdout.write('> ');
      final line = stdin.readLineSync();
      if (line == null) {
        return const <ProjectInfo>[];
      }
      try {
        final indices = parseSelection(line, projects.length);
        return [for (final index in indices) projects[index]];
      } on FormatException {
        logger.warn('Invalid selection, try again (e.g. 1,3-5 or "a").');
      }
    }
  }

  /// Prints the sweep plan before execution starts.
  void printPlan({
    required List<ProjectInfo> projects,
    required bool deep,
    required bool dryRun,
    required int concurrency,
  }) {
    logger.header(
      dryRun
          ? 'Dry run — measuring ${projects.length} projects (nothing deleted)'
          : 'Sweeping ${projects.length} projects',
    );
    logger.detail(
      'mode=${deep ? 'deep clean' : 'standard'} '
      'concurrency=$concurrency '
      'dryRun=$dryRun',
    );
  }

  /// Builds an event handler that renders live progress via [spinner].
  ///
  /// [total] is the number of projects in the run. The spinner shows overall
  /// progress ("[3/10] current_project"); on quiet mode only failures reach
  /// the terminal, keeping CI logs useful.
  void Function(SweepEvent event) progressHandler(
    Spinner spinner, {
    required int total,
  }) {
    var finished = 0;
    return (SweepEvent event) {
      switch (event.status) {
        case ProjectStatus.cleaning:
        case ProjectStatus.deepCleaning:
        case ProjectStatus.syncing:
        case ProjectStatus.queued:
          final active = p.basename(event.project.path);
          spinner.update('[$finished/$total] $active — ${event.status.name}');
        case ProjectStatus.completed:
          finished++;
          spinner.stop(
            finalMessage: '${p.basename(event.project.path)} — freed '
                '${formatBytes(event.project.freedBytes)}',
            symbol: '✓',
          );
          spinner.start();
        case ProjectStatus.failed:
          finished++;
          spinner.stop(
            finalMessage:
                '${p.basename(event.project.path)} — ${event.project.error ?? "failed"}',
            symbol: '✗',
          );
          spinner.start();
        case ProjectStatus.discovered:
        case ProjectStatus.skipped:
          break;
      }
    };
  }

  /// Prints the final summary table.
  ///
  /// [freedBytes] is the aggregate recovered storage; [failedCount] and
  /// [dryRun] adjust the closing lines.
  void printSummary({
    required List<ProjectInfo> projects,
    required int freedBytes,
    required int failedCount,
    required Duration elapsed,
    required bool dryRun,
  }) {
    logger.blank();
    logger.header('Sweep summary');

    for (final project in projects) {
      final name = p.basename(project.path).padRight(24);
      switch (project.status) {
        case ProjectStatus.completed:
          // In dry-run nothing is deleted, so freedBytes stays 0 — report the
          // measured cleanable size instead, matching the total.
          final bytes = dryRun ? project.preCleanSize : project.freedBytes;
          logger.step(
            '✓',
            '$name ${dryRun ? "cleanable" : "freed"} ${formatBytes(bytes)}',
          );
        case ProjectStatus.failed:
          logger.step(
            '✗',
            '$name ${project.error ?? "failed"}',
          );
        case ProjectStatus.skipped:
          logger.step('−', '$name skipped');
        default:
          logger.step('·', '$name ${project.status.name}');
      }
    }

    logger.blank();
    final succeeded = projects.length - failedCount;
    if (dryRun) {
      logger.success(
        'Would free ${formatBytes(freedBytes)} across $succeeded project(s).',
      );
    } else {
      logger.success(
        'Freed ${formatBytes(freedBytes)} — $succeeded ok, '
        '$failedCount failed.',
      );
    }
    logger.detail('Elapsed: ${elapsed.inSeconds}s');
  }
}
