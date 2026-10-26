// Shim for the private macOS CGVirtualDisplay API (virtual monitor).
// Classes are looked up at runtime (NSClassFromString): if Apple removes them, the function returns nil instead of crashing the app.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Creates a virtual monitor. The monitor lives as long as the returned object does. nil on failure.
/// vendor/product/serial — the monitor's "identity": macOS remembers its mode and arrangement by it.
id _Nullable TVMCreateVirtualDisplay(NSString *name, unsigned width, unsigned height, double refreshRate,
                                     unsigned vendorID, unsigned productID, unsigned serial,
                                     CGDirectDisplayID *outDisplayID);

NS_ASSUME_NONNULL_END
