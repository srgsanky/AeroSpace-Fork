# Build and install AeroSpace locally

Use the repository's `build-and-install-local.sh` helper to build the committed checkout, sign it, and install it as the Homebrew cask `aerospace-dev`.

> **Warning:** Installing the local build uninstalls any Homebrew-installed `aerospace` or `aerospace-dev` cask. Quit and relaunch AeroSpace after installation so the new binary is running.

## One-time setup

### 1. Install Xcode

Install the full Xcode application from the App Store. The helper automatically uses an installation under `/Applications` for the build, even when `xcode-select` points to the standalone Command Line Tools.

Initialize a new Xcode installation once:

```bash
sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -license accept
sudo /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch
```

The full Xcode application is required for the signed release build; the standalone Command Line Tools are insufficient.

### 2. Install build dependencies

`build-and-install-local.sh` automatically installs missing build dependencies with Homebrew. Depending on what is already available, it installs:

- `bash`
- `swiftly`
- `rust` (which provides Cargo)
- `fish`
- `ruby@3.4`

It does not automatically install Xcode, Homebrew, or the code-signing certificate.

To install the dependencies ahead of time, run:

```bash
brew install swiftly bash fish ruby@3.4 rust
swiftly init --skip-install --assume-yes
swiftly install
```

If Swiftly is installed but not initialized, the helper runs these initialization commands automatically and installs the Swift version pinned in `.swift-version`.

`xcbeautify` is optional and makes Xcode output easier to read:

```bash
brew install xcbeautify
```

You may use a Rust toolchain installed by [rustup](https://rustup.rs) instead of Homebrew. If `cargo` is already available, the helper does not install Homebrew's `rust` formula.

To verify the tools manually:

```bash
export PATH="/opt/homebrew/opt/ruby@3.4/bin:/opt/homebrew/bin:$PATH"

bash --version    # Must be 5 or newer
ruby --version    # Must be 3.x
cargo --version
swiftly run swift --version
```

On an Intel Mac, Homebrew normally uses `/usr/local` rather than `/opt/homebrew`. `build-and-install-local.sh` discovers the active Homebrew prefix automatically.

The project pins its Swift version in `.swift-version`; `swiftly` uses that version while running the build scripts.

### 3. Create the code-signing certificate

The release app and CLI must be signed. In **Keychain Access**:

1. Choose **Keychain Access → Certificate Assistant → Create a Certificate**.
2. Set the name to `aerospace-codesign-certificate`.
3. Set **Identity Type** to **Self-Signed Root**.
4. Set **Certificate Type** to **Code Signing**.
5. Create the certificate in your **login** keychain.
6. Under **login → My Certificates**, double-click the new certificate and expand **Trust**.
7. Set **Code Signing** (or **When using this certificate**) to **Always Trust**, close the window, and authenticate when prompted.

Confirm that macOS recognizes the certificate and its private key as a valid identity:

```bash
security find-identity -v -p codesigning
```

The output must list `aerospace-codesign-certificate` and end with `1 valid identities found`.

## Build and install

The release process requires a clean Git worktree because it regenerates derived files and temporarily updates version metadata. Commit or stash all changes first:

```bash
git status --short
```

When that command prints nothing, build and install:

```bash
./build-and-install-local.sh
```

The script installs any missing Homebrew build dependencies, validates the remaining prerequisites, and delegates to the repository's release and local Homebrew installation scripts. The build artifacts are written to `.release/`, including:

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

The helper attempts to install Homebrew's Bash and restart itself automatically. If that bootstrap fails, run:

```bash
brew install bash
export PATH="$(brew --prefix)/bin:$PATH"
```

Then confirm `bash --version` reports version 5 or newer.

### A Homebrew dependency fails to install

The helper prints the exact `brew install` command it is running. Resolve the reported Homebrew error and rerun the helper; already installed formulas will not be reinstalled.

### Swiftly is not initialized

The helper initializes Swiftly and installs the version pinned in `.swift-version` automatically. To repair the setup manually, run:

```bash
swiftly init --skip-install --assume-yes
swiftly install
swiftly run swift --version
```

The first download can be large. Subsequent builds reuse the installed toolchain.

### Ruby does not satisfy the Gemfile

The documentation build requires Ruby 3, not the macOS system Ruby or Ruby 4. The helper installs and selects `ruby@3.4` automatically. To repair it manually:

```bash
brew install ruby@3.4
export PATH="$(brew --prefix ruby@3.4)/bin:$PATH"
ruby --version
```

### Signing identity is missing

If `security find-identity -v -p codesigning` reports `0 valid identities found`, check the certificate in **Keychain Access → login → My Certificates**:

- Its exact name must be `aerospace-codesign-certificate` and its type must be **Code Signing**.
- Expanding the certificate must show its private key. A certificate without the matching private key is not a signing identity.
- Its **Trust** settings must allow code signing; set **Code Signing** (or **When using this certificate**) to **Always Trust**.

This result normally indicates a certificate, private-key, or trust-setting problem—not a terminal application's permission to access Keychain. Recreate the certificate by following the steps above if any of these checks fail.

### The old version is still running

Replacing `/Applications/AeroSpace.app` does not replace an already-running process. Quit AeroSpace completely and reopen it before testing the new command or binding.
