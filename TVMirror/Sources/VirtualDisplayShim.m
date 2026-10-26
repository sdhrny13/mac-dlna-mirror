#import "VirtualDisplayShim.h"
#import <objc/message.h>

id TVMCreateVirtualDisplay(NSString *name, unsigned width, unsigned height, double refreshRate,
                           unsigned vendorID, unsigned productID, unsigned serial,
                           CGDirectDisplayID *outDisplayID) {
    Class D = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class V = NSClassFromString(@"CGVirtualDisplay");
    Class S = NSClassFromString(@"CGVirtualDisplaySettings");
    Class M = NSClassFromString(@"CGVirtualDisplayMode");
    if (!D || !V || !S || !M) return nil;

    id desc = [[D alloc] init];
    // a dedicated serial queue, as in proven implementations (go-macos/virtualdisplay)
    ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setQueue:"),
                                          dispatch_queue_create("tvmirror.virtualdisplay", DISPATCH_QUEUE_SERIAL));
    ((void (*)(id, SEL, id))objc_msgSend)(desc, NSSelectorFromString(@"setName:"), name);
    ((void (*)(id, SEL, unsigned))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsWide:"), width);
    ((void (*)(id, SEL, unsigned))objc_msgSend)(desc, NSSelectorFromString(@"setMaxPixelsHigh:"), height);
    // physical size — from the resolution at 96 dpi
    CGSize mm = CGSizeMake(width * 25.4 / 96.0, height * 25.4 / 96.0);
    ((void (*)(id, SEL, CGSize))objc_msgSend)(desc, NSSelectorFromString(@"setSizeInMillimeters:"), mm);
    ((void (*)(id, SEL, unsigned))objc_msgSend)(desc, NSSelectorFromString(@"setVendorID:"), vendorID);
    ((void (*)(id, SEL, unsigned))objc_msgSend)(desc, NSSelectorFromString(@"setProductID:"), productID);
    ((void (*)(id, SEL, unsigned))objc_msgSend)(desc, NSSelectorFromString(@"setSerialNum:"), serial);

    id display = ((id (*)(id, SEL, id))objc_msgSend)([V alloc], NSSelectorFromString(@"initWithDescriptor:"), desc);
    if (!display) return nil;

    id mode = ((id (*)(id, SEL, NSUInteger, NSUInteger, double))objc_msgSend)(
        [M alloc], NSSelectorFromString(@"initWithWidth:height:refreshRate:"), width, height, refreshRate);
    id settings = [[S alloc] init];
    ((void (*)(id, SEL, unsigned))objc_msgSend)(settings, NSSelectorFromString(@"setHiDPI:"), 0);
    ((void (*)(id, SEL, id))objc_msgSend)(settings, NSSelectorFromString(@"setModes:"), @[ mode ]);
    BOOL ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(@"applySettings:"), settings);
    if (!ok) return nil;

    if (outDisplayID) *outDisplayID = ((CGDirectDisplayID (*)(id, SEL))objc_msgSend)(display, NSSelectorFromString(@"displayID"));
    return display;
}
