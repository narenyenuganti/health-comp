#!/usr/bin/env bash
# settle and grow must go through View.moving, or Reduce Motion keeps them.
set -uo pipefail
cd "$(dirname "$0")/.."

grep -rnE --include='*.swift' --exclude=Motion.swift \
  '(\.animation|withAnimation)\(Motion\.(settle|grow)' \
  HealthComp HealthCompWidgets HealthCompWatch HealthCompWatchWidgets
case $? in
  0) printf 'Use .moving(_:value:) for Motion.settle and Motion.grow.\n' >&2; exit 1 ;;
  1) printf 'Motion tokens OK\n' ;;
  *) exit 2 ;;
esac
