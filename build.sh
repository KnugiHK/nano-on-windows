#!/usr/bin/env bash
# =============================================================================
# build.sh — Cross-compile static GNU nano for Windows (x86, x64, arm64)
# Mirrors the architecture of KnugiHK/wget-on-windows
# Usage: ./build.sh [x86|x64|arm64|both|all]
# =============================================================================
set -e

# -----------------------------------------------------------------------------
# Centralized Component Versions
# -----------------------------------------------------------------------------
NANO_VER="9.3"
NANO_MAJOR="v${NANO_VER%%.*}"
NCURSES_VER="6.6"

# LLVM MinGW toolchain for ARM64 cross-compilation
LLVM_MINGW_VER="20250114"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-20.04-x86_64.tar.xz"

# -----------------------------------------------------------------------------
# Error Handling & Environment Setup
# -----------------------------------------------------------------------------
abort() {
    local lineno="${1:-unknown}"
    local msg="${2:-Build failed}"
    echo "==================================================================" >&2
    echo "[ERROR] ${msg} (at line ${lineno})" >&2
    echo "==================================================================" >&2
    exit 1
}
trap 'abort $LINENO "Unexpected error during build execution"' ERR

NPROC="$(nproc 2>/dev/null || echo 4)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All temporary files and output binaries live inside build-nano/
OUT_DIR="${ROOT_DIR}/build-nano"
TARBALL_CACHE_PATH="${OUT_DIR}/cache"
PATCH_DIR="${ROOT_DIR}/patches"
mkdir -p "${TARBALL_CACHE_PATH}"

