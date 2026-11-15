#!/usr/bin/env python3
"""
nano_tests.py — Automated smoke test and static PE verification suite for nano-on-windows.

Validates:
1. Binary presence and non-zero size for x86, x64, and arm64.
2. PE COFF header machine architecture codes and subsystem type (IMAGE_SUBSYSTEM_WINDOWS_CUI).
3. Absence of non-system dynamic DLL dependencies (verifies static ncursesw linking).
4. Runtime execution of `nano --version` and `nano --help` on compatible hosts.
5. Compiled-in VT mouse tracking sequences (DECSET fallback for passthrough hosts).
6. ConPTY mouse relay (`ENABLE_MOUSE_INPUT` / QuickEdit handling) in ncurses for Windows Terminal mouse reporting.
"""

import argparse
import os
import platform
import re
import struct
import subprocess
import sys
import unittest
from pathlib import Path

# PE Constants
IMAGE_DOS_SIGNATURE = 0x5A4D       # "MZ"
IMAGE_NT_SIGNATURE = 0x00004550    # "PE\0\0"
IMAGE_SUBSYSTEM_WINDOWS_CUI = 3    # Console subsystem

EXPECTED_MACHINE_TYPES = {
    "x86": 0x014C,    # IMAGE_FILE_MACHINE_I386
    "x64": 0x8664,    # IMAGE_FILE_MACHINE_AMD64
    "arm64": 0xAA64,  # IMAGE_FILE_MACHINE_ARM64
}

FORBIDDEN_DLL_PREFIXES = (
    "libncurses",
    "ncurses",
    "libtinfo",
    "libtic",
    "libintl",
    "libiconv",
    "libmagic",
    "libwinpthread",
    "libgcc_s",
    "cygwin1",
    "msys-",
)


def parse_pe_metadata(filepath: Path) -> dict:
    """Parse PE headers using standard library struct to extract machine type and subsystem."""
    data = filepath.read_bytes()
    if len(data) < 64:
        raise ValueError(f"{filepath} is smaller than a minimal DOS header.")

    mz_sig = struct.unpack_from("<H", data, 0)[0]
    if mz_sig != IMAGE_DOS_SIGNATURE:
        raise ValueError(f"{filepath} does not start with an MZ header (0x{mz_sig:04x}).")

    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if len(data) < pe_offset + 24:
        raise ValueError(f"{filepath} truncated before PE header at offset {pe_offset}.")

    pe_sig, machine, num_sections, _, _, _, opt_hdr_size, characteristics = struct.unpack_from(
        "<IHHIIIHH", data, pe_offset
    )
    if pe_sig != IMAGE_NT_SIGNATURE:
        raise ValueError(f"{filepath} invalid PE signature (0x{pe_sig:08x}).")

    opt_offset = pe_offset + 24
    opt_magic = struct.unpack_from("<H", data, opt_offset)[0]
    # Subsystem is at offset 68 in both PE32 (0x10b) and PE32+ (0x20b) optional headers
    subsystem = struct.unpack_from("<H", data, opt_offset + 68)[0]

    # Parse actual PE import table to find DLL dependencies
    # Data directories start at offset 96 (PE32) or 112 (PE32+)
    is_pe32_plus = (opt_magic == 0x20b)
    data_dir_offset = opt_offset + (112 if is_pe32_plus else 96)
    
    # Import table is the second data directory entry (index 1)
    import_rva = struct.unpack_from("<I", data, data_dir_offset + 8)[0]
    import_size = struct.unpack_from("<I", data, data_dir_offset + 12)[0]
    
    # Find the section containing the import table to convert RVA to file offset
    sections_offset = opt_offset + opt_hdr_size
    leaked_dlls = []
    
    if import_rva > 0 and import_size > 0:
        # Find the section containing the import RVA
        for i in range(num_sections):
            sec_offset = sections_offset + i * 40
            sec_virt_addr = struct.unpack_from("<I", data, sec_offset + 12)[0]
            sec_virt_size = struct.unpack_from("<I", data, sec_offset + 8)[0]
            sec_raw_offset = struct.unpack_from("<I", data, sec_offset + 20)[0]
            
            if sec_virt_addr <= import_rva < sec_virt_addr + sec_virt_size:
                import_file_offset = import_rva - sec_virt_addr + sec_raw_offset
                
                # Parse import directory entries (20 bytes each, null-terminated)
                idx = import_file_offset
                while idx + 20 <= len(data):
                    name_rva = struct.unpack_from("<I", data, idx + 12)[0]
                    if name_rva == 0:
                        break
                    
                    # Convert name RVA to file offset and read DLL name
                    if sec_virt_addr <= name_rva < sec_virt_addr + sec_virt_size:
                        name_offset = name_rva - sec_virt_addr + sec_raw_offset
                        name_end = data.find(b'\x00', name_offset)
                        if name_end > name_offset:
                            dll_name = data[name_offset:name_end].decode("ascii", errors="ignore").lower()
                            for prefix in FORBIDDEN_DLL_PREFIXES:
                                if dll_name.startswith(prefix.lower()):
                                    leaked_dlls.append(dll_name)
                                    break
                    idx += 20
                break

    return {
        "machine": machine,
        "opt_magic": opt_magic,
        "subsystem": subsystem,
        "characteristics": characteristics,
        "leaked_dlls": leaked_dlls,
    }


