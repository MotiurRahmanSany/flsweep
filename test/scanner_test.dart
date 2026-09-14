import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:flsweep/src/services/scanner.dart';

/// Creates `pubspec.yaml` content for a Flutter app.
String flutterPubspec(String name, {bool flutter = true}) => '''
name: $name
description: A test fixture.
environment:
  sdk: '>=3.0.0 <4.0.0'

${flutter ? 'flutter:\n  uses-material-design: true\n' : ''}dependencies:
  flutter:
    sdk: flutter
''';

/// Creates `pubspec.yaml` content for a plain Dart package.
String dartPubspec(String name) => '''
name: $name
description: A plain Dart package.
environment:
  sdk: '>=3.0.0 <4.0.0'
''';

/// Creates `name/pubspec.yaml` under [workspace] and returns its path.
String makeProject(Directory workspace, String name,
    {bool flutter = true, String? prefix}) {
  final dir = Directory(p.joinAll([
    workspace.path,
    if (prefix != null) ...p.split(prefix),
    name,
  ]))
    ..createSync(recursive: true);
  final file = File(p.join(dir.path, 'pubspec.yaml'))
    ..writeAsStringSync(flutterPubspec(name, flutter: flutter));
  return file.path;
}

/// Wraps a path string for tests that need a [File] handle.
File pubspecFile(String path) => File(path);

void main() {
  late Directory workspace;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('flsweep_scanner_test_');
  });

  tearDown(() {
    try {
      workspace.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup; never fail the test suite on a lock.
    }
  });

  group('extractFlutterProjectName', () {
    test('returns name when a top-level flutter block exists', () {
      final pubspecPath = makeProject(workspace, 'my_app');
      expect(extractFlutterProjectName(pubspecPath), 'my_app');
    });

    test('returns null for a plain Dart package', () {
      final dir = Directory(p.join(workspace.path, 'plain_pkg'))..createSync();
      final file = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync(dartPubspec('plain_pkg'));
      expect(extractFlutterProjectName(file.path), isNull);
    });

    test('ignores nested flutter-like keys (indentation matters)', () {
      final dir = Directory(p.join(workspace.path, 'nested_key'))..createSync();
      final file = File(p.join(dir.path, 'pubspec.yaml'))..writeAsStringSync('''
name: nested_key
dependencies:
  some_plugin:
    flutter: true
''');
      expect(extractFlutterProjectName(file.path), isNull);
    });

    test('handles quoted names', () {
      final dir = Directory(p.join(workspace.path, 'quoted'))..createSync();
      final file = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync("name: 'quoted_app'\nflutter:\n  assets:\n");
      expect(extractFlutterProjectName(file.path), 'quoted_app');
    });

    test('returns null on malformed pubspec without crashing', () {
      final dir = Directory(p.join(workspace.path, 'broken'))..createSync();
      final file = File(p.join(dir.path, 'pubspec.yaml'))
        ..writeAsStringSync('@@@ :::: not yaml at all {\n');
      expect(extractFlutterProjectName(file.path), isNull);
    });

    test('returns null when file is missing', () {
      expect(
        extractFlutterProjectName(
          p.join(workspace.path, 'nope', 'pubspec.yaml'),
        ),
        isNull,
      );
    });
  });

  group('Scanner', () {
    test('discovers Flutter projects and skips plain Dart packages', () async {
      makeProject(workspace, 'app_one');
      makeProject(workspace, 'app_two');
      makeProject(workspace, 'plain_pkg', flutter: false);

      final scanner = Scanner(rootPath: workspace.path);
      final result = await scanner.scan();

      expect(result.count, 2);
      final names = result.projects.map((pr) => pr.name).toSet();
      expect(names, {'app_one', 'app_two'});
    });

    test('skips node_modules, .git, and other built-in ignored dirs', () async {
      makeProject(workspace, 'real_app');
      makeProject(workspace, 'dep_app', prefix: 'node_modules/dep');
      makeProject(workspace, 'git_app', prefix: '.git/hooks');
      makeProject(workspace, 'pub_app', prefix: '.pub-cache/hosted');
      makeProject(workspace, 'hidden_app', prefix: '.hidden/app');

      final result = await Scanner(rootPath: workspace.path).scan();

      expect(result.count, 1);
      expect(result.projects.single.name, 'real_app');
    });

    test('skips build and .dart_tool directories during traversal', () async {
      makeProject(workspace, 'main_app');
      makeProject(workspace, 'built_app', prefix: 'build/outputs');
      makeProject(workspace, 'tool_app', prefix: '.dart_tool/package_config');

      final result = await Scanner(rootPath: workspace.path).scan();

      expect(result.count, 1);
      expect(result.projects.single.name, 'main_app');
    });

    test('honors --exclude by directory name', () async {
      makeProject(workspace, 'keep_me');
      makeProject(workspace, 'skip_me');

      final result = await Scanner(
        rootPath: workspace.path,
        exclusions: ['skip_me'],
      ).scan();

      expect(result.count, 1);
      expect(result.projects.single.name, 'keep_me');
    });

    test('honors --exclude by relative path', () async {
      makeProject(workspace, 'a_project', prefix: 'packages/one');
      makeProject(workspace, 'b_project', prefix: 'packages/two');

      final result = await Scanner(
        rootPath: workspace.path,
        exclusions: ['packages/two'],
      ).scan();

      expect(result.count, 1);
      expect(result.projects.single.name, 'a_project');
    });

    test('does not descend into a discovered Flutter project', () async {
      makeProject(workspace, 'outer');
      makeProject(workspace, 'inner', prefix: 'outer/inner');

      final result = await Scanner(rootPath: workspace.path).scan();

      expect(result.count, 1);
      expect(result.projects.single.name, 'outer');
    });

    test('returns empty result for an unknown root', () async {
      final result = await Scanner(
        rootPath: p.join(workspace.path, 'does_not_exist'),
      ).scan();
      expect(result.isEmpty, isTrue);
    });

    test('reports projects with canonical absolute paths', () async {
      makeProject(workspace, 'canon_app');
      final result = await Scanner(rootPath: workspace.path).scan();
      final project = result.projects.single;
      expect(p.isAbsolute(project.path), isTrue);
      expect(p.equals(project.path, p.canonicalize(project.path)), isTrue);
      expect(project.path, endsWith('canon_app'));
    });

    test('scanStream yields projects lazily', () async {
      makeProject(workspace, 's_one');
      makeProject(workspace, 's_two');

      final scanner = Scanner(rootPath: workspace.path);
      final names = <String>[];
      await for (final project in scanner.scanStream()) {
        names.add(project.name);
      }
      expect(names, containsAll(['s_one', 's_two']));
    });
  });
}
