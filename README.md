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

### The 32-bit build has no JIT, and cannot have one without new code

`dsperate-a30` is **interpreter + portable C++ renderer**. That is not a build-flag
oversight, it is what DSperate currently is on a 32-bit host:

- **The recompiler emits AArch64.** `src/core/cpu/jit/emit.h` is an AArch64 encoder, and
  the design leans on AArch64's register file: guest r0–r7/r13/r14 are pinned in x19–x28,
  r8–r12 in x9–x13, plus the cycle budget, page-table base, timing table, arena base and
  context pointer — about 19 pinned host registers, 15 of them holding guest state. That
  is what buys "linked blocks reconcile nothing". ARM32 has 16 registers with SP/LR/PC
  spoken for, so the scheme does not shrink to fit; an ARM32 target needs a different
  register allocator, i.e. a new backend, not a port.
- **The NEON kernels use A64-only intrinsics** — 31 uses across `kernels_neon.cpp` and
  `render3d.cpp` (`vaddvq`-class horizontal reductions, `vqtbl`, `float64x2`). ARMv7 NEON
  has none of them.

`CMakeLists.txt` turns both off automatically for a non-aarch64 `CMAKE_SYSTEM_PROCESSOR`,
so the build succeeds quietly. `build-a30.sh` asserts they are off and records it in
`BUILD_INFO`, so the tarball never implies otherwise.

DraStic does have an ARM32 recompiler, which is why it runs on these devices — so the
technique is proven on this class of hardware. Whether it is worth reimplementing is a
question about measured interpreter speed, not about whether it is possible.

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
  involved. The build asserts `SDL_VIDEO_DRIVER_WAYLAND` survived configure, because
  without it `display_wl.cpp` fails 200 lines later on a union member.
- **ALSA and Wayland are dlopen'd by DSperate itself**, so neither is a link-time
  dependency and neither needs bundling. The Wayland path is dead on our devices anyway —
  SDL uses KMSDRM or fbdev there — and it degrades by itself.
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

`patches/` is applied to every target — `*.patch` via `git apply`, `*.py` via `python3`.

- `0001-dmabuf-guard-no-wayland.py` — `display_wl.cpp` reads `wm.info.wl`, but
  `SDL_syswm.h` only declares that member when SDL was built with wayland. Every embedded
  SDL2 on a 32-bit spruce device is a Mali fbdev build with none (the A30's has zero
  wayland strings), so the file will not compile there. Guards `DmabufOut::open`, which
  already returns false to mean "no dmabuf, use the normal blit" — the same answer the
  runtime check gives on such a device. No-op where SDL does have wayland.

- `0002-screen-rotation.py` — adds `DS_ROTATE=0|90|180|270`. The A30's panel is mounted
  at 270° (spruce's own PyUI reports `screen_rotation() == 270` for it, and vTree passes
  `--rotate=3` there), and DSperate has no rotation of any kind, so everything renders
  sideways. The layout keeps working in an unrotated logical viewport — `out_size()`
  reports the swapped size, and since `layout()`, `build_scale()` and `map_point()` all
  size themselves from it, the whole geometry rotates with no other changes — and only
  the present rotates, via a logical-sized render target blitted with
  `SDL_RenderCopyEx`. Rotating a WxH rect about its own centre gives an HxW footprint,
  so a logical rect centred in the window lands exactly on the panel. Free on a Mali.
  Inert unless `DS_ROTATE` is set.

  Two limits, neither reachable on the devices this is for: per-scanline scaling is
  disabled while rotating (it writes into the window surface with no renderer in play,
  so there is nothing to rotate with — and it is off by default outside Wayland anyway),
  and `SDL_FINGER*` touch is not remapped (the mouse path via `map_point` is). The A30
  and Mini have neither a touchscreen nor a mouse.

## Running it on an A30

```sh
DS_ROTATE=270 ./dsperate-sdl game.nds --fullscreen
```

If the image comes out upside down, use `DS_ROTATE=90` — which of the two is right is a
property of the panel, and this has not been on hardware yet.

## Not done here

Wiring DSperate into spruceOS as an `Emu/NDS` emulator option alongside the three DraStic
builds — that is a spruceOS-side change (`config.json` `menuOptions`, a launch case, and
the process lists in `send_menu_button_to_retroarch`, `kill_ra_and_standard_emulators`
and `EMU_PROCESSES`).
