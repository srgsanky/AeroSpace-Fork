#!/usr/bin/env bash

set -euo pipefail

# Homebrew runs `brew cleanup` automatically every HOMEBREW_CLEANUP_PERIODIC_FULL_DAYS.
# That is unrelated to building AeroSpace, and a single unremovable keg anywhere in the
# Cellar fails the whole install, so keep it out of this script's install steps.
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ENV_HINTS=1

if ((BASH_VERSINFO[0] < 5)); then
    for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$candidate" ]]; then
            exec "$candidate" "$0" "$@"
        fi
    done

    brew_bin="$(command -v brew 2>/dev/null || true)"
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -z "$brew_bin" && -x "$candidate" ]]; then
            brew_bin="$candidate"
        fi
    done
    if [[ -n "$brew_bin" ]]; then
        echo "Bash 5 or newer is missing; installing it with Homebrew..."
        "$brew_bin" install bash
        exec "$("$brew_bin" --prefix)/bin/bash" "$0" "$@"
    fi

    echo "error: Bash 5 or newer is required, and Homebrew was not found. Install Homebrew from https://brew.sh" >&2
    exit 1
fi

cd "$(dirname "$0")"

usage() {
    cat <<'EOF'
Usage: ./build-and-install-local.sh [--dont-rebuild]

Build and install the committed checkout as the Homebrew cask aerospace-dev.
Missing Homebrew build dependencies are installed automatically.

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

install_missing_build_dependencies() {
    local formulas=()
    command -v swiftly >/dev/null 2>&1 || formulas+=(swiftly)
    command -v cargo >/dev/null 2>&1 || formulas+=(rust)
    command -v fish >/dev/null 2>&1 || formulas+=(fish)
    [[ -x "$ruby34_bin/ruby" ]] || formulas+=(ruby@3.4)

    if ((${#formulas[@]} > 0)); then
        echo "Installing missing build dependencies with Homebrew: ${formulas[*]}"
        brew install "${formulas[@]}"
        hash -r
    fi

    if [[ -x "$ruby34_bin/ruby" ]]; then
        export PATH="$ruby34_bin:$PATH"
    fi
}

initialize_swiftly() {
    if swiftly run swift --version >/dev/null 2>&1; then
        return
    fi

    echo "Initializing Swiftly and installing the Swift version from .swift-version..."
    swiftly init --skip-install --assume-yes --no-modify-profile --quiet-shell-followup || \
        fail "Swiftly initialization failed; try: swiftly init --skip-install --assume-yes && swiftly install"
    swiftly install || fail "Swiftly could not install the Swift version from .swift-version; try: swiftly install"
    swiftly run swift --version >/dev/null 2>&1 || fail "Swiftly is initialized, but the configured Swift toolchain is unavailable."
}

select_full_xcode() {
    local developer_dir="${DEVELOPER_DIR:-}"
    local candidate

    if [[ -z "$developer_dir" ]]; then
        developer_dir="$(xcode-select -p 2>/dev/null || true)"
    fi
    if [[ -d "$developer_dir/Platforms/MacOSX.platform" ]]; then
        export DEVELOPER_DIR="$developer_dir"
        return
    fi

    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer; do
        if [[ -d "$candidate/Platforms/MacOSX.platform" ]]; then
            export DEVELOPER_DIR="$candidate"
            echo "Full Xcode is not selected; using $DEVELOPER_DIR for this build."
            return
        fi
    done

    fail "full Xcode is required but was not found. Install Xcode from the App Store, then rerun this script."
}

if ((rebuild)); then
    if [[ -n "$(git status --porcelain)" ]]; then
        git status --short >&2
        fail "the release build requires a clean worktree. Commit or stash the changes above, then rerun this script."
    fi

    install_missing_build_dependencies

    require_command swiftly "Automatic Homebrew installation failed; try: brew install swiftly"
    initialize_swiftly
    require_command cargo "Automatic Homebrew installation failed; try: brew install rust"
    require_command fish "Automatic Homebrew installation failed; try: brew install fish"
    require_command ruby "Automatic Homebrew installation failed; try: brew install ruby@3.4"
    require_command bundler "Ruby was installed, but Bundler is unavailable; try: $(brew --prefix ruby@3.4)/bin/gem install bundler"

    select_full_xcode
    require_command xcodebuild "Install Xcode from the App Store."

    ruby_major="$(ruby -e 'print RUBY_VERSION.split(".").first')"
    if [[ "$ruby_major" -lt 3 || "$ruby_major" -ge 4 ]]; then
        fail "Ruby 3 is required, but $(ruby --version) is active. Install ruby@3.4 and put its bin directory first in PATH."
    fi

    if ! xcodebuild -version >/dev/null 2>&1; then
        fail "Xcode is not ready. Run: sudo \"$DEVELOPER_DIR/usr/bin/xcodebuild\" -license accept && sudo \"$DEVELOPER_DIR/usr/bin/xcodebuild\" -runFirstLaunch"
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
