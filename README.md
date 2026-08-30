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
dsperate            # headless CLI harness (traces, frame dumps, benchmarks)
dsperate-sdl        # the SDL2 frontend, what a device runs
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
  workers, the engine-B line worker, the CLI) but never links `Threads::Threads`.
  Upstream never notices: glibc 2.34 folded libpthread into libc, so on a 24.04 runner
  the symbols are already there. At 2.31 they are in `libpthread.so.0` and must be asked
  for. `-Wl,--no-as-needed` goes with it because CMake puts linker flags ahead of the
  objects that reference them, and as-needed would drop the library again.
- **libstdc++ and libgcc are static.** Several devices ship a libstdc++ older than this
  toolchain's. glibc stays dynamic — it is the floor being matched, not something to
  carry.
- **SDL2 comes from the device.** Linked, not bundled: `/usr/trimui/lib` on TrimUI,
  `spruce/flip/lib` on Flip, `App/PyUI/dll-mali` on the Anbernic XX line. Built against
  focal's SDL 2.0.10; every SDL symbol DSperate uses predates that.
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

## Not done here

Wiring DSperate into spruceOS as an `Emu/NDS` emulator option alongside the three DraStic
builds — that is a spruceOS-side change (`config.json` `menuOptions`, a launch case, and
the process lists in `send_menu_button_to_retroarch`, `kill_ra_and_standard_emulators`
and `EMU_PROCESSES`).
