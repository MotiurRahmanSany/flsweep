import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:flsweep/src/models/project_info.dart';
import 'package:flsweep/src/services/executor.dart';
import 'package:flsweep/src/services/metrics.dart';
import 'package:flsweep/src/services/scanner.dart';
import 'package:flsweep/src/ui/logger.dart';
import 'package:flsweep/src/ui/spinner.dart';
import 'package:flsweep/src/ui/tui.dart';

const String version = '1.0.0';

ArgParser buildParser() {
  return ArgParser()
    ..addOption(
      'path',
      abbr: 'p',
      defaultsTo: './',
      help: 'Root path to start scanning for Flutter projects.',
    )
    ..addFlag(
      'all',
      abbr: 'a',
      negatable: false,
      help: 'Non-interactive mode; process all found projects immediately.',
    )
    ..addFlag(
      'deep',
      abbr: 'd',
      negatable: false,
      help: 'Deep clean mode; removes android/.gradle, ios/Pods, .dart_tool.',
    )
    ..addOption(
      'exclude',
      abbr: 'e',
      defaultsTo: '',
      help: 'Comma-separated paths or names to ignore during scan.',
    )
    ..addFlag(
      'dry-run',
      abbr: 'n',
      negatable: false,
      help: 'Scan and display cleanable storage size without deleting '
          'anything.',
    )
    ..addOption(
      'concurrent',
      abbr: 'c',
      defaultsTo: '4',
      help: 'Maximum number of projects to clean in parallel.',
    )
    ..addFlag(
      'quiet',
      abbr: 'q',
      negatable: false,
      help: 'Suppress spinners/TUI animations; output minimal plain text.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show additional command output.',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag('version', negatable: false, help: 'Print the tool version.');
}

void printUsage(ArgParser argParser) {
  print('The ultimate concurrent Flutter workspace cleaner and package '
      'syncer.');
  print('');
  print('Usage: flsweep [path] [flags]');
  print('');
  print(argParser.usage);
}

/// Parses `--concurrent` into a positive int, falling back to [fallback].
int parseConcurrency(String? raw, Logger logger) {
  final value = int.tryParse(raw ?? '') ?? 4;
  if (value < 1) {
    logger.warn('--concurrent must be >= 1; using 1.');
    return 1;
  }
  return value;
}

/// Runs a full sweep against [rootPath] with the resolved [options].
Future<int> runSweep({
  required String rootPath,
  required bool selectAll,
  required bool deep,
  required bool dryRun,
  required bool quiet,
  required bool verbose,
  required int concurrency,
  required List<String> exclusions,
}) async {
  final logger = Logger(quiet: quiet, verbose: verbose);
  final ui = TerminalUI(logger: logger);

  // 1. Scan the workspace.
  logger.info('Scanning ${p.canonicalize(rootPath)} …');
  final scanner = Scanner(
    rootPath: rootPath,
    exclusions: exclusions,
    ignorePredicate: null,
  );
  final scan = await scanner.scan();
  if (scan.isEmpty) {
    logger.warn('No Flutter projects found under ${p.canonicalize(rootPath)}.');
    return 0;
  }
  logger.detail('Found ${scan.count} Flutter project(s).');

  // 2. Measure cleanable size per project (drives the checklist display).
  final projects = <ProjectInfo>[];
  for (final found in scan.projects) {
    final info = ProjectInfo(path: found.path, name: found.name);
    info.preCleanSize = measureCleanableSize(found.path);
    projects.add(info);
  }

  // 3. Choose projects.
  List<ProjectInfo> chosen;
  if (selectAll || quiet) {
    chosen = projects;
  } else {
    chosen = ui.selectProjects(projects);
    if (chosen.isEmpty) {
      logger.info('Nothing selected — bye.');
      return 0;
    }
  }

  ui.printPlan(
    projects: chosen,
    deep: deep,
    dryRun: dryRun,
    concurrency: concurrency,
  );

  // 4. Execute with a live spinner (suppressed in quiet mode).
  final spinner = Spinner(
    message: 'Sweeping…',
    enabled: !quiet && stdout.hasTerminal,
    logger: logger,
  );
  final executor = SweepExecutor(
    concurrency: concurrency,
    deep: deep,
    dryRun: dryRun,
    onEvent: ui.progressHandler(spinner, total: chosen.length),
  );

  final watch = Stopwatch()..start();
  spinner.start();
  List<SweepResult> results;
  try {
    results = await executor.runAll(chosen);
  } finally {
    spinner.stop();
  }
  watch.stop();

  // 5. Summary.
  var freed = 0;
  var failures = 0;
  for (final result in results) {
    // In dry-run mode nothing is deleted, so report the measured cleanable
    // size rather than the (always zero) freed delta.
    freed += dryRun ? result.project.preCleanSize : result.project.freedBytes;
    if (result.project.isFailed) {
      failures++;
    }
  }

  ui.printSummary(
    projects: chosen,
    freedBytes: freed,
    failedCount: failures,
    elapsed: watch.elapsed,
    dryRun: dryRun,
  );

  // Non-blocking behavior: failures never crash the tool; they only set the
  // exit code so CI can react.
  return failures == 0 ? 0 : 1;
}

Future<void> main(List<String> arguments) async {
  final argParser = buildParser();
  late ArgResults results;
  try {
    results = argParser.parse(arguments);
  } on FormatException catch (error) {
    print(error.message);
    print('');
    printUsage(argParser);
    exitCode = 64; // EX_USAGE
    return;
  }

  if (results.flag('help')) {
    printUsage(argParser);
    return;
  }
  if (results.flag('version')) {
    print('flsweep $version');
    return;
  }

  final logger = Logger(
    quiet: results.flag('quiet'),
    verbose: results.flag('verbose'),
  );

  // Positional [path] wins over --path for ergonomic `flsweep ~/dev` usage.
  final positional = results.rest;
  final rootPath = positional.isNotEmpty
      ? positional.first
      : (results['path'] as String? ?? './');

  if (!Directory(rootPath).existsSync()) {
    logger.error('Path does not exist: ${p.canonicalize(rootPath)}');
    exitCode = 66; // EX_NOINPUT
    return;
  }

  final exclusions = (results['exclude'] as String? ?? '')
      .split(',')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();

  try {
    exitCode = await runSweep(
      rootPath: rootPath,
      selectAll: results.flag('all'),
      deep: results.flag('deep'),
      dryRun: results.flag('dry-run'),
      quiet: results.flag('quiet'),
      verbose: results.flag('verbose'),
      concurrency: parseConcurrency(results['concurrent'] as String?, logger),
      exclusions: exclusions,
    );
  } catch (error, stackTrace) {
    // Final safety net: flsweep must never crash with a raw stack trace.
    logger.error('Unexpected failure: $error');
    logger.detail(stackTrace.toString());
    exitCode = 70; // EX_SOFTWARE
  }
}
