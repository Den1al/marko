// Loaded into the driven copy of Marko only (scripts/drive/launch.sh, DYLD_INSERT_LIBRARIES): no
// window of it is put on screen anywhere but the built-in display. A normal launch places its
// windows where AppKit and the saved frames say, which is the display the user works on.
// MEASURED: every way of showing a window (documents, panels, alerts, About, menus) goes through
// orderWindow:relativeTo:, so the observer below never had to move one that was already showing.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSScreen *builtIn(void) {
    for (NSScreen *screen in NSScreen.screens)
        if (CGDisplayIsBuiltin([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue])) return screen;
    return nil;
}

/// Moves the window onto the built-in display if it is not there; NO when it cannot be there.
static BOOL pin(NSWindow *window) {
    NSScreen *screen = builtIn();
    if (!screen) return NO;
    // A sheet, a child and a full-screen window are where their window is.
    if ((window.styleMask & NSWindowStyleMaskFullScreen) || window.parentWindow || window.isSheet)
        return window.screen == nil || window.screen == screen || NSContainsRect(screen.frame, window.frame);
    NSRect visible = screen.visibleFrame, frame = window.frame;
    if (!NSContainsRect(screen.frame, frame)) {
        frame.origin.x = MAX(visible.origin.x, MIN(frame.origin.x, NSMaxX(visible) - frame.size.width));
        frame.origin.y = MIN(NSMaxY(visible) - frame.size.height, MAX(frame.origin.y, visible.origin.y));
        [window setFrameOrigin:frame.origin];
    }
    for (NSScreen *other in NSScreen.screens)
        if (other != screen && NSIntersectsRect(other.frame, window.frame)) return NO;
    return YES;
}

@implementation NSWindow (Pin)
- (void)pin_orderWindow:(NSWindowOrderingMode)mode relativeTo:(NSInteger)other {
    if (mode != NSWindowOut && !pin(self)) {
        fprintf(stderr, "pin: not shown: %s\n", self.title.UTF8String);
        return;
    }
    [self pin_orderWindow:mode relativeTo:other];
}
@end

/// The copy never takes the keyboard by itself. MEASURED: Marko comes to the front for every
/// `marko` call, as it should for the user, and what the user was typing in another app then went
/// into the copy's documents. Only the driver brings it forward (`front`, which does not come
/// through here) and gives the front back (`hide`).
@implementation NSApplication (Pin)
- (void)pin_activateIgnoringOtherApps:(BOOL)flag {
    fprintf(stderr, "pin: activation kept back\n");
}
- (void)pin_activate {
    fprintf(stderr, "pin: activation kept back\n");
}
/// MEASURED: AppKit itself asks for the front when an app is launched (`finishLaunching` for a
/// file named as argument, and at the first Apple event) and whenever the two above are called,
/// each time through this method of its own; of two launches of the copy one was given the front
/// that way, for the 8 s it took to hide it.
- (void)pin_activateWithInfo:(id)info {
    fprintf(stderr, "pin: activation kept back\n");
}
@end

__attribute__((constructor)) static void install(void) {
    // Without AppKit's method there is nothing to keep the launch back with, and launch.sh ends the app.
    Method own = class_getInstanceMethod(NSApplication.class, NSSelectorFromString(@"_activateWithInfo:"));
    if (!own) return;
    method_exchangeImplementations(own, class_getInstanceMethod(NSApplication.class, @selector(pin_activateWithInfo:)));
    method_exchangeImplementations(class_getInstanceMethod(NSApplication.class, @selector(activateIgnoringOtherApps:)),
                                   class_getInstanceMethod(NSApplication.class, @selector(pin_activateIgnoringOtherApps:)));
    method_exchangeImplementations(class_getInstanceMethod(NSApplication.class, @selector(activate)),
                                   class_getInstanceMethod(NSApplication.class, @selector(pin_activate)));
    method_exchangeImplementations(class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)),
                                   class_getInstanceMethod(NSWindow.class, @selector(pin_orderWindow:relativeTo:)));
    // A window that is moved or resized while it shows.
    for (NSNotificationName name in @[NSWindowDidUpdateNotification, NSWindowDidMoveNotification, NSWindowDidChangeScreenNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSWindow *window = note.object;
            if (window.isVisible && !pin(window)) {
                fprintf(stderr, "pin: hidden: %s\n", window.title.UTF8String);
                [window pin_orderWindow:NSWindowOut relativeTo:0];
            }
        }];
    // launch.sh waits for this line before it lets the app go on: without it nothing is pinned.
    fprintf(stderr, "pin: installed\n");
}