log() {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

# -----------------------------------------------------------------------------
# Download & Verification Helper
# -----------------------------------------------------------------------------
download_tarball() {
    local filename="$1"
    local primary_url="$2"
    local mirror_url="${3:-}"
    local dest="${TARBALL_CACHE_PATH}/${filename}"

    if [ -f "${dest}" ]; then
        log "Using cached tarball: ${filename}"
        return 0
    fi

    log "Downloading ${filename} from ${primary_url}..."
    if ! wget --tries=3 --timeout=30 -O "${dest}.tmp" "${primary_url}"; then
        if [ -n "${mirror_url}" ]; then
            log "Primary URL failed; trying mirror ${mirror_url}..."
            wget --tries=3 --timeout=30 -O "${dest}.tmp" "${mirror_url}"
        else
            rm -f "${dest}.tmp"
            abort "$LINENO" "Failed to download ${filename}"
        fi
    fi
    mv "${dest}.tmp" "${dest}"
}

# -----------------------------------------------------------------------------
# ARM64 Toolchain Setup (downloads llvm-mingw if needed)
# -----------------------------------------------------------------------------
setup_arm64_toolchain() {
    local llvm_path="${OUT_DIR}/toolchains/llvm-mingw"
    
    if [ -x "${llvm_path}/bin/aarch64-w64-mingw32-gcc" ]; then
        log "Using cached llvm-mingw toolchain at ${llvm_path}"
    else
        log "Downloading llvm-mingw ${LLVM_MINGW_VER} for ARM64 cross-compilation..."
        mkdir -p "${llvm_path}"
        wget -qO- "${LLVM_MINGW_URL}" | tar -xJ --strip-components=1 -C "${llvm_path}"
        if [ ! -x "${llvm_path}/bin/aarch64-w64-mingw32-gcc" ]; then
            abort "$LINENO" "Failed to setup llvm-mingw toolchain"
        fi
        log "llvm-mingw ${LLVM_MINGW_VER} installed to ${llvm_path}"
    fi
    
    export PATH="${llvm_path}/bin:${PATH}"
}

# -----------------------------------------------------------------------------
# Stage 0: Verify Host Dependencies (including native 'tic' for ncursesw)
# -----------------------------------------------------------------------------
check_host_deps() {
    local mingw_host="$1"
    local missing=()

    for tool in "${mingw_host}-gcc" "${mingw_host}-strip" "${mingw_host}-ar" "${mingw_host}-ranlib" "pkg-config" "make" "patch" "tic" "infocmp" "xz" "zip"; do
        if ! command -v "${tool}" >/dev/null 2>&1; then
            missing+=("${tool}")
        fi
    done

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "[ERROR] Missing required build tools for target ${mingw_host}: ${missing[*]}" >&2
        echo "        On Ubuntu, install: sudo apt-get install -y build-essential mingw-w64 pkg-config ncurses-bin ncurses-term xz-utils zip patch wget" >&2
        echo "        For arm64, ensure llvm-mingw/bin is in your PATH." >&2
        exit 1
    fi

    log "Host tic version: $(tic -V)"
    log "Target compiler:  $(${mingw_host}-gcc --version | head -n 1)"
}

# -----------------------------------------------------------------------------
# Architecture Build Pipeline
# -----------------------------------------------------------------------------
build_arch() {
    local arch="$1"
    local mingw_host=""

    case "${arch}" in
        x86)
            mingw_host="i686-w64-mingw32"
            ;;
        x64)
            mingw_host="x86_64-w64-mingw32"
            ;;
        arm64)
            mingw_host="aarch64-w64-mingw32"
            ;;
        *)
            abort "$LINENO" "Unsupported architecture '${arch}'. Expected: x86, x64, arm64, both, or all."
            ;;
    esac

    log "=================================================================="
    log "Starting build for architecture: ${arch} (${mingw_host})"
    log "=================================================================="

    # For ARM64, download and setup llvm-mingw toolchain if not present
    if [ "${arch}" = "arm64" ]; then
        setup_arm64_toolchain
    fi

    check_host_deps "${mingw_host}"

    local build_path="${OUT_DIR}/build/${arch}"
    local install_path="${OUT_DIR}/install/${arch}"
    local release_path="${OUT_DIR}/release/nano-${NANO_VER}-win-${arch}"
    mkdir -p "${build_path}" "${install_path}" "${release_path}"

    # Download source tarballs once into shared cache
    download_tarball \
        "ncurses-${NCURSES_VER}.tar.gz" \
        "https://ftp.gnu.org/gnu/ncurses/ncurses-${NCURSES_VER}.tar.gz" \
        "https://invisible-mirror.net/archives/ncurses/ncurses-${NCURSES_VER}.tar.gz"

    download_tarball \
        "nano-${NANO_VER}.tar.xz" \
        "https://www.nano-editor.org/dist/${NANO_MAJOR}/nano-${NANO_VER}.tar.xz" \
        "https://ftp.gnu.org/gnu/nano/nano-${NANO_VER}.tar.xz"

    # -------------------------------------------------------------------------
    # Stage 1: Cross-compile static ncursesw
    # -------------------------------------------------------------------------
    if [ ! -f "${install_path}/lib/libncursesw.a" ]; then
        log "[Stage 1/2] Building static ncursesw ${NCURSES_VER} for ${arch}..."
        rm -rf "${build_path}/ncurses-${NCURSES_VER}"
        tar -xzf "${TARBALL_CACHE_PATH}/ncurses-${NCURSES_VER}.tar.gz" -C "${build_path}"
        pushd "${build_path}/ncurses-${NCURSES_VER}" >/dev/null

        if [ -f "${PATCH_DIR}/ncurses-mingw.patch" ]; then
            log "Applying patches/ncurses-mingw.patch..."
            patch -p1 < "${PATCH_DIR}/ncurses-mingw.patch"
        fi

        # Configure ncursesw with:
        # - native Win32 console driver (--enable-term-driver)
        # - compiled-in terminfo fallbacks (--with-fallbacks) via host tic/infocmp
        #   so Windows Terminal (ConPTY), SSH, and legacy conhost work out-of-the-box
        # - static library only (--enable-static --disable-shared)
        CFLAGS="-O2 -pipe -D_WIN32_WINNT=0x0601" \
        LDFLAGS="-static" \
        ./configure \
            --host="${mingw_host}" \
            --build="$(./config.guess)" \
            --prefix="${install_path}" \
            --with-build-cc=gcc \
            --disable-shared \
            --enable-static \
            --without-ada \
            --without-cxx \
            --without-cxx-binding \
            --without-manpages \
            --without-progs \
            --without-tests \
            --without-debug \
            --enable-widec \
            --enable-term-driver \
            --enable-sp-funcs \
            --enable-interop \
            --enable-pc-files \
            --with-pkg-config-libdir="${install_path}/lib/pkgconfig" \
            --with-fallbacks="xterm,xterm-256color,vt100,vt220,cygwin,linux,dumb,unknown" \
            --disable-db-install \
            --disable-home-terminfo

        make -j"${NPROC}" libs
        make install.libs install.includes

        # Ensure standard header and library aliases exist for downstream autoconf checks
        if [ -f "${install_path}/lib/libncursesw.a" ] && [ ! -f "${install_path}/lib/libcurses.a" ]; then
            ln -sf "${install_path}/lib/libncursesw.a" "${install_path}/lib/libcurses.a"
        fi

        popd >/dev/null
        log "[Stage 1/2] Finished static ncursesw ${NCURSES_VER} for ${arch}."
    else
        log "[Stage 1/2] Skipping ncursesw ${NCURSES_VER} (cached at ${install_path}/lib/libncursesw.a)."
    fi

    # -------------------------------------------------------------------------
    # Stage 2: Cross-compile static GNU nano
    # -------------------------------------------------------------------------
    log "[Stage 2/2] Building static GNU nano ${NANO_VER} for ${arch}..."
    rm -rf "${build_path}/nano-${NANO_VER}"
    tar -xJf "${TARBALL_CACHE_PATH}/nano-${NANO_VER}.tar.xz" -C "${build_path}"
    pushd "${build_path}/nano-${NANO_VER}" >/dev/null

    if [ -f "${PATCH_DIR}/nano-windows.patch" ]; then
        log "Applying patches/nano-windows.patch..."
        patch -p1 < "${PATCH_DIR}/nano-windows.patch"
    fi

    export PKG_CONFIG_PATH="${install_path}/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="${install_path}/lib/pkgconfig"
    export NCURSESW_CFLAGS="-I${install_path}/include -I${install_path}/include/ncursesw -DNCURSES_STATIC"
    export NCURSESW_LIBS="-L${install_path}/lib -lncursesw"

    # Pre-seed gnulib and autoconf cache variables for mingw-w64 cross-compilation
    ./configure \
        --host="${mingw_host}" \
        --build="$(./config.guess)" \
        --prefix="${install_path}" \
        --sysconfdir="C:/ProgramData/nano" \
        --disable-nls \
        --enable-utf8 \
        --disable-libmagic \
        --disable-speller \
        --disable-operatingdir \
        gl_cv_func_nanosleep=yes \
        gl_cv_func_working_mktime=yes \
        gl_cv_func_mbrtowc_empty_input=yes \
        ac_cv_func_fcntl=no \
        ac_cv_func_fork=no \
        ac_cv_func_vfork=no \
        ac_cv_func_getpwuid=no \
        ac_cv_func_getpwnam=no \
        ac_cv_func_getpwent=no \
        ac_cv_func_getuid=no \
        ac_cv_func_geteuid=no \
        ac_cv_func_lstat=no \
        ac_cv_func_readlink=no \
        ac_cv_func_symlink=no \
        ac_cv_func_chown=no \
        ac_cv_func_fchown=no \
        ac_cv_func_fchmod=no \
        ac_cv_func_sigaction=no \
        ac_cv_header_pwd_h=no \
        ac_cv_header_termios_h=no \
        ac_cv_header_sys_ioctl_h=no \
        ac_cv_header_sys_wait_h=no \
        ac_cv_header_sys_param_h=yes \
        ac_cv_lib_ncursesw_initscr=yes \
        ac_cv_lib_ncursesw_waddnwstr=yes \
        ac_cv_lib_ncursesw_use_default_colors=yes \
        ac_cv_lib_ncursesw_set_escdelay=yes \
        ac_cv_lib_ncursesw_key_defined=yes \
        CPPFLAGS="-I${install_path}/include -I${install_path}/include/ncursesw -DNCURSES_STATIC -D_WIN32_WINNT=0x0601 -DWIN32_LEAN_AND_MEAN" \
        CFLAGS="-O2 -pipe -ffunction-sections -fdata-sections -Wno-implicit-function-declaration" \
        LDFLAGS="-L${install_path}/lib -static -static-libgcc -Wl,--gc-sections" \
        LIBS="-lncursesw -lshlwapi -ladvapi32 -luser32 -lkernel32"

    make -j"${NPROC}"
    make install
    popd >/dev/null

    # -------------------------------------------------------------------------
    # Post-Build: Strip, Copy & Package Release Bundle
    # -------------------------------------------------------------------------
    local built_exe="${install_path}/bin/nano.exe"
    if [ ! -f "${built_exe}" ]; then
        abort "$LINENO" "Expected output binary ${built_exe} was not produced!"
    fi

    log "Stripping ${built_exe} with ${mingw_host}-strip..."
    "${mingw_host}-strip" --strip-all "${built_exe}"

    # Copy architecture-tagged binary to the build-nano output directory
    cp -f "${built_exe}" "${OUT_DIR}/nano-${arch}.exe"
    log "Created output binary: ${OUT_DIR}/nano-${arch}.exe"

    # Assemble portable release archive (exe + syntax files + sample nanorc + terminfo if present)
    rm -rf "${release_path}"
    mkdir -p "${release_path}/share"
    cp -f "${built_exe}" "${release_path}/nano.exe"
    cp -f "${built_exe}" "${release_path}/nano-${arch}.exe"

    if [ -d "${install_path}/share/nano" ]; then
        cp -rf "${install_path}/share/nano" "${release_path}/share/"
    fi
    if [ -d "${install_path}/share/terminfo" ]; then
        cp -rf "${install_path}/share/terminfo" "${release_path}/share/"
    fi
    if [ -f "${build_path}/nano-${NANO_VER}/doc/sample.nanorc" ]; then
        cp -f "${build_path}/nano-${NANO_VER}/doc/sample.nanorc" "${release_path}/nanorc.sample"
    elif [ -f "${build_path}/nano-${NANO_VER}/doc/sample.nanorc.in" ]; then
        cp -f "${build_path}/nano-${NANO_VER}/doc/sample.nanorc.in" "${release_path}/nanorc.sample"
    fi
    if [ -f "${build_path}/nano-${NANO_VER}/COPYING" ]; then
        cp -f "${build_path}/nano-${NANO_VER}/COPYING" "${release_path}/LICENSE.txt"
    fi

    pushd "${OUT_DIR}/release" >/dev/null
    rm -f "${OUT_DIR}/nano-${NANO_VER}-win-${arch}.zip"
    zip -rq "${OUT_DIR}/nano-${NANO_VER}-win-${arch}.zip" "nano-${NANO_VER}-win-${arch}"
    popd >/dev/null

    log "Packaged release archive: ${OUT_DIR}/nano-${NANO_VER}-win-${arch}.zip"
}

# -----------------------------------------------------------------------------
# CLI Argument Dispatch
# -----------------------------------------------------------------------------
TARGET="${1:-both}"
case "${TARGET}" in
    x86|x64|arm64)
        build_arch "${TARGET}"
        ;;
    both)
        build_arch "x86"
        build_arch "x64"
        ;;
    all)
        build_arch "x86"
        build_arch "x64"
        build_arch "arm64"
        ;;
    *)
        echo "Usage: $0 [x86|x64|arm64|both|all]" >&2
        exit 1
        ;;
esac

log "All requested targets (${TARGET}) completed successfully."
