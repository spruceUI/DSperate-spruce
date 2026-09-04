# DSperate-spruce

Cross-compiled [DSperate](https://github.com/beebono/DSperate) (Nintendo DS) builds for
[spruceOS](https://github.com/spruceUI/spruceOS).

## Why this repo

Upstream CI builds on `ubuntu-24.04-arm`. That runner's glibc is 2.39, so the release
tarball will not load on any spruce device — every aarch64 device we ship on is at
glibc 2.31 or older. This repo cross-compiles the same source on Ubuntu 20.04 multiarch
so the binary matches the floor our other universal binaries hold (`ra64.universal`,
`flycast`, `pcsx_rearmed`, `vtree.aarch64`), and fails the build if it ever drifts above it.

## Builds

| Build | Output | Devices | Base |
|-------|--------|---------|------|
| Universal | `dsperate-aarch64.tar.gz` | Brick, Brick Pro, TSP, TSPS, Flip, Pixel2, Anbernic XX (BaseOS), RGB30 | Ubuntu 20.04 multiarch, GCC 10 (glibc 2.31) |
| A30 | `dsperate-a30.tar.gz` | A30 (armhf, Cortex-A7) | A30 buildroot, GCC 13.2 (glibc 2.23) |

### The 32-bit build got a JIT — upstream wrote the backend

`dsperate-a30` used to be **interpreter + portable C++ renderer**, and this section used to
explain at length why it could not be anything else: the recompiler emitted AArch64 and
pinned ~19 host registers (15 of them guest state), which does not shrink onto ARM32's 16
with SP/LR/PC spoken for, and the NEON kernels used 31 A64-only intrinsics. A new backend,
not a port.

Upstream wrote it. As of 1.6.0 there is `src/core/cpu/jit/a32` and an ARMv7-expressible
kernel subset, and this target builds both — CMake says `ARMv7 host; NEON kernels built
from the A32 subset`, and the `jit` test passes under `qemu-arm` alongside the other 14.

`build-a30.sh` no longer asserts they are off. It **reads** `DSPERATE_JIT` /
`DSPERATE_NEON` out of `compile_commands.json` and writes what it finds into `BUILD_INFO`,
because the hardcoded "jit: OFF / expect it to be slow" text outlived the fact and shipped
a tarball describing a recompiler build as an interpreter one.

### The universal build

JIT and NEON are both on: the cross toolchain reports `CMAKE_SYSTEM_PROCESSOR=aarch64`,
which is what DSperate keys `DSPERATE_JIT` / `DSPERATE_NEON` off. The build hard-fails if
either ends up off, because an interpreter-only binary still runs — just slowly, with
nothing in any log to say why.

## Usage

```bash
# Trigger a build
gh workflow run build-all.yml

# ...against a specific upstream ref
gh workflow run build-all.yml -f dsperate_version=v0.1.0

# Download the output
gh release download beta-main -p "dsperate-aarch64.tar.gz" -R spruceUI/DSperate-spruce
```

## Output structure

```
dsperate            # the SDL2 frontend, what a device runs
dsperate-headless   # headless harness (traces, frame dumps, benchmarks)
configs/            # upstream's ready-made settings files, incl. drastic.ini
                    # and advdrastic.ini (Knulli's "Advanced DraStic" hotkeys)
libs/               # non-device-provided shared libraries (usually absent)
BUILD_INFO          # upstream commit, toolchain, flags
LICENSE  README.md
```

DSperate needs a DS BIOS pair and firmware (`bios9.bin`, `bios7.bin`, `firmware.bin`)
dumped from your own console. None are included here, and none can be.

## Build details

- **glibc 2.31 floor, enforced.** The build reads the maximum `GLIBC_2.x` symbol version
  out of both binaries and fails if it exceeds `GLIBC_MAX` (2.31). It also fails if any
  `GLIBCXX_`/`CXXABI_` symbol survives, which would mean `-static-libstdc++` silently
  did not take.
- **`-pthread` is added by this build.** DSperate uses `std::thread` (the 3D raster
  workers, the engine-B line worker, the headless harness) but never links `Threads::Threads`.
  Upstream never notices: glibc 2.34 folded libpthread into libc, so on a 24.04 runner
  the symbols are already there. At 2.31 they are in `libpthread.so.0` and must be asked
  for. `-Wl,--no-as-needed` goes with it because CMake puts linker flags ahead of the
  objects that reference them, and as-needed would drop the library again.
- **libstdc++ and libgcc are static.** Several devices ship a libstdc++ older than this
  toolchain's. glibc stays dynamic — it is the floor being matched, not something to
  carry.
- **SDL2 is built from source at 2.26.1, linked but not bundled.** The device supplies
  libSDL2 at runtime — `/usr/trimui/lib` on TrimUI, `spruce/flip/lib` on Flip,
  `App/PyUI/dll-mali` on the Anbernic XX line. focal's own libsdl2-dev is 2.0.10 and is
  deliberately not installed: DSperate needs 2.0.12 for `SDL_TouchFingerEvent.windowID`
  (which routes the touchscreen to the window a touch landed in) and 2.0.22 for
  `SDL_SysWMinfo`'s `wl.xdg_toplevel`, which `display_wl.cpp` reaches for behind a
  `SDL_VERSION_ATLEAST(2,0,18)` guard — so 2.0.18 through 2.0.20 would compile-fail on
  that member too. 2.26.1 clears both, and it is the **oldest SDL2 spruce ships**
  (2.26.1 / 2.26.5 / 2.30.10 / 2.32.0 across the tree), so compiling against it means we
  can never reach for an API the oldest device lacks — the same discipline as the glibc
  floor. SDL 2.26 vendors its own wayland protocol XML and needs only
  `wayland-client >= 1.18`, which focal has exactly, so no wayland-protocols package is
  involved. The build still asserts `SDL_VIDEO_DRIVER_WAYLAND` survived configure — not
  because anything needs it now, but as a canary for options configure drops in silence.
- **`-DDSPERATE_WAYLAND=OFF` on every target.** Upstream 1.6.0 builds a Wayland dmabuf
  scanout tier whenever the SDL2 it compiles against has wayland in it, and ours does.
  The device SDL2s are KMSDRM or fbdev builds with none and no spruce device runs a
  compositor, so the tier would be dead code compiled against an `SDL_SysWMinfo` layout
  the runtime SDL2 does not share. Upstream's advice to integrators is to pass the flag
  rather than patch the tier out, which is also what retired our `0001` patch.
- **ALSA is dlopen'd by DSperate itself**, so it is not a link-time dependency and does
  not need bundling.
- **`-mtune=cortex-a55`** (override with `ARCH_FLAGS`). Every spruce aarch64 device is a
  Cortex-A53 or A55; `-mtune` changes scheduling only, never the instruction set, so the
  binary stays generic ARMv8-A. It is repeated in the link flags because the core is
  built with LTO, which recompiles at link time against whatever the link command names.
- **GCC 10**, not focal's default 9 (`CROSS_GCC=9` to switch). ccache is attached as a
  CMake compiler *launcher*, not as a wrapper on the compiler path: CMake finds the LTO
  archiver by looking for `gcc-ar` next to the compiler it was given, so a shim makes
  `CMAKE_CXX_COMPILER_AR` come back NOTFOUND and the static library link dies. The
  `gcc-ar-10`/`gcc-ranlib-10` wrappers are named explicitly as well, and configure is
  checked for a NOTFOUND archiver before the build starts.
- **Unit tests run under `qemu-aarch64-static`** as part of the build, including the JIT
  tests that check the recompiler against the interpreter instruction by instruction.
  `-f skip_tests=true` (or `SKIP_TESTS=1`) turns them off.

## Local build

```bash
docker build -t dsperate-builder .
mkdir -p output
docker run --rm -e DSPERATE_VERSION=main -v "$PWD/output:/output" dsperate-builder
```

## Patches

`patches/` is applied to every target — `*.patch` via `git apply`, `*.py` via `python3`. A
patch that no longer applies is fatal, so a drifted patch cannot produce a green build with
the feature silently missing.

It is **empty right now**: upstream 1.6.0 took both patches we carried — the no-wayland
dmabuf guard and `DS_ROTATE` — and `patches/README.md` records what they were and what
replaced them.

## Running it on an A30

The A30's panel is mounted at 270°. `DS_ROTATE` is an **environment variable, not a
command-line flag** — unset, the image is sideways.

```sh
DS_ROTATE=270 ./dsperate game.nds \
  --bios9 /mnt/SDCARD/BIOS/nds/bios9.bin \
  --bios7 /mnt/SDCARD/BIOS/nds/bios7.bin \
  --firmware /mnt/SDCARD/BIOS/nds/firmware.bin \
  --fullscreen
```

Since 1.6.0 this is upstream's own, and it belongs to the display-engine scaler tier: the
hardware layer scales a DS-resolution canvas and NEON kernels do the rotate, which is the
whole reason it exists on a Cortex-A7. The tier is auto wherever `/dev/disp` and `/dev/fb0`
answer, so nothing has to ask for it. `--no-disp` forces it off.

The one line to check on stderr, because it says which tier actually opened:

```
video: display-engine scaler, rot 270, layout …
```

Without it we are on the SDL renderer, which has no rotation of its own — `DS_ROTATE` is
read only on the disp path. `video.disp: /dev/disp not usable; using SDL` is the explicit
version of the same news, and `disp: rotation <x> not supported` means `DS_ROTATE` was
something other than 0/90/180/270.

## Not done here

Wiring DSperate into spruceOS as an `Emu/NDS` emulator option alongside the three DraStic
builds — that is a spruceOS-side change (`config.json` `menuOptions`, a launch case, and
the process lists in `send_menu_button_to_retroarch`, `kill_ra_and_standard_emulators`
and `EMU_PROCESSES`).
