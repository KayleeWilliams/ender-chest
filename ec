#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
(cd "$source_dir" && "$source_dir/tools/zig" build -Doptimize=ReleaseSafe >&2)
exec "$source_dir/zig-out/bin/ec" "$@"
