#include "CZenithBar.h"

CFArrayRef zenithbar_window_spaces(uint32_t window) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &window);
    CFArrayRef windows = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFArrayRef spaces = SLSCopySpacesForWindows(SLSMainConnectionID(), 7, windows);
    CFRelease(windows);
    CFRelease(number);
    return spaces;
}

#include <servers/bootstrap.h>
#include <stdlib.h>
#include <string.h>

mach_port_t zenithbar_mach_register(const char *name) {
    mach_port_t bootstrap, port = MACH_PORT_NULL;
    if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bootstrap) != KERN_SUCCESS) return MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) goto fail;
    if (mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) goto fail;
    // Room for the snapshots Kosmos sends while a socket request holds the queue that drains
    // the port; Kosmos's zero timeout send fails on a full port, and the default holds 5.
    mach_port_limits_t limits = {.mpl_qlimit = MACH_PORT_QLIMIT_LARGE};
    mach_port_set_attributes(mach_task_self(), port, MACH_PORT_LIMITS_INFO, (mach_port_info_t)&limits,
                             MACH_PORT_LIMITS_INFO_COUNT);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Deprecated, but it needs no launchd plist, and SketchyBar registers the same way on macOS 27.
    if (bootstrap_register(bootstrap, (char *)name, port) != KERN_SUCCESS) goto fail;
#pragma clang diagnostic pop
    mach_port_deallocate(mach_task_self(), bootstrap);
    return port;
fail:
    if (port != MACH_PORT_NULL) mach_port_mod_refs(mach_task_self(), port, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), bootstrap);
    return MACH_PORT_NULL;
}

typedef struct {
    mach_msg_header_t header;
    mach_msg_size_t count;
    mach_msg_ool_descriptor_t payload;
    mach_msg_trailer_t trailer;
} zenithbar_message;

char *zenithbar_mach_receive(mach_port_t port, uint32_t *length) {
    zenithbar_message message = {0};
    *length = 0;
    if (mach_msg(&message.header, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, sizeof message, port, 0, MACH_PORT_NULL)
        != KERN_SUCCESS) return NULL;
    char *copy = NULL;
    if ((message.header.msgh_bits & MACH_MSGH_BITS_COMPLEX) && message.count == 1
        && message.payload.type == MACH_MSG_OOL_DESCRIPTOR && message.payload.address) {
        copy = malloc(message.payload.size);
        if (copy) {
            memcpy(copy, message.payload.address, message.payload.size);
            *length = message.payload.size;
        }
    }
    mach_msg_destroy(&message.header);
    return copy;
}

#include <ApplicationServices/ApplicationServices.h>

// The second argument receives one byte of the reply, as Kosmos's KosmosBridge.m reads it.
extern CGError SLPSGetKeyFocusProcess(ProcessSerialNumber *psn, uint8_t *unknown);
extern CGError _SLPSGetFrontProcess(ProcessSerialNumber *psn);

static pid_t pidOf(ProcessSerialNumber *psn) {
    pid_t pid = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // the pid of a PSN
    return GetProcessPID(psn, &pid) == noErr ? pid : 0;
#pragma clang diagnostic pop
}

pid_t zenithbar_key_focus_pid(void) {
    ProcessSerialNumber psn = {0};
    uint8_t unknown = 0;
    return SLPSGetKeyFocusProcess(&psn, &unknown) == kCGErrorSuccess ? pidOf(&psn) : 0;
}

pid_t zenithbar_front_pid(void) {
    ProcessSerialNumber psn = {0};
    return _SLPSGetFrontProcess(&psn) == kCGErrorSuccess ? pidOf(&psn) : 0;
}
