#!/usr/bin/env python3
# Pause-menu palette: spruce's IGM colours (RA patches/common/0001-spruce-igm.patch),
# alphas pre-blended over black because this menu writes solid pixels.
import sys
p = "src/frontend/sdl/menu.cpp"
s = open(p).read()
old = ("constexpr u32 kInk = 0xFFFFFFFF, kDim = 0xFF909090, kPanel = 0xFF101018, kEdge = 0xFF5060A0, kSel = 0xFF3050A0;\n"
       "constexpr u32 kEdgeText = 0xFFA0B0E0, kPanelEdgeDim = 0xFF303040;")
new = ("constexpr u32 kInk = 0xFFD5C4A1, kDim = 0xFF8C8172, kPanel = 0xFF121212, kEdge = 0xFFAB8A21, kSel = 0xFF382D0B;\n"
       "constexpr u32 kEdgeText = 0xFF689D6A, kPanelEdgeDim = 0xFF665C54;")
if s.count(old) != 1:
    sys.exit(f"{p}: palette line not found; upstream moved it")
open(p, "w").write(s.replace(old, new))
print("menu.cpp: spruce palette applied")
