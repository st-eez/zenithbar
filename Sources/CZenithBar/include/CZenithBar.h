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
CFArrayRef zenithbar_window_spaces(uint32_t window);

#include <mach/mach.h>

/// A receive right registered under `name` with the bootstrap server, as SketchyBar registers
/// its own, or MACH_PORT_NULL when registering fails.
mach_port_t zenithbar_mach_register(const char *name);
/// The payload of the next message on `port`, one out of line descriptor as Kosmos sends it,
/// in a buffer the caller frees, or NULL with `length` 0 when none waits or it has another shape.
char *zenithbar_mach_receive(mach_port_t port, uint32_t *length);
