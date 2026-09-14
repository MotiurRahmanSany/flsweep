import 'dart:io';

import 'package:dart_console/dart_console.dart';

import 'logger.dart';

/// Pure state machine for an interactive multi-select checklist.
///
/// Kept free of any I/O so the toggle-all semantics (the reason this
/// first-party component exists) can be unit-tested directly:
///
/// * [toggleAll] — `a` key: selects everything when anything is unchecked,
///   otherwise clears everything.
/// * [toggleCurrent] — `space` key: flips the row under [cursor].
/// * [moveUp] / [moveDown] — `↑`/`↓` (or `k`/`j`): wrap around the ends.
class ChecklistState {
  /// Creates state for [itemCount] rows with optional [defaults].
  ///
  /// Throws [ArgumentError] when [itemCount] is not positive or [defaults]
  /// has a mismatched length.
  ChecklistState({required int itemCount, List<bool>? defaults})
      : checked = List<bool>.generate(
          itemCount,
          (index) => defaults?[index] ?? false,
        ) {
    if (itemCount <= 0) {
      throw ArgumentError.value(itemCount, 'itemCount', 'must be positive');
    }
    if (defaults != null && defaults.length != itemCount) {
      throw ArgumentError.value(
        defaults,
        'defaults',
        'must have length $itemCount',
      );
    }
  }

  /// Checked state per row.
  final List<bool> checked;

  /// Row the cursor currently sits on.
  int cursor = 0;

  /// Number of rows.
  int get itemCount => checked.length;

  /// Whether every row is checked.
  bool get allSelected => checked.every((checked) => checked);

  /// Whether no row is checked.
  bool get noneSelected => checked.every((checked) => !checked);

  /// Moves the cursor up one row, wrapping to the last row.
  void moveUp() {
    cursor = (cursor - 1 + itemCount) % itemCount;
  }

  /// Moves the cursor down one row, wrapping to the first row.
  void moveDown() {
    cursor = (cursor + 1) % itemCount;
  }

  /// Flips the checked state of the row under the cursor.
  void toggleCurrent() {
    checked[cursor] = !checked[cursor];
  }

  /// The `a` key: select everything when anything is unchecked, otherwise
  /// clear everything. Returns the resulting all-selected state.
  bool toggleAll() {
    final target = !allSelected;
    for (var index = 0; index < itemCount; index++) {
      checked[index] = target;
    }
    return target;
  }

  /// Checked row indices in ascending order.
  List<int> get selectedIndices => <int>[
        for (var index = 0; index < itemCount; index++)
          if (checked[index]) index,
      ];
}

/// A first-party interactive multi-select checklist.
///
/// Built directly on `dart_console` instead of `interact`, whose
/// `MultiSelect` has no toggle-all key. Supported keys:
///
/// * `↑` / `↓` (or `k` / `j`) — move the cursor.
/// * `space` — toggle the item under the cursor.
/// * `a` / `A` — toggle **all** items at once.
/// * `enter` — confirm the current selection.
/// * `q` — abort with an empty selection.
/// * `ctrl+c` — abort gracefully (the process keeps running so the caller
///   can fall back or exit cleanly).
///
/// Rendering is ANSI-line-wipe based; callers on non-TTY streams must not
/// use this class — `TerminalUI` already gates it behind `hasTerminal`.
class MultiSelectChecklist {
  /// Creates a checklist with [prompt], [options], and optional [defaults].
  ///
  /// Throws [ArgumentError] when [options] is empty or [defaults] has a
  /// mismatched length.
  MultiSelectChecklist({
    required this.prompt,
    required this.options,
    this.defaults,
    this.colorEnabled = true,
  }) {
    if (options.isEmpty) {
      throw ArgumentError.value(options, 'options', 'must not be empty');
    }
    if (defaults != null && defaults!.length != options.length) {
      throw ArgumentError.value(
        defaults,
        'defaults',
        'must have the same length as options',
      );
    }
  }

  /// Header message shown above the checklist.
  final String prompt;

  /// Display labels, one per row.
  final List<String> options;

  /// Initial checked state per row (defaults to all unchecked).
  final List<bool>? defaults;

  /// Whether ANSI colors are emitted.
  final bool colorEnabled;

  final Console _console = Console();

  int _renderedLines = 0;
  bool _aborted = false;

  /// True when the user aborted via `q` or `ctrl+c` (selection is empty).
  bool get aborted => _aborted;

