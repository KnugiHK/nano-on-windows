# nano-on-windows

Statically linked builds of **GNU nano** (x86, x64, arm64) for Windows, cross-compiled on Ubuntu using `mingw-w64` and `llvm-mingw`. Inspired by and architecturally aligned with [KnugiHK/wget-on-windows](https://github.com/KnugiHK/wget-on-windows).

---

## Features

* **Zero External DLL Dependencies:** Statically linked against `ncursesw` (`--enable-widec --enable-term-driver --enable-sp-funcs --enable-interop`). Depends only on standard Windows system DLLs (`KERNEL32.dll`, `USER32.dll`, `ADVAPI32.dll`, `SHLWAPI.dll`, and the Windows C Runtime).
* **Three Native Architectures:**
  * `nano-x86.exe` — 32-bit x86 (`i686-w64-mingw32`)
  * `nano-x64.exe` — 64-bit x86_64 (`x86_64-w64-mingw32`)
  * `nano-arm64.exe` — 64-bit ARM64 (`aarch64-w64-mingw32` via `llvm-mingw`)
* **Native Windows Terminal, ConPTY, SSH & `conhost.exe` Support:**
  * Compiles `ncursesw` with both the native Win32 Console driver (`win32con`) and built-in terminfo fallback tables (`xterm-256color`, `xterm`, `vt100`, `vt220`, `cygwin`, `linux`, `dumb`).
  * Automatically configures UTF-8 console codepages (`CP_UTF8`) and detects Windows Terminal (`WT_SESSION`), VS Code integrated terminals (`TERM_PROGRAM`), and OpenSSH sessions without requiring an external `/usr/share/terminfo` installation.
* **Windows-Native Configuration Paths:** Resolves `nanorc` and syntax highlighting files across standard Windows environment variables (`%USERPROFILE%`, `%APPDATA%`, `%LOCALAPPDATA%`, `C:/ProgramData/nano`, and portable executable directories).

---

## Configuration & `nanorc` Search Order

`nano-on-windows` searches for configuration files in the following order:

### 1. System-Wide Configuration
1. `C:/ProgramData/nano/nanorc`
2. `<directory-of-nano.exe>/nanorc` *(portable fallback)*

### 2. User Configuration (First match wins)
1. `%XDG_CONFIG_HOME%/nano/nanorc`
2. `%HOME%/.nanorc` or `%USERPROFILE%/.nanorc`
3. `%HOME%/.config/nano/nanorc` or `%USERPROFILE%/.config/nano/nanorc`
4. `%APPDATA%/nano/nanorc` (e.g., `C:/Users/<You>/AppData/Roaming/nano/nanorc`)
5. `%LOCALAPPDATA%/nano/nanorc` (e.g., `C:/Users/<You>/AppData/Local/nano/nanorc`)

To enable all bundled syntax highlighting rules from the release `.zip`, add the following line to your `nanorc` (using forward slashes):

```nanorc
include "C:/ProgramData/nano/share/nano/*.nanorc"
```

---

## Building from Source (Ubuntu)

### 1. Install Prerequisites

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  mingw-w64 \
  pkg-config \
  ncurses-bin \
  ncurses-term \
  texinfo \
  xz-utils \
  zip \
  wget \
  patch
```

*(Optional for `arm64`)* Download and add [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) to your `PATH`.

### 2. Run the Build Script

```bash
# Build x86 and x64
./build.sh both

# Build a single architecture
./build.sh x64
./build.sh x86
./build.sh arm64

# Build all three architectures (x86, x64, arm64)
./build.sh all
```

### 3. Run the Smoke Test Suite

```bash
python3 nano_tests.py --arch all
```

> **Note:** All build temporary files (tarball cache, toolchains, build trees, install staging) and the output binaries (`nano-x86.exe`, `nano-x64.exe`, `nano-arm64.exe`, plus the portable `nano-<version>-win-<arch>.zip` bundles) are produced inside the `build-nano/` directory. Nothing is written to the repository root, and the entire directory is gitignored.

---

## Verifying Build Provenance & Checksums

All official GitHub Actions builds generate SLSA Build Level 2 provenance attestations via `actions/attest-build-provenance`. You can verify any downloaded binary using the [GitHub CLI](https://cli.github.com/):

```bash
gh attestation verify nano-x64.exe --repo <owner>/nano-on-windows
```

Or verify against `SHA256SUMS.txt` on Windows PowerShell:

```powershell
Get-FileHash .\nano-x64.exe -Algorithm SHA256
```

---

## License

GNU `nano` is distributed under the **GNU General Public License v3.0 or later (GPLv3+)**. `ncurses` is distributed under the **MIT-style X11 License**.
