/* The three Xlib names `vulkan_xlib.h` needs, declared opaquely.
 *
 * The Vulkan backend receives an X11 display pointer and a pointer-width window ID from
 * `platform` and hands both straight to `vkCreateXlibSurfaceKHR`; it never dereferences
 * either. Declaring them here means a Linux build, native or cross-compiled, needs no system
 * X11 headers (docs/design/vulkan.md §3). `Display` stays an incomplete type, and `Window` and
 * `VisualID` are X11's `unsigned long` XIDs.
 */
#ifndef FOUNDRY_XLIB_OPAQUE_H
#define FOUNDRY_XLIB_OPAQUE_H

typedef struct _XDisplay Display;
typedef unsigned long Window;
typedef unsigned long VisualID;

#endif
