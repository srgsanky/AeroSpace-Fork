#!/usr/bin/env bash
cd "$(dirname "$0")"
source ./script/setup.sh

rebuild=1
while test $# -gt 0; do
    case $1 in
        --dont-rebuild) rebuild=0; shift ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done

if test $rebuild == 1; then
    ./build-release.sh
fi

PATH="$PATH:$(brew --prefix)/bin"
export PATH

while IFS= read -r installed_cask; do
    brew uninstall --cask "$installed_cask"
done < <(brew list --cask --full-name | grep -E '(^|/)aerospace(-dev)?$' || true)
brew_install_path="$(brew --prefix brew-install-path 2>/dev/null || true)/bin/brew-install-path"
if ! test -x "$brew_install_path"; then
    brew install nikitabobko/tap/brew-install-path
    brew_install_path="$(brew --prefix brew-install-path)/bin/brew-install-path"
fi

# Override HOMEBREW_CACHE. Otherwise, homebrew refuses to "redownload" the snapshot file
# Maybe there is a better way, I don't know
rm -rf /tmp/aerospace-from-sources-brew-cache
HOMEBREW_CACHE=/tmp/aerospace-from-sources-brew-cache "$brew_install_path" ./.release/aerospace-dev.rb

rm -rf "$(brew --prefix)/Library/Taps/aerospace-dev-user" # Compatibility. Drop after a while
