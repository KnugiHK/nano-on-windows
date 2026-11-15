# Windows Binaries of GNU nano 9.3

GNU nano is a small, friendly text editor for use in a terminal.

This project provides statically linked Windows builds of GNU nano for x86, x64, and ARM64. The binaries are cross-compiled on Ubuntu using mingw-w64 and llvm-mingw.

> [!TIP]
> Native Windows on ARM (ARM64) binaries are available.

## How to use nano

Download a standalone executable from the [latest release](https://github.com/KnugiHK/nano-for-windows/releases/latest) and run it from a terminal:

```powershell
.\nano-x64.exe .\file.txt
```

For instructions on using GNU nano, see the [official documentation](https://www.nano-editor.org/docs.php).

## Build environment

- **Cross-compiled builds**: GitHub Actions builds the Windows binaries on Ubuntu using mingw-w64 for x86 and x64, and llvm-mingw for ARM64.
- **Statically linked ncurses**: The required ncurses library is statically linked. The binaries rely on standard Windows system DLLs, not third-party DLLs.
- **Native terminal support**: ncurses is built with its Win32 console driver and bundled terminal descriptions, supporting Windows Terminal, ConPTY, SSH, and the classic console.
- **Windows configuration paths**: Nano searches standard Windows locations for its configuration and syntax files, including `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%`, and `C:/ProgramData/nano`.

### Supported architectures

| Binary | Architecture |
| --- | --- |
| `nano-x86.exe` | 32-bit x86 |
| `nano-x64.exe` | 64-bit x64 |
| `nano-arm64.exe` | 64-bit ARM64 |

### Configuration

Nano checks for system-wide configuration in `C:/ProgramData/nano/nanorc` and next to `nano.exe`. User configuration can be placed in `%XDG_CONFIG_HOME%/nano/nanorc`, `%HOME%/.nanorc` or `%USERPROFILE%/.nanorc`, `%HOME%/.config/nano/nanorc` or `%USERPROFILE%/.config/nano/nanorc`, `%APPDATA%/nano/nanorc`, or `%LOCALAPPDATA%/nano/nanorc`.

To load the syntax highlighting files from `datafiles.zip`, extract the archive and add this line to your `nanorc` file, adjusting the path to the extracted `share/nano` directory:

```nanorc
include "C:/ProgramData/nano/share/nano/*.nanorc"
```

The release's `datafiles.zip` contains the complete `share` directory and the `LICENSE` file. Extract it to the location referenced by your `nanorc` include.

## Local build

To build GNU nano for Windows on Ubuntu or WSL, install the required tools:

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
  wget \
  patch
```

Then clone this repository and run the build script:

```bash
git clone https://github.com/KnugiHK/nano-for-windows.git
cd nano-for-windows

./build.sh             # Builds x86 and x64
./build.sh x86         # Builds x86 only
./build.sh x64         # Builds x64 only
./build.sh arm64       # Builds ARM64 only (downloads llvm-mingw if needed)
./build.sh all         # Builds all three architectures
```

Build outputs, downloaded sources, and temporary files are kept in the gitignored `build-nano/` directory. Run the Windows smoke tests with:

```bash
python3 nano_tests.py --arch all
```

## Verifying Build Integrity

To ensure that the release files were built directly from this source code via GitHub Actions and have not been tampered with, GitHub Artifact Attestations is used. You can verify the authenticity of all three executables and `datafiles.zip` using the GitHub CLI.

### Using PowerShell (Windows)

```powershell
Get-Item nano*.exe, datafiles.zip | ForEach-Object { gh attestation verify $_.FullName -R KnugiHK/nano-for-windows }
```

### Using Bash (Linux/WSL/macOS)

```bash
for file in nano*.exe datafiles.zip; do gh attestation verify "$file" -R KnugiHK/nano-for-windows; done
```

## License

GNU nano is distributed under the GNU General Public License version 3 or later (GPLv3+). ncurses is distributed under the MIT-style X11 License.
