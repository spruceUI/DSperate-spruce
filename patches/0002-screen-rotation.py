#!/usr/bin/env python3
"""Add DS_ROTATE: rotate the whole presented image for rotated panels.

The Miyoo A30's panel is mounted at 270 degrees - spruce's own PyUI reports
screen_rotation() == 270 for it, and vTree has to pass --rotate=3 there.
DSperate has no rotation of any kind, so on that device everything renders
sideways. Same problem on any handheld whose panel is fitted portrait.

Approach: the layout keeps working in an unrotated "logical" viewport, and only
the final present rotates.

  out_size() reports the logical size (w/h swapped for 90/270). It is the one
  place layout(), build_scale() and map_point() all read their dimensions from,
  so swapping it there rotates the entire geometry with no other changes.

  draw() renders the views into a logical-sized render target, then blits that
  into the window with SDL_RenderCopyEx. Rotating a WxH rect about its own
  centre gives an HxW footprint, so a logical-sized dst rect centred in the
  window lands exactly on the panel. On a Mali that blit is free; the software
  renderer supports target textures too, so both paths work.

Off unless DS_ROTATE is set, and the accepted values are 0/90/180/270. With it
unset every code path is what it was before, so this is inert on the aarch64
build.

Two deliberate limits, neither reachable on the devices this is for:
  - Per-scanline scaling is disabled when rotating. It writes straight into the
    window surface with no renderer in play, so there is nothing to rotate with.
    It is off by default outside Wayland anyway, which is where rotated panels
    are.
  - SDL_FINGER* coordinates are normalised to the window, and input.cpp scales
    them by output_size(), which is now logical - so touch is wrong under
    rotation. The mouse path goes through map_point() and is correct. The A30
    and the Mini have neither a touchscreen nor a mouse; fixing it properly
    means changing input.cpp, which is left for whoever has a rotated
    touchscreen device to test on.
"""
import pathlib
import sys

CPP = pathlib.Path("src/frontend/sdl/display.cpp")
HDR = pathlib.Path("src/frontend/sdl/display.h")


def edit(text, anchor, replacement, what):
    if anchor not in text:
        raise SystemExit(f"rotation patch: could not find {what}")
    return text.replace(anchor, replacement, 1)


