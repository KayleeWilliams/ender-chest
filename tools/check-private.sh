#!/bin/sh
# Blocks real machine names, accounts, addresses, and credentials from entering this public repo.
#
# Patterns live outside the repo, one fixed string per line, matched without case:
#   $EC_PRIVATE_PATTERNS, else ~/.config/ender-chest/private-patterns
# Matches report a file and line, or a commit, never the matched text.
#
#   tools/check-private.sh            tracked files in the working tree
#   tools/check-private.sh --staged   the index, for pre-commit
#   tools/check-private.sh --range R  commits in R, for pre-push
#   tools/check-private.sh --all      every commit on every ref
#
# gitleaks also runs when it is installed. Set EC_REQUIRE_PATTERNS=1 to fail when no
# pattern file exists, as CI does.
set -eu

mode=${1:---tree}
range=${2-}
patterns=${EC_PRIVATE_PATTERNS:-${HOME:-}/.config/ender-chest/private-patterns}
root=$(git rev-parse --show-toplevel)
cd "$root"
found=0

clean_patterns() {
	# Blank lines would match everything.
	tmp=$(mktemp)
	trap 'rm -f "$tmp"' EXIT
	grep -v '^[[:space:]]*$' "$patterns" >"$tmp" || true
	[ -s "$tmp" ]
}

scan_commits() {
	for commit in $(git rev-list "$@"); do
		if git show --format='%an%n%ae%n%cn%n%ce%n%B' --no-color --no-ext-diff "$commit" | grep -qiF -f "$tmp"; then
			echo "private text in commit $(git rev-parse --short "$commit"): $(git log -1 --format=%s "$commit")" >&2
			found=1
		fi
	done
}

if [ -r "$patterns" ] && clean_patterns; then
	case "$mode" in
	--tree) hits=$(git grep -I -n -i -F -f "$tmp" -- . | cut -d: -f1,2 || true) ;;
	--staged) hits=$(git grep --cached -I -n -i -F -f "$tmp" -- . | cut -d: -f1,2 || true) ;;
	# shellcheck disable=SC2086 # a range may be "SHA --not --remotes"
	--range) hits="" && scan_commits $range ;;
	--all) hits='' && scan_commits --all ;;
	*)
		echo "usage: $0 [--staged | --range A..B | --all]" >&2
		exit 2
		;;
	esac
	if [ -n "$hits" ]; then
		printf 'private text at %s\n' $hits >&2
		found=1
	fi
elif [ "${EC_REQUIRE_PATTERNS:-0}" = 1 ]; then
	echo "No private patterns at $patterns." >&2
	exit 1
else
	echo "note: no private patterns at $patterns; checking only for generic secrets." >&2
fi

if command -v gitleaks >/dev/null 2>&1; then
	case "$mode" in
	--staged) gitleaks git --no-banner --redact --staged --pre-commit . >&2 || found=1 ;;
	--range) gitleaks git --no-banner --redact --log-opts="$range" . >&2 || found=1 ;;
	--all) gitleaks git --no-banner --redact . >&2 || found=1 ;;
	*) gitleaks git --no-banner --redact --pre-commit . >&2 || found=1 ;;
	esac
fi

if [ "$found" = 1 ]; then
	echo "Remove the private text, or rewrite the commit, before it reaches the public repo." >&2
	exit 1
fi
