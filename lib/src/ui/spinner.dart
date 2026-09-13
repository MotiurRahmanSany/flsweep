import 'dart:async';
import 'dart:io';

import 'logger.dart';

/// Braille spinner frames — the classic smooth "dot spinner".
const List<String> kBrailleFrames = <String>[
  '⠋',
  '⠙',
  '⠹',
  '⠸',
  '⠼',
  '⠴',
  '⠦',
  '⠧',
  '⠇',
  '⠏',
];

/// An animated terminal spinner that renders on a single line.
///
/// Works on every terminal that understands carriage returns (Linux, macOS,
/// Windows Terminal). When [enabled] is `false` (e.g. `--quiet` or output is
/// piped), the spinner becomes a no-op and simply logs the start and end of
/// the operation — which keeps CI logs clean and linear.
class Spinner {
  /// Creates a spinner. Rendering only happens when [enabled] is `true`.
  Spinner({
    required this.message,
    this.enabled = true,
    this.frames = kBrailleFrames,
    this.interval = const Duration(milliseconds: 80),
    Logger? logger,
  }) : _logger = logger ??
            Logger(
              quiet: true,
              color: stdout.hasTerminal,
            );

  /// Current message shown next to the spinner glyph.
  String message;

  /// Whether animation is allowed.
  final bool enabled;

  /// Frame sequence to cycle through.
  final List<String> frames;

  /// Time between frame renders.
  final Duration interval;

  final Logger _logger;

  Timer? _timer;
  int _frameIndex = 0;

  /// Starts the animation.
  void start() {
    if (!enabled || _timer != null) {
      if (!enabled) {
        // eslint-disable-next-line
        _logger.step('…', message);
      }
      return;
    }
    _render();
    _timer = Timer.periodic(interval, (_) {
      _frameIndex = (_frameIndex + 1) % frames.length;
      _render();
    });
  }

  void _render() {
    final frame = frames[_frameIndex];
    stdout.write('\r$frame $message\x1B[K');
  }

  /// Updates the message while spinning.
  void update(String newMessage) {
    message = newMessage;
    if (!enabled) {
      return;
    }
    if (_timer == null) {
      start();
    }
  }

  /// Stops the animation and clears the line.
  ///
  /// When [finalMessage] is provided, it is printed as a normal log line
  /// (with [symbol] prefix, e.g. `✓` or `✗`) so the completed state persists
  /// in the scrollback.
  void stop({String? finalMessage, String symbol = '✓'}) {
    _timer?.cancel();
    _timer = null;
    if (!enabled) {
      return;
    }
    // Clear the animated line.
    stdout.write('\r\x1B[K');
    if (finalMessage != null) {
      _logger.step(symbol, finalMessage);
    }
  }

  /// Convenience wrapper: runs [action] under the spinner and returns its
  /// result. Exceptions stop the spinner with a red `✗` and are rethrown.
  Future<T> run<T>(Future<T> Function() action) async {
    start();
    try {
      final result = await action();
      stop();
      return result;
    } catch (error) {
      stop(finalMessage: message, symbol: '✗');
      rethrow;
    }
  }
}
