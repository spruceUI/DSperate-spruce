#!/usr/bin/env python3
"""Compile DSperate against an SDL2 that was built without wayland.

display_wl.cpp reads wm.info.wl unconditionally, but SDL_syswm.h only declares
that union member when SDL itself was built with SDL_VIDEO_DRIVER_WAYLAND. Every
embedded SDL2 spruce runs on a 32-bit device is a Mali fbdev build with no
wayland at all (the A30's has zero wayland strings in it), so the file will not
compile there.

DmabufOut::open already reports failure by returning false, and every caller
treats that as "no dmabuf, use the normal blit" - so the no-wayland build simply
takes the path it would have taken at runtime anyway.

No-op wherever SDL does have wayland: the original body is kept under #else.
"""
import pathlib
import sys

SRC = pathlib.Path("src/frontend/sdl/display_wl.cpp")
SIG = "bool DmabufOut::open(SDL_Window* win, int w, int h, int output_index) {"

GUARD = """
#ifndef SDL_VIDEO_DRIVER_WAYLAND
  // This SDL2 was built without wayland, so SDL_SysWMinfo carries no wl member
  // and there is no compositor to hand buffers to. Same answer the runtime
  // check below would give on such a device, just reached at compile time.
  (void)win; (void)w; (void)h; (void)output_index;
  std::fprintf(stderr, "dmabuf: SDL2 built without wayland support\\n");
  return false;
#else"""

def main() -> int:
    text = SRC.read_text()
    if "SDL_VIDEO_DRIVER_WAYLAND" in text:
        print("display_wl.cpp already guarded; nothing to do")
        return 0
    start = text.index(SIG)
    brace = text.index("{", start + len(SIG) - 1)

    # Walk to the brace that closes the function so #endif lands in the right
    # place even if the body moves around upstream.
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                end = i
                break
    else:
        raise SystemExit("display_wl.cpp: unbalanced braces in DmabufOut::open")

    patched = text[: brace + 1] + GUARD + text[brace + 1 : end] + "#endif\n" + text[end:]
    SRC.write_text(patched)
    print("display_wl.cpp: DmabufOut::open guarded for SDL2 without wayland")
    return 0

if __name__ == "__main__":
    sys.exit(main())
