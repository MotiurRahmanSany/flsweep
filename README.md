# flsweep 🧹⚡

**The ultimate concurrent Flutter workspace cleaner and package syncer.**

`flsweep` is a high-performance, cross-platform CLI tool written in pure Dart.
It scans any workspace for Flutter projects, batch-runs `flutter clean`,
deep-cleans stubborn native build artifacts, and immediately restores
dependencies with `flutter pub get` — so your IDE symbols and indices come
back instantly. Every byte recovered is measured and reported.

```text
$ flsweep ~/dev --all --deep -c 8

  Flutter projects discovered: 12

  Sweeping 12 projects
  ✓ shop_app               freed 1.21 GB
  ✓ tracker                freed 312.4 MB
  ✗ legacy_client          flutter clean failed (exit 1): ...
  ✓ portfolio              freed 890.7 MB
  ...

  Sweep summary
  ✓ Freed 2.45 GB — 11 ok, 1 failed.
```

---

## ✨ Features

- **Parallel execution** — a bounded async worker pool cleans up to
  `--concurrent` projects at once (default: 4).
- **Zero-break sync** — `flutter clean` ➔ `flutter pub get` run back-to-back
  per project, so every project stays buildable and IDE-friendly.
- **Deep clean (`--deep`)** — wipes what `flutter clean` leaves behind:
  `android/.gradle`, `ios/Pods`, `ios/Podfile.lock`, and `.dart_tool`.
- **Exact disk metrics** — recursive size calculation (B/KB/MB/GB) before and
  after cleaning; the summary reports precisely what was recovered.
- **Dual interface** — an interactive multi-select checklist with live braille
  spinners, *and* a fully non-interactive headless mode for CI/CD and AI
  agents (`--all --quiet`).
- **Error isolation** — one broken project never aborts the run. Failures are
  logged, the remaining projects keep processing, and the exit code signals
  the outcome to CI.

---

## 📦 Installation

### From source (requires the [Dart SDK](https://dart.dev/get-dart) ≥ 3.0)

```bash
git clone <your-fork-url> flsweep
cd flsweep
dart pub get
dart pub global activate --source path .
```

After global activation, `flsweep` is available on your `PATH`.

### One-off runs without installing

```bash
dart run bin/flsweep.dart [path] [flags]
```

---

## 🚦 Usage

```text
flsweep [path] [flags]
```

The first positional argument, if given, overrides `--path`.

### Flags

| Flag | Short | Type | Default | Description |
| --- | --- | --- | --- | --- |
| `--path` | `-p` | String | `./` | Root path to start scanning for Flutter projects. |
| `--all` | `-a` | Bool | `false` | Non-interactive mode; process all found projects immediately. |
| `--deep` | `-d` | Bool | `false` | Deep clean mode; removes `android/.gradle`, `ios/Pods`, `.dart_tool`. |
| `--exclude` | `-e` | String | `""` | Comma-separated paths or names to ignore during scan. |
| `--dry-run` | `-n` | Bool | `false` | Scan and display cleanable storage size without deleting anything. |
| `--concurrent` | `-c` | Int | `4` | Maximum number of projects to clean in parallel. |
| `--quiet` | `-q` | Bool | `false` | Suppress spinners/TUI animations; output minimal plain text. |
| `--verbose` | `-v` | Bool | `false` | Show additional command output. |
| `--help` | `-h` | Bool | `false` | Print usage information. |
| `--version` | | Bool | `false` | Print the tool version. |

### Examples

Preview how much space a workspace could reclaim — touches nothing:

```bash
flsweep ~/dev --dry-run
```

Clean everything in a workspace, quietly, for a CI cron job:

```bash
flsweep ~/workspaces --all --quiet
```

Deep clean with 8 parallel workers, skipping a legacy monorepo and vendor dirs:

```bash
flsweep ~/dev --all --deep -c 8 --exclude legacy_monorepo,vendored
```

Point at a single project and interactively confirm:

```bash
flsweep ~/dev/my_app
```

Restore dependencies only, without cleaning:

