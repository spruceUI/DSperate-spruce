# patches

Applied to every target before configure — `*.patch` via `git apply`, `*.py` via `python3`.
A patch that no longer applies is fatal, so the build cannot ship a binary with a feature
silently missing (see `build.sh`).

**The directory is empty on purpose.** Upstream took both patches into 1.6.0:

- `0001-dmabuf-guard-no-wayland.py` — guarded `DmabufOut::open` so `display_wl.cpp` would
  compile against an SDL2 built without wayland, which every embedded spruce SDL2 is.
  1.6.0 makes the same decision at configure time (`DSPERATE_WAYLAND` plus a
  `check_cxx_source_compiles` probe on `SDL_SysWMinfo`'s `wl` member) and swaps in
  `display_wl_stub.cpp`, so the file is no longer compiled. We pass
  `-DDSPERATE_WAYLAND=OFF` outright rather than lean on the probe: our build-time SDL2 has
  wayland even though no device we ship to does.

- `0002-screen-rotation.py` — added `DS_ROTATE=0|90|180|270` on the SDL renderer path.
  1.6.0 has `DS_ROTATE` natively, on the display-engine scaler tier
  (`display_disp.cpp`) it added for the A30 class: NEON rotate kernels, `/dev/disp`
  auto-detected, `DispOut::open(rot, vsync)`. Keeping ours on top was worse than dropping
  it — its `out_size()` return-swap fires on `disp_->logical_w/h`, which `DispOut` already
  reports rotated, so the two rotations cancel into a double swap.

  The A30 is the only platform that sets `DS_ROTATE`
  (`spruce/scripts/emu/lib/dsperate_functions.sh`), and upstream's tier is auto wherever
  `/dev/disp` and `/dev/fb0` answer. The emu log says which tier opened:
  `video: display-engine scaler, rot 270, ...`. If that line is ever missing, rotation is
  gone — the SDL renderer fallback has none of its own upstream.
