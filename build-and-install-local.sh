#!/usr/bin/env bash

set -euo pipefail

if ((BASH_VERSINFO[0] < 5)); then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$candidate" ]]; then
            exec "$candidate" "$0" "$@"
        fi
    done
    echo "error: Bash 5 or newer is required. Install it with: brew install bash" >&2
    exit 1
fi

cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
Usage: ./build-and-install-local.sh [--dont-rebuild]

Build and install the committed checkout as the Homebrew cask aerospace-dev.

Options:
  --dont-rebuild  Reinstall the existing .release build without rebuilding it
  -h, --help      Show this help
EOF
}

rebuild=1
while (($# > 0)); do
    case "$1" in
        --dont-rebuild)
            rebuild=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

fail() {
    echo "error: $1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required. $2"
}

if ! command -v brew >/dev/null 2>&1; then
    for candidate in /opt/homebrew/bin /usr/local/bin; do
        if [[ -x "$candidate/brew" ]]; then
            export PATH="$candidate:$PATH"
            break
        fi
    done
fi

require_command brew "Install Homebrew from https://brew.sh"
require_command git "Install the Xcode command-line tools or Git."

brew_prefix="$(brew --prefix)"
export PATH="$brew_prefix/bin:$PATH"

# Homebrew's unversioned Ruby may be Ruby 4, while the Gemfile requires Ruby 3.
ruby34_bin="$brew_prefix/opt/ruby@3.4/bin"
if [[ -x "$ruby34_bin/ruby" ]]; then
    export PATH="$ruby34_bin:$PATH"
fi

if ((rebuild)); then
    if [[ -n "$(git status --porcelain)" ]]; then
        git status --short >&2
        fail "the release build requires a clean worktree. Commit or stash the changes above, then rerun this script."
    fi

    require_command swiftly "Install it with: brew install swiftly"
    require_command cargo "Install Rust from https://rustup.rs"
    require_command fish "Install it with: brew install fish"
    require_command ruby "Install Ruby 3 with: brew install ruby@3.4"
    require_command bundler "Install Bundler with: gem install bundler"
    require_command xcodebuild "Install Xcode from the App Store."

    ruby_major="$(ruby -e 'print RUBY_VERSION.split(".").first')"
    if [[ "$ruby_major" -lt 3 || "$ruby_major" -ge 4 ]]; then
        fail "Ruby 3 is required, but $(ruby --version) is active. Install ruby@3.4 and put its bin directory first in PATH."
    fi

    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ ! -d "$developer_dir/Platforms/MacOSX.platform" ]]; then
        fail "full Xcode is not selected. Run: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    fi
    if ! xcodebuild -version >/dev/null 2>&1; then
        fail "Xcode is not ready. Run: sudo xcodebuild -license accept && sudo xcodebuild -runFirstLaunch"
    fi

    if ! grep -Fq 'aerospace-codesign-certificate' <<< "$(security find-identity -v -p codesigning)"; then
        fail "the 'aerospace-codesign-certificate' code-signing identity is missing. See dev-docs/build-and-install-local.md."
    fi
else
    [[ -f .release/aerospace-dev.rb ]] || fail ".release/aerospace-dev.rb is missing; rerun without --dont-rebuild first."
fi

cat <<'EOF'

Building and installing the local AeroSpace checkout.
Warning: this replaces any Homebrew-installed aerospace or aerospace-dev cask.
EOF

if ((rebuild)); then
    ./install-from-sources.sh
else
    ./install-from-sources.sh --dont-rebuild
fi

cat <<'EOF'

Local AeroSpace installation complete.
Quit the currently running AeroSpace, then run:
  open /Applications/AeroSpace.app

If macOS does not allow it to manage windows, remove and re-add AeroSpace in:
  System Settings > Privacy & Security > Accessibility
EOF
