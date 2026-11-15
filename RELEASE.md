## GNU nano for Windows - Static Release Binaries

Statically linked Windows executables of **GNU nano** (x86, x64, arm64) with zero external third-party DLL dependencies.

### Component Versions

| Component | Version | Configuration / Notes |
| --- | --- | --- |
| **GNU nano** | `9.3` | `--enable-utf8 --disable-nls --disable-libmagic --disable-speller` |
| **ncursesw** | `6.6` | `--enable-widec --enable-term-driver --enable-sp-funcs --enable-interop` |
| **x86 / x64 Toolchain** | `mingw-w64` (GCC) | Ubuntu `i686-w64-mingw32-gcc` / `x86_64-w64-mingw32-gcc` |
| **ARM64 Toolchain** | `llvm-mingw` (20261104) | `aarch64-w64-mingw32-clang` (UCRT) |

### Included Release Assets

| Asset | Architecture | Description |
| --- | --- | --- |
| `nano-x64.exe` | 64-bit `x86_64` | Standalone single-file executable |
| `nano-x86.exe` | 32-bit `i686` | Standalone single-file executable |
| `nano-arm64.exe` | 64-bit `ARM64` | Standalone single-file executable for Windows on ARM |
| `datafiles.zip` | All | Complete `share` directory and the `LICENSE` file |

### Attestation Verification

Verify build provenance for the executables and data archive using the GitHub CLI:

```bash
gh attestation verify nano-x86.exe --repo KnugiHK/nano-for-windows
gh attestation verify nano-x64.exe --repo KnugiHK/nano-for-windows
gh attestation verify nano-arm64.exe --repo KnugiHK/nano-for-windows
gh attestation verify datafiles.zip --repo KnugiHK/nano-for-windows
```
