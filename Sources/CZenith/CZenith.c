#include "CZenith.h"

CFArrayRef zenith_window_spaces(uint32_t window) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window);
    CFArrayRef windows = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = SLSCopySpacesForWindows(SLSMainConnectionID(), 7, windows);
    CFRelease(windows);
    CFRelease(number);
    return spaces;
}
