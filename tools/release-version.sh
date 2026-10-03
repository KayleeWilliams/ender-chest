#!/bin/sh
# Print the next ec patch release. No release yet starts at 0.0.1.
set -eu
raw=${1:-}
raw=${raw#v}
if [ -z "$raw" ] || [ "$raw" = "null" ]; then
  printf '%s\n' 0.0.1
  exit 0
fi
case $raw in
  0.0.*) ;;
  *) echo "ec releases stay on 0.0.x, not $raw" >&2; exit 1 ;;
esac
patch=${raw##*.}
case $patch in
  *[!0-9]*) echo "bad ec version: $raw" >&2; exit 1 ;;
esac
case $patch in
  0*) [ "$patch" = 0 ] || { echo "bad ec version: $raw" >&2; exit 1; } ;;
esac
printf '0.0.%s\n' "$((patch + 1))"
