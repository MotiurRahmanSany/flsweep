#!/usr/bin/env bash
# Compiles flsweep into a standalone native executable at build/flsweep.
#
# The native binary starts instantly and never prints Dart SDK messages
# ("Resolving dependencies…", "Downloading packages…", "Building package
# executables…"), because no Dart toolchain runs at execution time. This is
# the recommended way to use flsweep interactively.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
dart pub get
dart compile exe bin/flsweep.dart --output build/flsweep

echo
echo "Built build/flsweep"
