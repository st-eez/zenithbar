#pragma once
#include <CoreGraphics/CoreGraphics.h>

typedef int SLSConnectionID;

extern SLSConnectionID SLSMainConnectionID(void);
// The Spaces holding each window; selector 7 asks for every Space, as Kosmos reads them.
extern CFArrayRef SLSCopySpacesForWindows(SLSConnectionID cid, int selector, CFArrayRef windows);
extern uint64_t SLSGetActiveSpace(SLSConnectionID cid);
// The blur WindowServer draws behind a window, as SketchyBar's blur_radius sets it.
extern CGError SLSSetWindowBackgroundBlurRadius(SLSConnectionID cid, uint32_t window, uint32_t radius);

/// The Spaces holding `window`, as an array of numbers.
CFArrayRef zenith_window_spaces(uint32_t window);
