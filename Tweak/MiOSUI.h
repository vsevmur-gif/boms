#import <Foundation/Foundation.h>

// The injected, in-Instagram control surface: a draggable floating button that opens the
// container manager (list / create-with-fingerprint+location / switch / delete).
@interface MiOSUI : NSObject
+ (void)install;     // safe to call once from the constructor; attaches when the UI is up
+ (void)present;     // open the manager over Instagram's current screen
@end

// Defined in Tweak.x — delete all keychain items belonging to a container's namespace
// (__mios_<id>_…). Used by the overlay's "clear container" to fully reset saved logins.
void miosWipeContainerKeychain(NSString *containerID);
