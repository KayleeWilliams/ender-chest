#!/bin/sh
# Publishes examples/config to a checkout of the ender-chest-template repository.
#
#   tools/publish-template.sh TEMPLATE [--version V] [--no-commit] [--push]
#
# TEMPLATE must be a clean checkout whose origin is an ender-chest-template repository. The script
# makes its files match examples/config, then commits "Publish the example config from ec V".
# --no-commit still writes the files, and leaves the change uncommitted. Nothing is pushed
# without --push.
set -eu

usage() {
	echo "usage: $0 TEMPLATE [--version V] [--no-commit] [--push]" >&2
	exit 2
}

[ $# -ge 1 ] || usage
template=$1
shift
version=""
commit=1
push=0
while [ $# -gt 0 ]; do
	case "$1" in
	--version)
		[ $# -ge 2 ] || usage
		version=$2
		shift 2
		;;
	--no-commit)
		commit=0
		shift
		;;
	--push)
		push=1
		shift
		;;
	*) usage ;;
	esac
done
[ "$commit" = 1 ] || [ "$push" = 0 ] || {
	echo "--push needs a commit; drop --no-commit." >&2
	exit 2
}

root=$(cd "$(dirname "$0")/.." && pwd -P)
source="$root/examples/config"
template=$(cd "$template" && pwd -P)
if [ "$(git -C "$template" rev-parse --show-toplevel 2>/dev/null)" != "$template" ]; then
	echo "$template is not the root of a Git checkout." >&2
	exit 1
fi
case "$(git -C "$template" remote get-url origin 2>/dev/null)" in
*/ender-chest-template | */ender-chest-template.git) ;;
*)
	echo "$template's origin is not an ender-chest-template repository." >&2
	exit 1
	;;
esac
if [ -n "$(git -C "$template" status --porcelain)" ]; then
	echo "$template has uncommitted changes. Commit or discard them first." >&2
	exit 1
fi

# The template is exactly examples/config: anything else in it, such as a license copied from
# this repository, is removed.
rsync -a --delete --exclude .git --exclude .DS_Store "$source/" "$template/"

if [ -z "$(git -C "$template" status --porcelain)" ]; then
	echo "The template already matches examples/config."
	exit 0
fi
if [ "$commit" = 0 ]; then
	git -C "$template" status --short
	exit 0
fi

if [ -z "$version" ]; then
	version=$(git -C "$root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') || true
fi
[ -n "$version" ] || {
	echo "Pass --version; this checkout has no release tag." >&2
	exit 1
}

git -C "$template" add -A
(cd "$template" && "$root/tools/check-private.sh" --staged)
git -C "$template" commit -q -m "Publish the example config from ec $version"
echo "Committed the example config from ec $version in $template."
if [ "$push" = 1 ]; then
	git -C "$template" push -q origin HEAD
	echo "Pushed."
fi