def can_execute_arch(arch: str) -> bool:
    """Return True if the current OS and CPU can natively run the target Windows binary."""
    if sys.platform != "win32":
        return False
    host_machine = platform.machine().lower()
    if arch == "x86":
        return host_machine in ("x86", "i386", "i686", "amd64", "x86_64", "arm64", "aarch64")
    if arch == "x64":
        return host_machine in ("amd64", "x86_64", "arm64", "aarch64")
    if arch == "arm64":
        return host_machine in ("arm64", "aarch64")
    return False


class NanoWindowsTestSuite(unittest.TestCase):
    TARGET_ARCHES = ["x86", "x64", "arm64"]

    def test_01_pe_headers_and_static_linking(self):
        """Verify PE machine type, console subsystem, and absence of non-system DLL imports."""
        for arch in self.TARGET_ARCHES:
            exe_path = Path("build-nano") / f"nano-{arch}.exe"
            with self.subTest(arch=arch):
                self.assertTrue(exe_path.is_file(), f"Missing binary: {exe_path}")
                self.assertGreater(exe_path.stat().st_size, 100_000, f"{exe_path} is unexpectedly small")

                meta = parse_pe_metadata(exe_path)
                expected_machine = EXPECTED_MACHINE_TYPES[arch]
                self.assertEqual(
                    meta["machine"],
                    expected_machine,
                    f"{exe_path} machine type 0x{meta['machine']:04x} != expected 0x{expected_machine:04x}",
                )
                self.assertEqual(
                    meta["subsystem"],
                    IMAGE_SUBSYSTEM_WINDOWS_CUI,
                    f"{exe_path} is not a Windows Console (CUI) binary",
                )
                self.assertEqual(
                    meta["leaked_dlls"],
                    [],
                    f"{exe_path} dynamically imports forbidden non-system DLLs: {meta['leaked_dlls']}",
                )

    def test_02_version_output(self):
        """Execute `nano-<arch>.exe --version` and verify version banner and UTF-8 build flags."""
        for arch in self.TARGET_ARCHES:
            if not can_execute_arch(arch):
                continue
            exe_path = (Path("build-nano") / f"nano-{arch}.exe").resolve()
            with self.subTest(arch=arch):
                proc = subprocess.run(
                    [str(exe_path), "--version"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=15,
                )
                self.assertEqual(
                    proc.returncode,
                    0,
                    f"{exe_path.name} --version failed with code {proc.returncode}: {proc.stderr}",
                )
                self.assertIn("GNU nano", proc.stdout)
                self.assertIn("Compiled options:", proc.stdout)
                self.assertIn("--enable-utf8", proc.stdout)

    def test_03_help_output(self):
        """Execute `nano-<arch>.exe --help` and verify CLI option documentation."""
        for arch in self.TARGET_ARCHES:
            if not can_execute_arch(arch):
                continue
            exe_path = (Path("build-nano") / f"nano-{arch}.exe").resolve()
            with self.subTest(arch=arch):
                proc = subprocess.run(
                    [str(exe_path), "--help"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=15,
                )
                self.assertEqual(
                    proc.returncode,
                    0,
                    f"{exe_path.name} --help failed with code {proc.returncode}: {proc.stderr}",
                )
                self.assertIn("--version", proc.stdout)
                self.assertIn("--rcfile", proc.stdout)
                self.assertIn("--noread", proc.stdout)

    def test_04_invalid_option_clean_exit(self):
        """Ensure an unrecognized CLI flag exits cleanly with a non-zero code without crashing."""
        for arch in self.TARGET_ARCHES:
            if not can_execute_arch(arch):
                continue
            exe_path = (Path("build-nano") / f"nano-{arch}.exe").resolve()
            with self.subTest(arch=arch):
                proc = subprocess.run(
                    [str(exe_path), "--definitely-not-a-valid-flag"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    timeout=15,
                )
                self.assertNotEqual(proc.returncode, 0)
                # Ensure process did not crash with Windows STATUS_ACCESS_VIOLATION (0xC0000005)
                self.assertNotEqual(proc.returncode & 0xFFFFFFFF, 0xC0000005)


    def test_05_mouse_wheel_support(self):
        """Verify the compiled-in VT mouse DECSET sequences (fallback path).

        NOTE: under ConPTY (Windows Terminal) conhost absorbs these
        sequences before they reach the terminal, so their presence alone
        does NOT prove wheel support there.  The sequences only take
        effect on hosts that pass client output through to the terminal
        verbatim.  The ConPTY registration mechanism is verified
        separately by test_06.
        """
        enable_seq = b"\x1b[?1006h\x1b[?1000h"
        disable_seq = b"\x1b[?1000l\x1b[?1006l"
        for arch in self.TARGET_ARCHES:
            exe_path = Path("build-nano") / f"nano-{arch}.exe"
            with self.subTest(arch=arch):
                self.assertTrue(exe_path.is_file(), f"Missing binary: {exe_path}")
                data = exe_path.read_bytes()
                self.assertIn(
                    enable_seq,
                    data,
                    f"{exe_path.name} lacks the VT mouse-enable sequence "
                    "(mouse wheel will not work on passthrough hosts)",
                )
                self.assertIn(
                    disable_seq,
                    data,
                    f"{exe_path.name} lacks the VT mouse-disable sequence",
                )

    def test_06_mouse_relay_mechanism(self):
        """Verify the ConPTY mouse relay mechanism is compiled into ncurses.

        Under ConPTY the only mouse registration channel is the
        ENABLE_MOUSE_INPUT console flag on the input handle (conhost then
        emits the mouse-mode sequences to the terminal), and quick-edit
        mode must be toggled in the same call or the flag stays
        suppressed.  This is behavior invisible in the binary as a plain
        string, so it is verified at two artifact levels:

        1. The static ncurses archive must export the patched
           `_nc_console_mouse_tracking` symbol (i.e. the patched object
           is what nano links against).
        2. If the build tree is still present, the sources that were
           compiled must contain the relay logic (mode-flag toggle with
           ENABLE_QUICK_EDIT_MODE / ENABLE_EXTENDED_FLAGS) and the
           wheel-to-arrow-key binding in nano.
        """
        for arch in self.TARGET_ARCHES:
            with self.subTest(arch=arch):
                lib_path = Path("build-nano") / "install" / arch / "lib" / "libncursesw.a"
                self.assertTrue(lib_path.is_file(), f"Missing library: {lib_path}")

                # 1. Symbol check on the linked archive (durable artifact).
                symbol = "_nc_console_mouse_tracking"
                try:
                    proc = subprocess.run(
                        ["nm", str(lib_path)],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        timeout=30,
                    )
                    symtable = proc.stdout
                except (FileNotFoundError, subprocess.TimeoutExpired):
                    symtable = lib_path.read_bytes()
                self.assertRegex(
                    symtable.decode("utf-8", errors="replace"),
                    rf"\b T {re.escape(symbol)}\b",
                    f"{lib_path} does not export {symbol}; the ConPTY mouse "
                    "relay patch was not applied/linked",
                )

                # 2. Source-level checks on the tree that was compiled.
                ncurses_src = (
                    Path("build-nano") / "build" / arch / "ncurses-6.6" / "ncurses"
                )
                nano_src = Path("build-nano") / "build" / arch / "nano-9.3" / "src"
                if not ncurses_src.is_dir() or not nano_src.is_dir():
                    continue  # build tree cleaned; symbol check above still ran

                win32con = (ncurses_src / "tinfo" / "lib_win32con.c").read_text(
                    encoding="utf-8", errors="replace"
                )
                # The relay: mouse flag toggled together with quick-edit mode.
                self.assertIn("ENABLE_MOUSE_INPUT", win32con)
                self.assertIn("ENABLE_QUICK_EDIT_MODE", win32con)
                self.assertIn("ENABLE_EXTENDED_FLAGS", win32con)
                self.assertIn("_nc_console_mouse_tracking", win32con)

                lib_mouse = (ncurses_src / "base" / "lib_mouse.c").read_text(
                    encoding="utf-8", errors="replace"
                )
                # Wheel events delivered immediately (no click-interval wait).
                self.assertIn("M_TERM_DRIVER", lib_mouse)
                self.assertIn("BUTTON4_PRESSED", lib_mouse)

                winio = (nano_src / "winio.c").read_text(
                    encoding="utf-8", errors="replace"
                )
                # Wheel moves the cursor (arrow keys), gated to Windows.
                self.assertIn("_WIN32", winio)
                self.assertIn("KEY_UP : KEY_DOWN", winio)


def main():
    parser = argparse.ArgumentParser(description="Smoke test GNU nano Windows binaries.")
    parser.add_argument(
        "--arch",
        default="all",
        choices=["x86", "x64", "arm64", "both", "all"],
        help="Target architecture(s) to validate.",
    )
    args, remaining = parser.parse_known_args()

    if args.arch == "both":
        NanoWindowsTestSuite.TARGET_ARCHES = ["x86", "x64"]
    elif args.arch == "all":
        NanoWindowsTestSuite.TARGET_ARCHES = ["x86", "x64", "arm64"]
    else:
        NanoWindowsTestSuite.TARGET_ARCHES = [args.arch]

    unittest.main(argv=[sys.argv[0]] + remaining, verbosity=2)


if __name__ == "__main__":
    main()
