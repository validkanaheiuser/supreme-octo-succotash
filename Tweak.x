/*
 * TouchGeoFix — companion dylib for iOSAutomate
 *
 * Problem: iOSAutomate injects HID touch events with majorRadius=0 and a flat
 * force curve, which PerimeterX PXTouchManager flags as synthetic.
 *
 * Fix: hook IOHIDEventSystemClientDispatchEvent (final dispatch point before
 * the kernel receives the event) and stamp realistic ellipse/pressure values
 * on any digitizer event that is missing a contact radius.
 *
 * Injected into: SpringBoard, Preferences, Facebook (same filter as iOSAutomate)
 * Real user touches always have majorRadius > 1 — they are NOT modified.
 */

#import <substrate.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>

// ─── IOHIDEvent opaque types ───────────────────────────────────────────────

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDEventField;
typedef uint32_t IOHIDEventOptionBits;
typedef mach_port_t io_service_t;

// ─── IOHIDEvent function pointers (resolved at runtime) ───────────────────

typedef IOHIDEventType (*fn_GetType)(IOHIDEventRef);
typedef double         (*fn_GetFloat)(IOHIDEventRef, IOHIDEventField);
typedef void           (*fn_SetFloat)(IOHIDEventRef, IOHIDEventField, double, IOHIDEventOptionBits);
typedef kern_return_t  (*fn_Dispatch)(io_service_t, IOHIDEventRef);

static fn_GetType   _getType   = NULL;
static fn_GetFloat  _getFloat  = NULL;
static fn_SetFloat  _setFloat  = NULL;
static fn_Dispatch  _origDisp  = NULL;

// ─── Field constants ────────────────────────────────────────────────────────
// IOHIDEventField = (kIOHIDEventType << 16) | fieldIndex
// kIOHIDEventTypeDigitizer = 11 (0x0B) — consistent across iOS 13–17
// Field indices from reversed IOHIDEventTypes.h:
//   MajorRadius = 3, MinorRadius = 4, Pressure = 11
//
// Some iOS versions use type 13 (0x0D) for the digitizer subtype; we try both.

#define _BASE(t)            ((IOHIDEventField)((t) << 16))
#define _F(t, idx)          (_BASE(t) | (idx))

#define kHIDTypeDigitizer   11u   // kIOHIDEventTypeDigitizer
#define kHIDTypeDigitizer2  13u   // alternate base seen in iOS 15+ traces

// Primary set (type 11)
#define kFldMajorR      _F(kHIDTypeDigitizer, 3)
#define kFldMinorR      _F(kHIDTypeDigitizer, 4)
#define kFldPressure    _F(kHIDTypeDigitizer, 11)

// Alternate set (type 13)
#define kFldMajorR2     _F(kHIDTypeDigitizer2, 3)
#define kFldMinorR2     _F(kHIDTypeDigitizer2, 4)
#define kFldPressure2   _F(kHIDTypeDigitizer2, 11)

// ─── Helpers ────────────────────────────────────────────────────────────────

static inline float randRange(float lo, float hi) {
    return lo + ((float)(arc4random() % 10000u) / 10000.0f) * (hi - lo);
}

static void stampTouchGeometry(IOHIDEventRef event) {
    if (!_getType || !_getFloat || !_setFloat) return;
    if (_getType(event) != kHIDTypeDigitizer)  return;

    // Check both field bases; real finger contact is always > 1 pt radius
    double major = _getFloat(event, kFldMajorR);
    if (major < 1.0) major = _getFloat(event, kFldMajorR2);
    if (major >= 1.0) return; // real touch — leave untouched

    // Synthetic touch detected: apply realistic finger contact geometry
    float r     = randRange(12.5f, 18.0f);          // typical finger contact: 12–18 pt
    float rMinor = r * randRange(0.80f, 0.94f);      // slightly elliptical
    float press  = randRange(0.40f, 0.72f);          // mid-press force

    _setFloat(event, kFldMajorR,   r,      0);
    _setFloat(event, kFldMinorR,   rMinor, 0);
    _setFloat(event, kFldPressure, press,  0);

    // Mirror to alternate field base for version compatibility
    _setFloat(event, kFldMajorR2,   r,      0);
    _setFloat(event, kFldMinorR2,   rMinor, 0);
    _setFloat(event, kFldPressure2, press,  0);
}

// ─── Hook: IOHIDEventSystemClientDispatchEvent ──────────────────────────────
// This C function is the last user-space stop before a HID event reaches the
// kernel. Hooking here is robust regardless of how iOSAutomate created the event.

static kern_return_t hook_Dispatch(io_service_t client, IOHIDEventRef event) {
    if (event) stampTouchGeometry(event);
    return _origDisp(client, event);
}

// ─── Constructor ────────────────────────────────────────────────────────────

%ctor {
    // Prefer the PrivateFrameworks path; fall back to main Frameworks
    void *lib = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!lib)
        lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!lib) return;

    _getType  = (fn_GetType) dlsym(lib, "IOHIDEventGetType");
    _getFloat = (fn_GetFloat)dlsym(lib, "IOHIDEventGetFloatValue");
    _setFloat = (fn_SetFloat)dlsym(lib, "IOHIDEventSetFloatValue");

    void *sym = dlsym(lib, "IOHIDEventSystemClientDispatchEvent");
    if (sym) {
        MSHookFunction(sym, (void *)hook_Dispatch, (void **)&_origDisp);
    }
}