def main() -> int:
    hdr = HDR.read_text()
    cpp = CPP.read_text()
    if "rot_" in hdr:
        print("display: rotation already patched in")
        return 0

    # ---- header: state and the render target ----
    hdr = edit(
        hdr,
        "  void layout();\n",
        "  void layout();\n"
        "  void ensure_rt();            // (re)create the logical-size render target\n"
        "  void unrotate(int& x, int& y) const;  // panel point -> logical point\n",
        "Display::layout declaration",
    )
    hdr = edit(
        hdr,
        "  SDL_Window*   win_ = nullptr;\n",
        "  // DS_ROTATE: 0 (off), 90, 180 or 270 degrees clockwise applied at present.\n"
        "  int           rot_ = 0;\n"
        "  SDL_Texture*  rt_ = nullptr;   // logical-size render target; only when rot_\n"
        "  SDL_Window*   win_ = nullptr;\n",
        "Display member block",
    )

    # ---- open(): read the env var, size the window in panel space ----
    cpp = edit(
        cpp,
        "  int w = 0, h = 0;\n"
        "  if (only_screen_ >= 0) { w = static_cast<int>(SCREEN_W) * scale; h = static_cast<int>(SCREEN_H) * scale; }\n"
        "  else natural_size(layout_, scale, w, h);\n",
        "  if (const char* r = std::getenv(\"DS_ROTATE\")) {\n"
        "    const int deg = std::atoi(r);\n"
        "    if (deg == 90 || deg == 180 || deg == 270) rot_ = deg;\n"
        "    else if (deg != 0) std::fprintf(stderr, \"DS_ROTATE=%s ignored; use 0, 90, 180 or 270\\n\", r);\n"
        "  }\n"
        "  int w = 0, h = 0;\n"
        "  if (only_screen_ >= 0) { w = static_cast<int>(SCREEN_W) * scale; h = static_cast<int>(SCREEN_H) * scale; }\n"
        "  else natural_size(layout_, scale, w, h);\n"
        "  // The layout is computed in logical space, so a windowed window has to be\n"
        "  // created the other way round. Fullscreen on a handheld ignores this.\n"
        "  if (rot_ == 90 || rot_ == 270) std::swap(w, h);\n",
        "open() window sizing",
    )

    # ---- open(): the scanline path cannot rotate ----
    cpp = edit(
        cpp,
        "  if (scaled_) {\n"
        "    if (accel) std::fprintf(stderr, \"DS_SCANLINE_SCALE renders on the CPU; --accel ignored\\n\");\n",
        "  if (scaled_ && rot_) {\n"
        "    // It writes into the window surface with no renderer in play, so there is\n"
        "    // nothing to rotate with. Say so rather than silently drawing sideways.\n"
        "    std::fprintf(stderr, \"DS_ROTATE=%d: scanline scaling cannot rotate; using the renderer\\n\", rot_);\n"
        "    scaled_ = false;\n"
        "  }\n"
        "  if (scaled_) {\n"
        "    if (accel) std::fprintf(stderr, \"DS_SCANLINE_SCALE renders on the CPU; --accel ignored\\n\");\n",
        "open() scaled_ decision",
    )

    # ---- close(): drop the render target ----
    cpp = edit(
        cpp,
        "  for (auto*& t : tex_) { if (t) SDL_DestroyTexture(t); t = nullptr; }\n",
        "  if (rt_) { SDL_DestroyTexture(rt_); rt_ = nullptr; }\n"
        "  for (auto*& t : tex_) { if (t) SDL_DestroyTexture(t); t = nullptr; }\n",
        "close() texture teardown",
    )

    # ---- layout(): keep the render target the size of the logical viewport ----
    cpp = edit(
        cpp,
        "void Display::layout() {\n",
        "// The render target is the logical viewport; every path that can change the\n"
        "// window size calls layout(), so this is the one place it needs rebuilding.\n"
        "void Display::ensure_rt() {\n"
        "  if (!rot_ || !ren_) return;\n"
        "  int w = 0, h = 0;\n"
        "  if (!out_size(w, h) || w <= 0 || h <= 0) return;\n"
        "  if (rt_) {\n"
        "    int cw = 0, ch = 0;\n"
        "    if (SDL_QueryTexture(rt_, nullptr, nullptr, &cw, &ch) == 0 && cw == w && ch == h) return;\n"
        "    SDL_DestroyTexture(rt_);\n"
        "    rt_ = nullptr;\n"
        "  }\n"
        "  rt_ = SDL_CreateTexture(ren_, SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_TARGET, w, h);\n"
        "  if (!rt_) {\n"
        "    std::fprintf(stderr, \"DS_ROTATE: render target unavailable (%s); not rotating\\n\", SDL_GetError());\n"
        "    rot_ = 0;\n"
        "  }\n"
        "}\n"
        "\n"
        "// Inverse of the present rotation: a point in panel pixels -> logical pixels.\n"
        "void Display::unrotate(int& x, int& y) const {\n"
        "  if (!rot_) return;\n"
        "  int lw = 0, lh = 0;\n"
        "  if (!out_size(lw, lh)) return;      // already the logical size\n"
        "  const int px = x, py = y;\n"
        "  switch (rot_) {\n"
        "    case 90:  x = py;          y = lh - 1 - px; break;\n"
        "    case 180: x = lw - 1 - px; y = lh - 1 - py; break;\n"
        "    case 270: x = lw - 1 - py; y = px;          break;\n"
        "    default: break;\n"
        "  }\n"
        "}\n"
        "\n"
        "void Display::layout() {\n"
        "  ensure_rt();\n",
        "layout() definition",
    )

    # ---- draw(): render into the target, then blit it rotated ----
    cpp = edit(
        cpp,
        "void Display::draw(const u32* const fb[SCREENS]) {\n"
        "  SDL_SetRenderDrawColor(ren_, 0, 0, 0, 255);\n"
        "  SDL_RenderClear(ren_);\n",
        "void Display::draw(const u32* const fb[SCREENS]) {\n"
        "  const bool rotating = rot_ && rt_ && SDL_SetRenderTarget(ren_, rt_) == 0;\n"
        "  SDL_SetRenderDrawColor(ren_, 0, 0, 0, 255);\n"
        "  SDL_RenderClear(ren_);\n",
        "draw() prologue",
    )
    cpp = edit(
        cpp,
        "    SDL_RenderCopy(ren_, tex_[v.screen], nullptr, &v.rect);\n"
        "  }\n"
        "  SDL_RenderPresent(ren_);\n"
        "}\n",
        "    SDL_RenderCopy(ren_, tex_[v.screen], nullptr, &v.rect);\n"
        "  }\n"
        "  if (rotating) {\n"
        "    SDL_SetRenderTarget(ren_, nullptr);\n"
        "    SDL_SetRenderDrawColor(ren_, 0, 0, 0, 255);\n"
        "    SDL_RenderClear(ren_);\n"
        "    int lw = 0, lh = 0;\n"
        "    SDL_QueryTexture(rt_, nullptr, nullptr, &lw, &lh);\n"
        "    int pw = 0, ph = 0;\n"
        "    SDL_GetRendererOutputSize(ren_, &pw, &ph);\n"
        "    // Centre the logical rect on the panel. RenderCopyEx turns it about its\n"
        "    // own centre, so a WxH rect centred here covers an HxW panel exactly.\n"
        "    const SDL_Rect dst = { (pw - lw) / 2, (ph - lh) / 2, lw, lh };\n"
        "    SDL_RenderCopyEx(ren_, rt_, nullptr, &dst, static_cast<double>(rot_), nullptr, SDL_FLIP_NONE);\n"
        "  }\n"
        "  SDL_RenderPresent(ren_);\n"
        "}\n",
        "draw() epilogue",
    )

    # ---- map_point(): input arrives in panel pixels ----
    cpp = edit(
        cpp,
        "bool Display::map_point(int wx, int wy, int& screen, int& sx, int& sy) const {\n",
        "bool Display::map_point(int wx, int wy, int& screen, int& sx, int& sy) const {\n"
        "  unrotate(wx, wy);   // the views are in logical space; the event is not\n",
        "map_point() prologue",
    )

    # ---- out_size(): the single choke point the geometry reads ----
    cpp = edit(
        cpp,
        "bool Display::out_size(int& w, int& h) const {\n",
        "// Reports the LOGICAL viewport under DS_ROTATE: layout(), build_scale() and\n"
        "// map_point() all size themselves from here, so swapping here rotates the\n"
        "// whole geometry and nothing else has to know.\n"
        "bool Display::out_size(int& w, int& h) const {\n"
        "  struct Swap {\n"
        "    const int rot; int& w; int& h;\n"
        "    ~Swap() { if (rot == 90 || rot == 270) std::swap(w, h); }\n"
        "  } swap_on_return{rot_, w, h};\n",
        "out_size() definition",
    )

    # <algorithm> for std::swap is already pulled in by display.cpp's includes;
    # <cstdlib> for atoi/getenv may not be.
    if "#include <cstdlib>" not in cpp:
        cpp = edit(cpp, "#include <cstdio>", "#include <cstdio>\n#include <cstdlib>", "include block")

    HDR.write_text(hdr)
    CPP.write_text(cpp)
    print("display: DS_ROTATE support added (0/90/180/270, off by default)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
