# flsweep Implementation Roadmap & AI Agent System Specification

> **Notice to AI Coding Agent**: You are tasked with building `flsweep` fully end-to-end inside this repository (`/home/lazy/Projects/flutter_/flsweep`). Read this entire document carefully before writing any code. Execute each phase sequentially, run tests to verify stability, and strictly follow the Git commit guidelines at every milestone.

---

## 🛠 Project Overview & Core Goals

`flsweep` is a high-performance, cross-platform CLI tool written in **Dart** that scans workspace directories, batch cleans Flutter projects (`flutter clean`), resolves dependencies (`flutter pub get`), deep-cleans hidden native build artifacts, and calculates exact disk space recovered.

### Key Capabilities
1. **Parallel Execution**: Process multiple Flutter projects concurrently using Dart async isolate worker pools.
2. **Zero-Break Sync**: Sequentially execute `flutter clean` ➔ `flutter pub get` so IDE symbols and indices are instantly restored.
3. **Deep Clean Option (`--deep`)**: Safely wipe `android/.gradle`, `ios/Pods`, and `.dart_tool` directories.
4. **Disk Metric Tracking**: Calculate and output precise MB/GB freed post-clean.
5. **Dual Interface**:
   - **Interactive Mode (TUI)**: Multi-select interactive menu, live braille spinners, and colored logs.
   - **Headless Mode**: Non-interactive flags (`--all`, `--quiet`, `--json`) designed for CI/CD pipelines and AI coding agents.

---

## 🏗 System Architecture & Repository Layout

Initialize the repository using `dart create -t cli . --force` and establish the following structure:

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
├── test/
│   ├── scanner_test.dart
│   ├── executor_test.dart
│   └── metrics_test.dart
├── pubspec.yaml               # Executable & dependency configuration
├── README.md                  # Complete visual documentation & usage guide
└── ROADMAP.md                 # This specification file



📦 Required Dependencies (pubspec.yaml)
Configure pubspec.yaml with the following dependencies:


name: flsweep
description: The ultimate concurrent Flutter workspace cleaner and package syncer.
version: 1.0.0

environment:
  sdk: '>=3.0.0 <4.0.0'

executables:
  flsweep: flsweep

dependencies:
  args: ^2.4.2
  interact: ^2.4.0
  mason_logger: ^0.2.11
  path: ^1.9.0

dev_dependencies:
  lints: ^3.0.0
  test: ^1.24.0
  
  
  
  
🚦 CLI Specifications & Interface Options
flsweep [path] [flags]

Flag,Short,Type,Default,Description
--path,-p,String,./,Root path to start scanning for Flutter projects.
--all,-a,Bool,false,Non-interactive mode; process all found projects immediately.
--deep,-d,Bool,false,"Deep clean mode; removes android/.gradle, ios/Pods, .dart_tool."
--exclude,-e,String,"""""",Comma-separated paths or names to ignore during scan.
--dry-run,-n,Bool,false,Scan and display cleanable storage size without deleting anything.
--concurrent,-c,Int,4,Maximum number of projects to clean in parallel.
--quiet,-q,Bool,false,Suppress spinners/TUI animations; output minimal logs or plain text.




📋 Step-by-Step Execution Phases
Phase 1: Environment Setup & Foundation
Initialize the Dart CLI package in the current directory (dart create -t cli . --force).

Update pubspec.yaml with required dependencies and run dart pub get.

Create lib/src/models/project_info.dart holding path, name, pre-clean size, post-clean size, and execution status.

Git Commit: feat(setup): initialize project structure and dependencies

Phase 2: Scanner & Metrics Core Engine
Implement lib/src/services/scanner.dart:

Recursively crawl directories starting from target --path.

Ignore directories matching: .pub-cache, .cache, .local, .git, node_modules, build, and hidden folders starting with ..

Validate that discovered pubspec.yaml files contain a top-level flutter: block.

Implement lib/src/services/metrics.dart:

Recursively calculate target directory size in Bytes/KB/MB/GB for build, .dart_tool, android/.gradle, and ios/Pods.

Write unit tests in test/scanner_test.dart and test/metrics_test.dart.

Git Commit: feat(engine): implement directory scanner, pubspec filter, and metrics engine

Phase 3: Executor & Concurrent Worker Pool
Implement lib/src/services/executor.dart:

Execute flutter clean inside target project path.

If --deep flag is active, wipe android/.gradle, ios/Pods, ios/Podfile.lock, and .dart_tool.

Immediately execute flutter pub get upon successful clean.

Implement worker concurrency limit via Future pool / Stream throttling governed by --concurrent.

Write unit tests in test/executor_test.dart.

Git Commit: feat(executor): implement parallel process execution and deep clean routines

Phase 4: Terminal UI, Spinners, & CLI Flags
Implement lib/src/ui/tui.dart & lib/src/ui/spinner.dart:

Interactive multi-select checklist using interact or mason_logger when --all is not passed.

Live braille loading animation during execution.

Summary display showing total projects processed, failures, and formatted storage recovered (e.g., Freed 2.45 GB).

Connect all flags (--path, --all, --deep, --dry-run, --quiet, --concurrent, --exclude) in bin/flsweep.dart.

Git Commit: feat(ui): add interactive TUI, braille spinners, and CLI flag routing

Phase 5: Verification, Tests, & Documentation
Run dart analyze to ensure zero linting errors or warnings.

Run dart test to confirm all tests pass.

Generate a comprehensive README.md containing usage examples, installation guides, flag documentation, and architectural overviews.

Git Commit: docs: add production README and final project polish

🛡 Mandatory Rules for the AI Agent
Strict Non-Destructive Scanning: Never modify, clean, or delete any files inside .pub-cache, global SDK directories, or system paths.

Error Isolation: If flutter clean or flutter pub get fails on a single project, log the failure gracefully and continue processing remaining projects. Do not throw unhandled exceptions that crash the script.

Cross-Platform Compatibility: Use standard path package helpers (path.join, path.canonicalize) for all directory routing so code runs identically on Linux, macOS, and Windows.

Git Discipline: Create clean atomic commits after completing each specified phase. Do not bundle the entire repository into a single massive commit.
