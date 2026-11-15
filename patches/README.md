# Patch rationale

This directory contains the source patches applied by `build.sh` before
compiling. Each hunk exists for a concrete, Windows-specific reason; this
document explains every one of them. The patches are generated as plain
unified diffs (`patch -p1` from inside the extracted source tree), so the
rationale lives here rather than inside the patch files themselves.

Sources involved:

| Patch | Applies to |
| --- | --- |
| `ncurses-mouse.patch` | ncurses 6.6 — mouse support for the native Win32 console driver |
| `nano-windows.patch` | nano 9.3 — Windows portability + mouse behavior |

(`build.sh` also optionally applies an `ncurses-mingw.patch` if one is
present; none is shipped at the moment.)

Terminology used below:

- **ConPTY** — the pseudo-console API (`CreatePseudoConsole`). Windows
  Terminal, VS Code and friends host console programs through it; conhost
  sits in the middle and translates between the Win32 console API and the
  terminal's VT byte stream.
- **Classic console** — the traditional full-screen console window
  (conhost) used by `cmd.exe` / PowerShell when not hosted by another
  terminal.
- **Win32 console driver** — ncurses' `win32con` term driver
  (`--enable-term-driver`), which talks to the console API directly
  (`ReadConsoleInput`, `SetConsoleMode`, ...) instead of emitting VT
  sequences. nano always runs with this driver on Windows.

---

## `ncurses-mouse.patch`

The Win32 console driver historically dropped scroll-wheel events, and
even with them decoded, nothing told Windows Terminal to *send* mouse
events. The patch addresses decoding, registration, delivery latency and
teardown.

### 1. `curses.priv.h` — prototype

Declares `_nc_console_mouse_tracking()` so the generic mouse code in
`lib_mouse.c` can call into the Windows driver. Needed because the
console driver lives in `lib_win32con.c` while the mouse enable/disable
hook lives in `lib_mouse.c`.

### 2. `lib_mouse.c` — `enable_win32_mouse()`: hook up the registration

Inside the `#if USE_NAMED_PIPES ... #else` branch — i.e. exactly the
native console-driver path this project builds with — the enable/disable
hook now calls `_nc_console_mouse_tracking(enable)`. Without this, nano
could decode wheel events but never *request* them from the terminal, so
nothing ever arrived under ConPTY.

### 3. `lib_mouse.c` — `_nc_mouse_inline()`: deliver wheel events instantly

The Win32 console driver reports a roll of the wheel as a *press* of the
fourth (up) or fifth (down) button. ncurses' input loop, after receiving
a mouse event, waits out the click-recognition interval
(`mouseinterval`, 50 ms in nano) to see whether a press is followed by a
release, so clicks and double-clicks can be composed. A wheel roll never
produces a release, so that wait was pure latency: at human wheel speeds
(notches more than ~50 ms apart) *every* notch stalled the full interval
before nano saw it, making scrolling feel laggy.

For the term driver (`M_TERM_DRIVER`), the hook now reports a queued
wheel event as a complete gesture, so the input loop breaks immediately
and the event is delivered at once. Upstream ncurses already does the
same for xterm-style wheel events; the term-driver path simply never got
the equivalent treatment. Click and double-click recognition is
unaffected.

### 4. `lib_win32con.c` — `mouse_tracking_active` guard

`ENABLE_MOUSE_INPUT` is passed to `SetConsoleMode` only while mouse
tracking is active (and explicitly stripped otherwise). Two reasons:

- Under ConPTY, conhost relays mouse mode to the terminal whenever the
  *effective* `ENABLE_MOUSE_INPUT` flag changes (see item 6). ncurses'
  unrelated console-mode changes (raw mode at startup, restore at
  endwin) would otherwise re-trigger or clobber that relay.
- In a classic console the flag also gates whether mouse records reach
  the input buffer at all, so it must track the application's actual
  mouse state rather than being always-on.

### 5. `lib_win32con.c` — decode wheel records (`is_wheel_event`, `handle_mouse`)

Windows reports a wheel roll as a `MOUSE_EVENT_RECORD` with the
`MOUSE_WHEELED` flag; the scroll amount and direction are packed into
`HIWORD(dwButtonState)` as a signed delta (positive = up), *not* as a
button mask. The stock driver only looked at button masks, so wheel
events were silently dropped. The patch decodes the delta into
`BUTTON4_PRESSED` (up) / `BUTTON5_PRESSED` (down), which nano already
understands. The sign convention is consistent across both delivery
paths (classic console and the ConPTY SGR decode in conhost).
Horizontal-wheel (`MOUSE_HWHEELED`) events are ignored: nano has no
horizontal scrolling, and ncurses' `BUTTON6/7` do not exist at
`NCURSES_MOUSE_VERSION=2`.

### 6. `lib_win32con.c` — push events directly into the event queue

