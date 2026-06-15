#!/bin/sh
set -eu

threshold="${1:-80}"
binary=".build/arm64-apple-macosx/debug/PhorganizePackageTests.xctest/Contents/MacOS/PhorganizePackageTests"
profile=".build/arm64-apple-macosx/debug/codecov/default.profdata"

swift test --enable-code-coverage --quiet

report="$(xcrun llvm-cov report "$binary" \
  -instr-profile "$profile" \
  -ignore-filename-regex='Tests|PhorganizeApp|resource_bundle_accessor|runner.swift')"

printf '%s\n' "$report"

coverage="$(printf '%s\n' "$report" | awk '/^TOTAL/ { gsub("%", "", $10); print $10 }')"
awk -v actual="$coverage" -v threshold="$threshold" '
  BEGIN {
    if (actual + 0 < threshold + 0) {
      printf("Coverage %.2f%% is below the %.2f%% target.\n", actual, threshold) > "/dev/stderr"
      exit 1
    }
  }
'