  /// Runs the interactive loop and returns the checked indices in order.
  List<int> interact() {
    final state = ChecklistState(
      itemCount: options.length,
      defaults: defaults,
    );

    _console.hideCursor();
    try {
      _render(state);
      while (true) {
        final key = _readKey();
        if (key.isControl) {
          switch (key.controlChar) {
            case ControlCharacter.arrowUp:
              state.moveUp();
              _render(state);
            case ControlCharacter.arrowDown:
              state.moveDown();
              _render(state);
            case ControlCharacter.enter:
              return _result(state);
            case ControlCharacter.ctrlC:
              _aborted = true;
              return _result(state);
            default:
              break;
          }
        } else {
          switch (key.char) {
            case ' ':
              state.toggleCurrent();
              _renderRow(state, state.cursor);
            case 'a':
            case 'A':
              state.toggleAll();
              _render(state);
            case 'j':
              state.moveDown();
              _render(state);
            case 'k':
              state.moveUp();
              _render(state);
            case 'q':
            case 'Q':
              _aborted = true;
              return _result(state);
            default:
              break;
          }
        }
      }
    } finally {
      _console.showCursor();
    }
  }

  /// Reads one key with `ctrl+c` intercepted so an interrupt aborts the
  /// checklist instead of killing the whole process.
  Key _readKey() {
    final console = _console;
    while (true) {
      final key = console.readKey();
      if (key.isControl && key.controlChar == ControlCharacter.ctrlC) {
        return key;
      }
      // Ignore resize/other events we cannot act on.
      if (key.isControl && key.controlChar == ControlCharacter.unknown) {
        continue;
      }
      return key;
    }
  }

  List<int> _result(ChecklistState state) {
    if (_aborted) {
      for (var index = 0; index < state.itemCount; index++) {
        state.checked[index] = false;
      }
    }
    _finish(state);
    return state.selectedIndices;
  }

  void _finish(ChecklistState state) {
    _erase();
    final selected = state.selectedIndices.length;
    final summary = _aborted
        ? 'aborted — nothing selected'
        : '$selected of ${options.length} selected';
    stdout.writeln(
      '${colorize('✔', AnsiCodes.green, enabled: colorEnabled)}'
      ' $prompt '
      '${colorize(summary, AnsiCodes.dim, enabled: colorEnabled)}',
    );
  }

  void _render(ChecklistState state) {
    _erase();
    stdout.writeln(
      '${colorize('✔', AnsiCodes.cyan, enabled: colorEnabled)}'
      ' $prompt '
      '${colorize(
        '(↑/↓ move, space toggle, a toggle all, enter confirm, q quit)',
        AnsiCodes.dim,
        enabled: colorEnabled,
      )}',
    );
    for (var index = 0; index < options.length; index++) {
      stdout.writeln(_rowLabel(state, index));
    }
    stdout.writeln();
    stdout.writeln(
      colorize(
        '  ${_badge(state)} selected — press enter to confirm, q to quit',
        AnsiCodes.gray,
        enabled: colorEnabled,
      ),
    );
    _renderedLines = options.length + 3;
  }

  String _badge(ChecklistState state) {
    final count = state.selectedIndices.length;
    final total = state.itemCount;
    final mark = colorize(
      '$count/$total',
      count == 0
          ? AnsiCodes.gray
          : count == total
              ? AnsiCodes.green
              : AnsiCodes.cyan,
      enabled: colorEnabled,
    );
    return mark;
  }

  /// Redraws a single row in place (used by the `space` toggle so pressing
  /// it does not flash the whole list).
  void _renderRow(ChecklistState state, int index) {
    final up = _renderedLines - 1 - index;
    stdout
      ..write('\x1B[${up}A') // up to the row
      ..write('\x1B[2K\r') // clear it, back to column 0
      ..write(_rowLabel(state, index))
      ..write('\x1B[${up}B\r'); // back down to the home row
  }

  String _rowLabel(ChecklistState state, int index) {
    final checked = state.checked[index];
    final checkbox = checked
        ? colorize('◉', AnsiCodes.green, enabled: colorEnabled)
        : colorize('○', AnsiCodes.gray, enabled: colorEnabled);
    final label = _truncate(options[index]);
    final name = ' $label';
    if (index == state.cursor) {
      return '${colorize('❯', AnsiCodes.magenta, enabled: colorEnabled)}'
          '${colorize('[', AnsiCodes.magenta, enabled: colorEnabled)}'
          '$checkbox'
          '${colorize(']', AnsiCodes.magenta, enabled: colorEnabled)}'
          '${colorize(name, AnsiCodes.bold, enabled: colorEnabled)}';
    }
    return ' $checkbox$name';
  }

  /// Long labels would wrap and break the line-count math, so clip them to
  /// the terminal width (minus room for the cursor glyph and checkbox).
  String _truncate(String label) {
    var width = 80;
    try {
      width = _console.windowWidth;
    } catch (_) {
      // Non-TTY or unsupported ioctl — keep the 80-column default.
    }
    final maxWidth = width - 8;
    if (label.length <= maxWidth) {
      return label;
    }
    return '${label.substring(0, maxWidth - 1)}…';
  }

  void _erase() {
    for (var i = 0; i < _renderedLines; i++) {
      stdout.write('\x1B[1A\x1B[2K');
    }
    _renderedLines = 0;
  }
}