Stock behavior stages events in a driver-local fifo, from which they are
transferred into ncurses' mouse event queue one input cycle later. That
extra hop means the `KEY_MOUSE` code the input machinery reads does not
always correspond to an event already in the queue, which (combined with
item 3's old behavior) delayed delivery. `handle_mouse()` now pushes
each event straight into the screen's event queue
(`sp->_mouse_writep`), so a wheel event is already queued when
`_nc_mouse_inline()` inspects it and can report it as complete.

### 7. `lib_win32con.c` — `_nc_console_mouse_tracking()`: register mouse with the terminal

This is the piece that makes Windows Terminal actually send mouse
events. Two mechanisms are needed because the environment differs:

1. **ConPTY relay (Windows Terminal, VS Code, ...).** conhost *absorbs*
   mouse DECSET sequences (`ESC[?1000h` etc.) written to the output
   handle — they never reach the terminal. The only registration
   channel a local ConPTY client has is the Win32 console flag
   `ENABLE_MOUSE_INPUT` on its *input* handle: when that effective flag
   changes, conhost emits `ESC[?1003;1006h` (or `...l`) to the terminal
   (microsoft/terminal PR #9970). Two subtleties are handled here:
   - *Quick-edit suppression.* conhost computes
     `effective mouse = ENABLE_MOUSE_INPUT & ~ENABLE_QUICK_EDIT_MODE`,
     and quick-edit mode is on by default. The enable path therefore
     clears quick-edit mode (which requires `ENABLE_EXTENDED_FLAGS`) in
     the same `SetConsoleMode` call.
   - *Diff-based relay.* conhost only emits the sequence when the
     effective flag *changes*, so the enable path toggles the mouse
     flag off and on again to guarantee a state change. On disable, the
     saved quick-edit state is restored, which itself triggers the
     relay-off to the terminal.
2. **DECSET fallback (passthrough hosts, e.g. some SSH/embedded
   setups).** For hosts that pass client output through to the terminal
   verbatim, the standard sequences `ESC[?1006h` + `ESC[?1000h` (SGR
   mouse encoding, button presses and wheel rolls) are also emitted.
   They are gated on `ENABLE_VIRTUAL_TERMINAL_PROCESSING` on the output
   handle: a classic console without VT processing would print them as
   garbage.

Quick-edit mode is saved before first use and restored when tracking is
switched off (nano exit or `M-M`), so the user's selection behavior is
unchanged outside the period when nano owns the mouse.

### 8. `lib_win32con.c` — `_nc_console_twait()`: wheel-aware event wait

The wait loop peeks at console input records to decide what woke it up.
Two adjustments:

- Wheel records are recognized up front: when the application expects
  mouse events (`TW_MOUSE` requested) the record is left in the queue
  and `TW_MOUSE` is returned so the read path picks it up immediately;
  when mouse support is off, the record is consumed and dropped instead
  of stalling the wait loop.
- Non-wheel mouse records without any button change (pure motion) are
  consumed and ignored, as before.

---

## `nano-windows.patch`

General Windows portability fixes plus the mouse-behavior adaptation.
All hunks are gated on `#ifdef _WIN32` (or guarded so the POSIX path is
untouched).

### 1. `definitions.h` — headers and compatibility definitions

MinGW lacks a number of POSIX constants nano's code references
unconditionally: signal numbers (`SIGHUP`, `SIGTSTP`, `SIGWINCH`, ...),
group/other file-mode bits (`S_IRGRP`, `S_IWOTH`, ...) and `S_ISLNK`
(nano never follows Windows symlinks; it is defined to 0). `fsync` maps
to `_commit`. `IS_ABSOLUTE_PATH` learns about drive letters (`C:/...`)
and UNC paths (`//server/...`) in addition to the POSIX leading slash.

### 2. `prototypes.h` — declaration

Declares `normalize_slashes()` (see next item).

### 3. `utils.c` — Windows home directory

Windows does not set `HOME`; nano's rcfile and spell/file lookup depend
on finding the user's home. `get_homedir()` now falls back to
`USERPROFILE`, then `HOMEDRIVE` + `HOMEPATH`. Results are normalized to
forward slashes (`normalize_slashes`) because Windows APIs accept both
but string handling and display are simpler with one form. The POSIX
password-database path is left untouched behind `#else`.

### 4. `browser.c` — directory refresh without `rewinddir()`

The file browser rereads the current directory after every operation.
With the gnulib `DIR` replacement used in the MinGW build, native
`rewinddir()` misbehaves; the Windows branch closes and reopens the
directory instead, which is equivalent and safe.

### 5. `files.c` — header and fallback guards

`<sys/wait.h>` does not exist on MinGW and is only needed for POSIX job
control. The `fsync(...)` fallback stub is skipped on Windows because
`fsync` is mapped to `_commit` (item 1) — defining both would clash.

### 6. `nano.c` — no suspend; mouse on by default

- `do_suspend()` sends itself `SIGSTOP`, which does not exist on
  Windows; the call is compiled out there.
- `SET(USE_MOUSE)` runs before the rcfile is read, so the wheel works
  out of the box but a user can still switch it off with
  `unset mouse` (or toggle at runtime with `M-M`).

### 7. `winio.c` — wheel moves the cursor (Windows only)

Upstream since nano 8.0 maps wheel rolls to `M-Up`/`M-Down` twice, which
scroll the *viewport* while the cursor stays anchored to its text
position. On Windows this feels broken in the opposite direction from
most editors (and from what users know from arrow-key "alternate
scroll" in terminals, where the wheel sends arrow keys and the caret
follows). Under `_WIN32` the wheel therefore injects plain
`KEY_UP`/`KEY_DOWN` (two per notch): the cursor moves, and the view
scrolls when the cursor reaches the top or bottom edge. Non-Windows
builds keep the upstream binding unchanged.

---

## Verifying the patches

```
tar -xzf ncurses-6.6.tar.gz && cd ncurses-6.6 && patch -p1 --dry-run < ../../patches/ncurses-mouse.patch
tar -xJf nano-9.3.tar.xz  && cd nano-9.3  && patch -p1 --dry-run < ../../patches/nano-windows.patch
```

Both must apply cleanly (and do; `build.sh` applies them for real before
compiling, and `nano_tests.py` exercises the resulting binaries).
