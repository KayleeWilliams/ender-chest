#!/bin/sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
(cd "$source_dir/packages/cli" && "$source_dir/tools/zig" build -Doptimize=ReleaseSafe >&2)
exec "$source_dir/packages/cli/zig-out/bin/ec" "$@"
