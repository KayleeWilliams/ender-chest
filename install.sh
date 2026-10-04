#!/bin/sh
# Download and verify ec before replacing an installed binary.

main() (
  set -eu

  fail() { printf 'ec: %s\n' "$*" >&2; exit 1; }
  repo=${EC_RELEASE_REPO:-KayleeWilliams/ender-chest-cli}
  version=${EC_VERSION:-}
  install_dir=${EC_INSTALL_DIR:-}
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        [ "$#" -ge 2 ] || fail '--version needs a release version.'
        [ -n "$2" ] || fail '--version needs a release version.'
        version=$2; shift 2 ;;
      --install-dir)
        [ "$#" -ge 2 ] || fail '--install-dir needs a directory.'
        [ -n "$2" ] || fail '--install-dir needs a directory.'
        install_dir=$2; shift 2 ;;
      --help|-h)
        printf '%s\n' 'Install ec for macOS or Linux, ARM64 or x86-64.' \
          'Usage: sh install.sh [--version X.Y.Z] [--install-dir DIRECTORY]' \
          'Default directory: ~/.local/bin. No sudo or shell-profile edits.' \
          'Private releases require an authenticated GitHub CLI.'
        exit 0 ;;
      *) fail "Unknown option: $1" ;;
    esac
  done

  case "$repo" in
    *[!a-zA-Z0-9_./-]*|/*|*/|*/*/*|./*|../*|*/.|*/..|-*) fail 'Invalid EC_RELEASE_REPO; use owner/repo.' ;;
    */*) ;;
    *) fail 'Invalid EC_RELEASE_REPO; use owner/repo.' ;;
  esac
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) fail 'Supported systems are macOS and Linux.' ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) fail 'Supported processors are ARM64 and x86-64.' ;;
  esac
  asset="ec-$arch-$os"

  if command -v sha256sum >/dev/null 2>&1; then
    checksum=sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    checksum=shasum
  else
    fail 'Install sha256sum or shasum to verify the download.'
  fi
  method=curl
  if command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1; then
    method=gh
  else
    command -v curl >/dev/null 2>&1 || fail 'Install curl to download ec.'
  fi

  if [ -z "$version" ]; then
    if [ "$method" = gh ]; then
      version=$(gh release view --repo "$repo" --json tagName --jq .tagName) || fail 'Cannot find a release. Check your repository access.'
    else
      url=$(curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
        --output /dev/null --write-out '%{url_effective}' -- "https://github.com/$repo/releases/latest") || \
        fail 'Cannot find a release. For private releases, install gh and run gh auth login.'
      case "$url" in
        "https://github.com/$repo/releases/tag/"*) version=${url##*/} ;;
        *) fail 'GitHub did not return a release tag.' ;;
      esac
    fi
  fi
  version=${version#v}
  case "$version" in
    ''|*[!0-9.]*|.*|*.|*..*) fail 'Use a release version such as 0.0.1.' ;;
  esac
  # Only stable, three-component versions are supported by this installer.
  old_ifs=$IFS; IFS=.; set -- $version; IFS=$old_ifs
  [ "$#" -eq 3 ] || fail 'Use a release version such as 0.0.1.'
  for part in "$@"; do
    case "$part" in 0?*) fail 'Release version components must not have leading zeros.' ;; esac
  done
  tag="v$version"

  if [ -z "$install_dir" ]; then
    [ -n "${HOME:-}" ] || fail 'Set HOME or pass --install-dir.'
    install_dir="$HOME/.local/bin"
  fi
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/ec-install.XXXXXX")
  staged=
  cleanup() {
    rm -rf -- "$temporary"
    if [ -n "$staged" ]; then rm -f -- "$staged"; fi
  }
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

  download() {
    if [ "$method" = gh ]; then
      gh release download "$tag" --repo "$repo" --pattern "$1" --output "$temporary/$1"
    else
      curl --proto '=https' --proto-redir '=https' -fsSL --retry 3 --connect-timeout 10 --max-time 120 \
        --output "$temporary/$1" -- "https://github.com/$repo/releases/download/$tag/$1"
    fi
  }
  printf 'Downloading ec %s for %s/%s...\n' "$version" "$os" "$arch"
  download "$asset" || fail 'Binary download failed; the existing installation is unchanged.'
  download "$asset.sha256" || fail 'Checksum download failed; the existing installation is unchanged.'
  [ -s "$temporary/$asset" ] || fail 'The downloaded binary is empty.'
  expected=$(tr -d ' \t\r\n' < "$temporary/$asset.sha256" | tr 'A-F' 'a-f')
  [ "${#expected}" -eq 64 ] || fail 'Invalid release checksum.'
  case "$expected" in *[!0-9a-f]*) fail 'Invalid release checksum.' ;; esac
  if [ "$checksum" = sha256sum ]; then
    actual=$(sha256sum "$temporary/$asset")
  else
    actual=$(shasum -a 256 "$temporary/$asset")
  fi
  [ "${actual%% *}" = "$expected" ] || fail 'Checksum mismatch; the existing installation is unchanged.'

  mkdir -p -- "$install_dir"
  install_dir=$(CDPATH= cd -- "$install_dir" && pwd)
  [ ! -d "$install_dir/ec" ] || fail 'The install destination is a directory.'
  staged=$(mktemp "$install_dir/.ec-install.XXXXXX")
  cat "$temporary/$asset" > "$staged"
  chmod 755 "$staged"
  mv -f -- "$staged" "$install_dir/ec"
  staged=
  printf 'Installed ec %s to %s/ec\n' "$version" "$install_dir"
  case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *) printf 'Add %s to your PATH, then run ec --help.\n' "$install_dir" ;;
  esac
)

main "$@"
