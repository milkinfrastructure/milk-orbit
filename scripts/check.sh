#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if (( $# > 1 )); then
    echo "Usage: bash scripts/check.sh [--core]" >&2
    exit 2
fi
case "${1:-}" in
    ""|--core) ;;
    --help|-h) echo "Usage: bash scripts/check.sh [--core]"; exit 0 ;;
    *) echo "Usage: bash scripts/check.sh [--core]" >&2; exit 2 ;;
esac
# Structural validation only by default: no app build, XCTest, or device actions.
swift scripts/validate-project.swift
if [[ "${1:-}" == "--core" ]]; then
    # Optional deterministic macOS core checks; never launches an iOS UI suite.
    swift test --scratch-path .qa-build/core
fi
