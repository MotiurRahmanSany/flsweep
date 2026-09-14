import 'dart:io';

/// Severity levels for [Logger] output.
enum LogLevel {
  /// Plain informational output, always shown (unless fully silenced).
  info,

  /// Success confirmation (green).
  success,

  /// Warning (yellow) — shown even in quiet mode.
  warn,

  /// Error (red) — shown even in quiet mode.
  error,

  /// Verbose detail (dim), only shown in verbose mode.
  detail,
}

/// ANSI color codes used by [Logger]. Degrades gracefully when the output
/// is not a TTY (e.g. CI logs) via the [colorEnabled] flag.
abstract final class AnsiCodes {
  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String italic = '\x1B[3m';
  static const String red = '\x1B[31m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String magenta = '\x1B[35m';
  static const String cyan = '\x1B[36m';
  static const String gray = '\x1B[90m';
  static const String bgGray = '\x1B[48;5;236m';
}

/// Colorizes [message] with [code] when [enabled] is `true`.
String colorize(String message, String code, {bool enabled = true}) {
  if (!enabled || code.isEmpty) {
    return message;
  }
  return '$code$message${AnsiCodes.reset}';
}

/// Minimal colorized logger for flsweep.
///
/// Respects two switches:
///
/// * [quiet] — suppresses [info] and [detail]; [success] collapses to plain
///   text; warnings and errors are always printed (they matter).
/// * [verbose] — enables [detail] lines.
class Logger {
  /// Creates a logger writing to [out] (stdout by default).
  Logger({
    this.quiet = false,
    this.verbose = false,
    bool? color,
    IOSink? out,
  })  : _out = out ?? stdout,
        colorEnabled = color ?? stdout.hasTerminal;

  /// Whether to suppress chatter.
  final bool quiet;

  /// Whether to print dim detail lines.
  final bool verbose;

  final IOSink _out;

  /// Whether ANSI colors are emitted.
  final bool colorEnabled;

  void _write(String message) {
    _out.writeln(message);
  }

  /// Standard informational line.
  void info(String message) {
    if (quiet) {
      return;
    }
    _write(colorize(message, AnsiCodes.cyan, enabled: colorEnabled));
  }

  /// Success confirmation. In quiet mode, printed without any decoration.
  void success(String message) {
    if (quiet) {
      _write(message);
      return;
    }
    _write(
      '${colorize('✓', AnsiCodes.green, enabled: colorEnabled)} '
      '${colorize(message, AnsiCodes.bold, enabled: colorEnabled)}',
    );
  }

  /// Warning — always shown.
  void warn(String message) {
    _write(
      '${colorize('!', AnsiCodes.yellow, enabled: colorEnabled)} '
      '${colorize(message, AnsiCodes.yellow, enabled: colorEnabled)}',
    );
  }

  /// Error — always shown, even in quiet mode.
  void error(String message) {
    _write(
      '${colorize('✗', AnsiCodes.red, enabled: colorEnabled)} '
      '${colorize(message, AnsiCodes.red, enabled: colorEnabled)}',
    );
  }

  /// Dim detail line, only in verbose mode.
  void detail(String message) {
    if (!verbose) {
      return;
    }
    _write(colorize(message, AnsiCodes.dim, enabled: colorEnabled));
  }

  /// Section header rendered as a soft rule with an accent title, e.g.
  /// `── Sweep summary ──`.
  void header(String message) {
    if (quiet) {
      return;
    }
    _write(
      colorize(
        '\n── $message ──',
        '${AnsiCodes.bold}${AnsiCodes.magenta}',
        enabled: colorEnabled,
      ),
    );
  }

  /// A standout banner line for the final outcome (e.g. storage freed).
  void banner(String message) {
    if (quiet) {
      _write(message);
      return;
    }
    _write(
      colorize(
        '✨ $message',
        '${AnsiCodes.bold}${AnsiCodes.green}',
        enabled: colorEnabled,
      ),
    );
  }

  /// A thin horizontal rule used to visually group sections.
  void rule() {
    if (quiet) {
      return;
    }
    _write(colorize('· ────────────────────────────────', AnsiCodes.gray,
        enabled: colorEnabled));
  }

  /// A step line like `  ⟳ Cleaning app_name …`.
  void step(String symbol, String message) {
    if (quiet) {
      return;
    }
    _write('  ${colorize(symbol, _symbolColor(symbol, colorEnabled))} $message');
  }

  /// Maps a result symbol to its accent color.
  String _symbolColor(String symbol, bool enabled) {
    if (!enabled) {
      return '';
    }
    return switch (symbol) {
      '✓' => AnsiCodes.green,
      '✗' => AnsiCodes.red,
      '!' => AnsiCodes.yellow,
      '−' || '·' => AnsiCodes.gray,
      _ => AnsiCodes.cyan,
    };
  }

  /// Emits a blank line (skipped in quiet mode).
  void blank() {
    if (quiet) {
      return;
    }
    _write('');
  }

  /// Writes a raw line with no extra decoration. Colorized externally by
  /// callers that want a specific accent (e.g. gray box borders).
  void plain(String message) {
    if (quiet) {
      return;
    }
    _write(message);
  }
}