```bash
# flsweep always runs pub get after clean; use --dry-run first to audit.
flsweep ~/dev --all
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (including a clean dry run). |
| `1` | At least one project failed during the sweep (the rest still completed). |
| `64` | Invalid command-line usage. |
| `66` | The given path does not exist. |
| `70` | An unexpected internal error. |

---

## 🏗 Architecture

```text
flsweep/
├── bin/
│   └── flsweep.dart          # CLI entry point, flag parsing, and route dispatching
├── lib/
│   ├── flsweep.dart          # Public library entry
│   └── src/
│       ├── models/
│       │   └── project_info.dart  # Data model for discovered projects
│       ├── services/
│       │   ├── scanner.dart       # Workspace file crawler & filtering engine
│       │   ├── executor.dart      # Process runner (clean, pub get, deep clean)
│       │   └── metrics.dart       # Disk space calculator (KB/MB/GB)
│       └── ui/
│           ├── tui.dart        # Interactive multi-select & terminal prompts
│           ├── spinner.dart    # Animated terminal braille spinners
│           └── logger.dart     # Colorized log formatters
└── test/                     # Unit tests for scanner, executor, and metrics
```

### Data flow

1. **Scan** (`scanner.dart`) — a breadth-first crawler walks the workspace
   from `--path`, skipping `.pub-cache`, `.git`, `node_modules`, `build`,
   `.dart_tool`, other dotted directories, and anything passed to
   `--exclude`. A directory is a Flutter project iff its `pubspec.yaml` has a
   top-level `name:` **and** a top-level `flutter:` block. Nested traversal
   stops at each discovered project.
2. **Measure** (`metrics.dart`) — for every project, the sizes of `build`,
   `.dart_tool`, `android/.gradle`, `ios/Pods`, and `ios/Podfile.lock` are
   summed recursively (symlinks are never followed).
3. **Select** (`tui.dart`) — interactive arrow-key checklist (`interact`), or
   zero prompts with `--all` / `--quiet`.
4. **Execute** (`executor.dart`) — a fixed-size async worker pool runs, per
   project: `flutter clean` → *(optional deep clean)* → `flutter pub get`,
   then re-measures. Results preserve input order; every failure is captured
   per project.
5. **Report** (`logger.dart`, `tui.dart`) — live spinner progress, per-project
   outcomes, and a final summary with total storage freed.

### Safety guarantees

- **Never touches `.pub-cache`** or any system/SDK directory — the scanner
  hard-ignores it, and the deep-clean deleter re-validates every path against
  a whitelist (`build`, `.dart_tool`, `.gradle`, `Pods`, `Podfile.lock`)
  *and* a canonical containment check against the project root.
- **Deep-clean whitelist** — a path is only deletable if it is (a) inside the
  canonical project root, (b) exactly one of the whitelisted artifact names,
  (c) not the project root, home directory, or filesystem root, and (d) not
  under any `.pub-cache` segment.
- **No symlink following** — neither size measurement nor deletion follows
  links, so linked artifacts elsewhere on disk are never affected.
- **Crash-proof** — `main` has a final safety net; per-project failures are
  converted into status/exit codes, never stack traces.

---

## 🧪 Development

```bash
dart pub get        # fetch dependencies
dart analyze        # static analysis — zero issues expected
dart test           # run the full test suite
```

The executor's process runner and delete routine are injectable seams, so the
test suite exercises the full pipeline (ordering, concurrency caps, failure
isolation, deep-clean safety) without a Flutter SDK on the machine.

### Tech stack

| Package | Purpose |
| --- | --- |
| [`args`](https://pub.dev/packages/args) | CLI flag parsing |
| [`interact`](https://pub.dev/packages/interact) | Arrow-key multi-select checklist |
| [`mason_logger`](https://pub.dev/packages/mason_logger) | Logger baseline utilities |
| [`path`](https://pub.dev/packages/path) | Cross-platform path handling everywhere |

---

## 🤝 Contributing

Issues and pull requests are welcome. Please run `dart analyze` and
`dart test` before submitting; both must be clean.

## 📄 License

MIT — see `LICENSE` if present in your distribution.
