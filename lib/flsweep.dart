/// flsweep — the ultimate concurrent Flutter workspace cleaner and package
/// syncer.
///
/// This library exposes the public API surface of the `flsweep` package:
///
/// * [ProjectInfo] — the model for discovered Flutter projects.
/// * Scanner / metrics / executor services under `package:flsweep/src/...`.
///
/// ```bash
/// # Clean every Flutter project under ~/dev, deep clean, 8 workers:
/// flsweep --path ~/dev --all --deep -c 8
/// ```
library flsweep;

export 'src/models/project_info.dart';
// export 'src/services/executor.dart'; // Added in the executor phase.
export 'src/services/metrics.dart';
export 'src/services/scanner.dart';
