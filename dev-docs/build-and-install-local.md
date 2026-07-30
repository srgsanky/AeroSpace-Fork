# Build and install AeroSpace locally

Use the repository's `build-and-install-local.sh` helper to build the committed checkout, sign it, and install it as the Homebrew cask `aerospace-dev`.

> **Warning:** Installing the local build uninstalls any Homebrew-installed `aerospace` or `aerospace-dev` cask. Quit and relaunch AeroSpace after installation so the new binary is running.

## One-time setup

### 1. Install and select Xcode

Install the full Xcode application from the App Store, then run:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
```

Selecting only the Command Line Tools is insufficient for the signed release build.

### 2. Install build dependencies

Install the Homebrew dependencies:

```bash
brew install swiftly bash fish ruby@3.4 xcbeautify
```

Install Rust and Cargo using [rustup](https://rustup.rs), then make sure the expected tools are available:

```bash
export PATH="/opt/homebrew/opt/ruby@3.4/bin:/opt/homebrew/bin:$PATH"

bash --version    # Must be 5 or newer
ruby --version    # Must be 3.x
cargo --version
swiftly --version
```

On an Intel Mac, Homebrew normally uses `/usr/local` rather than `/opt/homebrew`. `build-and-install-local.sh` discovers the active Homebrew prefix automatically.

The project pins its Swift version in `.swift-version`; `swiftly` uses that version while running the build scripts.

### 3. Create the code-signing certificate

The release app and CLI must be signed. In **Keychain Access**:

1. Choose **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Set the name to `aerospace-codesign-certificate`.
3. Set **Identity Type** to **Self-Signed Root**.
4. Set **Certificate Type** to **Code Signing**.
5. Create the certificate in your login keychain.

Confirm that macOS recognizes the identity:

```bash
security find-identity -v -p codesigning | grep aerospace-codesign-certificate
```

## Build and install

The release process requires a clean Git worktree because it regenerates derived files and temporarily updates version metadata. Commit or stash all changes first:

```bash
git status --short
```

When that command prints nothing, build and install:

```bash
./build-and-install-local.sh
```

The script validates the common prerequisites and delegates to the repository's release and local Homebrew installation scripts. The build artifacts are written to `.release/`, including:

- `.release/AeroSpace.app`
- `.release/aerospace`
- `.release/AeroSpace-v0.0.0-SNAPSHOT.zip`

If Homebrew refuses to install the `brew-install-path` helper because its tap is not trusted, explicitly trust that formula and retry:

```bash
brew trust --formula nikitabobko/tap/brew-install-path
./build-and-install-local.sh
```

## Relaunch and verify

Quit AeroSpace from its menu-bar icon, then launch the newly installed app:

```bash
open /Applications/AeroSpace.app
```

Verify the CLI and compare its commit hash with the checkout you built:

```bash
git rev-parse --short HEAD
aerospace --version
```

If the app launches but cannot manage windows, open **System Settings → Privacy & Security → Accessibility**, remove the old AeroSpace entry if necessary, and add or enable `/Applications/AeroSpace.app` again.

## Reinstall an existing build

To reinstall the existing `.release` artifacts without rebuilding them:

```bash
./build-and-install-local.sh --dont-rebuild
```

This requires `.release/aerospace-dev.rb` from an earlier successful release build.

## Build without installing

To create the signed release artifacts without replacing the installed app:

```bash
./build-release.sh
```

For a faster unsigned development build that runs from the terminal:

```bash
./run-debug.sh
```

The debug build does not require the self-signed certificate, but Terminal must have Accessibility permission.

## Troubleshooting

### Bash is too old

If a script reports that Bash is too old:

```bash
brew install bash
export PATH="$(brew --prefix)/bin:$PATH"
```

Then confirm `bash --version` reports version 5 or newer.

### Ruby does not satisfy the Gemfile

The documentation build requires Ruby 3, not the macOS system Ruby or Ruby 4:

```bash
brew install ruby@3.4
export PATH="$(brew --prefix ruby@3.4)/bin:$PATH"
ruby --version
```

### Signing identity is missing

Recreate the certificate with the exact name `aerospace-codesign-certificate` and type **Code Signing**. A similarly named ordinary certificate cannot sign the app.

### The old version is still running

Replacing `/Applications/AeroSpace.app` does not replace an already-running process. Quit AeroSpace completely and reopen it before testing the new command or binding.
