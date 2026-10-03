#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <errno.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import <libkern/OSByteOrder.h>
#import <execinfo.h>
#import <signal.h>
#import <stdlib.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#import "MiOSContainer.h"
#import "MiOSUI.h"
#import "fishhook.h"

// miOS — Instagram-only, Blaze-parity edition.
// Single dylib injected into com.burbn.instagram. One floating button opens the
// in-sandbox manager with Spoof (fingerprint) / Location / Proxy / Containers / Settings.

static NSString *const kIGBundleID = @"com.burbn.instagram";

// Diagnostics master switch. OFF by default: no signal handlers, no watchdog, no logging —
// so Instagram crashes natively (producing a real .ips) instead of our non-async-signal-safe
// crash handler turning the crash into a hang. Build with MIOS_DIAG=1 to re-enable logging.
#ifndef MIOS_DIAG
#define MIOS_DIAG 0
#endif

// Diagnostic logger (defined with the constructor, forward-declared for the hooks).
static void miosLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void miosStartWatchdog(void);

// MARK: - Private declarations

// DeviceCheck (DCDevice) and App Attest (DCAppAttestService) are intentionally NOT declared or
// hooked anywhere — removed completely to match Blaze, which touches neither.

// Keychain-wrapper classes that Instagram / the Facebook SDK use. On a sideloaded (resigned)
// build they request a hard-coded keychain access group the app isn't entitled to, so SecItem
// fails and login crashes. We hook their -accessGroup to return a valid group (opa334 fix).
@interface FBSDKKeychainStore : NSObject @end
@interface FBKeychainItemController : NSObject @end
@interface UICKeyChainStore : NSObject @end

// Instagram's Cloud ID validation (signup anti-abuse). On a sideloaded/sandboxed build CloudKit
// returns nil, and IGCloudIDValidation does _os_crash (SIGTRAP) on the nil NSString — the exact
// registration crash (see LiveContainer#1156). Returning nil from CKContainer does NOT help: nil
// is precisely what triggers the crash. The fix is to SKIP the validation entirely.
@interface IGCloudIDValidation : NSObject @end

@interface ASIdentifierManager : NSObject
+ (ASIdentifierManager *)sharedManager;
- (NSUUID *)advertisingIdentifier;
- (BOOL)isAdvertisingTrackingEnabled;
@end

@interface CTCarrier : NSObject
- (NSString *)carrierName;
- (NSString *)mobileCountryCode;
- (NSString *)mobileNetworkCode;
- (NSString *)isoCountryCode;
- (BOOL)allowsVOIP;
@end
@interface CTTelephonyNetworkInfo : NSObject
- (NSString *)currentRadioAccessTechnology;
- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology;
@end

@interface CMAccelerometerData : NSObject @end
@interface CMGyroData : NSObject @end
@interface CMMotionManager : NSObject
- (void)startGyroUpdates;
- (void)startGyroUpdatesToQueue:(id)q withHandler:(void (^)(id, NSError *))h;
@end

@interface MFMailComposeViewController : NSObject + (BOOL)canSendMail; @end
@interface MFMessageComposeViewController : NSObject + (BOOL)canSendText; @end

typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef interfaceName);

// MARK: - Shared runtime state (resolved once in the constructor)

static NSDictionary *gSpoof = nil;
static NSString *gContainerUUID = nil;
static NSString *gKcPrefix = nil;

// Cached, allocation-free spoof values
static BOOL      gDeviceSpoofActive = NO;
static char     *gcMachine  = NULL;
static char     *gcModel    = NULL;
static uint64_t  gcMemsize  = 0;
static int       gcCPU      = 0;
static char     *gcKernelVersion = NULL;  // uname.release-style + full kern.version
static CFDictionaryRef gcWifiInfo     = NULL;
static CFStringRef gcMGProductType    = NULL;
static CFStringRef gcMGHWModel        = NULL;
static CFStringRef gcMGDeviceName     = NULL;
static CFStringRef gcMGProductVersion = NULL;
static CFTypeRef (*gRealMGCopyAnswer)(CFStringRef) = NULL;

// Real device values captured BEFORE any hook is installed — used to rewrite outgoing telemetry
// (NSJSONSerialization) so the real model/iOS can't leak into IG's login/device payload even if
// the app read them through a path we don't intercept. Mirrors TinderSpoofer's modifyJSONData:.
static NSString *gRealMachineNS  = nil;   // e.g. iPhone17,1
static NSString *gRealIOSNS      = nil;   // e.g. 18.2
static NSString *gRealFriendlyNS = nil;   // e.g. "iPhone 16 Pro" (marketing name)

// Access helpers
static NSString *spoofStr(NSString *key)   { id v = gSpoof[key]; return [v isKindOfClass:[NSString class]] ? v : @""; }
static BOOL      spoofBool(NSString *key)  { return [gSpoof[key] boolValue]; }
static NSInteger spoofInt(NSString *key)   { return [gSpoof[key] integerValue]; }
static double    spoofDbl(NSString *key)   { return [gSpoof[key] doubleValue]; }

// MARK: - Location

static BOOL locationSpoofEnabled(void) { return spoofBool(@"spoofLocation"); }
static CLLocationCoordinate2D spoofedCoordinate(void) {
    return CLLocationCoordinate2DMake(spoofDbl(@"latitude"), spoofDbl(@"longitude"));
}
static CLLocation *spoofedLocationObject(void) {
    double acc = spoofDbl(@"horizontalAccuracy"); if (acc <= 0) acc = 5.0;
    double alt = spoofDbl(@"altitude");
    double spd = spoofDbl(@"speed"); double crs = spoofDbl(@"course");
    return [[CLLocation alloc] initWithCoordinate:spoofedCoordinate()
                                         altitude:alt horizontalAccuracy:acc verticalAccuracy:acc
                                           course:(crs ?: -1) speed:(spd ?: -1) timestamp:[NSDate date]];
}

// (groups removed — flat hooks + single %init)
%hook CLLocationManager
- (CLLocation *)location {
    if (locationSpoofEnabled()) return spoofedLocationObject();
    return %orig;
}
- (void)startUpdatingLocation {
    %orig;
    if (!locationSpoofEnabled()) return;
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        CLLocationManager *mgr = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [delegate locationManager:mgr didUpdateLocations:@[spoofedLocationObject()]];
        });
    }
}
- (void)requestLocation {
    %orig;
    if (!locationSpoofEnabled()) return;
    id delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        CLLocationManager *mgr = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [delegate locationManager:mgr didUpdateLocations:@[spoofedLocationObject()]];
        });
    }
}
%end
%hook CLLocation
- (CLLocationCoordinate2D)coordinate {
    if (locationSpoofEnabled()) return spoofedCoordinate();
    return %orig;
}
%end
// end LocationHooks

// MARK: - Device fingerprint (UIDevice / NSProcessInfo)

// group DeviceSpoofHooks
%hook UIDevice
- (NSString *)systemVersion {
    // DECISIVE one-shot probe: proves whether ObjC %hook (MSHookMessageEx) fires on this
    // sideload runtime at all. If this line never appears in Console, Substrate's ObjC hooking
    // is a no-op here and every %hook (battery/locale/carrier/vendorID/...) is dead.
    static dispatch_once_t once; dispatch_once(&once, ^{
        NSLog(@"[miOS-iso] HOOK UIDevice.systemVersion FIRED  enableSpoofSW=%d iosVersion=%@",
              (int)spoofBool(@"enableSpoofSoftwareVersion"), spoofStr(@"iosVersion"));
    });
    if (spoofBool(@"enableSpoofSoftwareVersion")) {
        NSString *ver = spoofStr(@"iosVersion");
        if (ver.length) return ver;
    }
    return %orig;
}
- (NSString *)name {
    if (spoofBool(@"enableSpoofDeviceName")) {
        NSString *name = spoofStr(@"deviceName");
        if (name.length) return name;
    }
    return %orig;
}
- (NSString *)model {
    if (spoofBool(@"enableSpoofDeviceModel")) {
        NSString *ident = spoofStr(@"deviceIdentifier");
        if ([ident hasPrefix:@"iPad"]) return @"iPad";
        if ([ident hasPrefix:@"iPod"]) return @"iPod touch";
        if ([ident hasPrefix:@"iPhone"]) return @"iPhone";
    }
    return %orig;
}
- (NSString *)localizedModel {   // afhook spoofs this too — generic class string
    if (spoofBool(@"enableSpoofDeviceModel")) {
        NSString *ident = spoofStr(@"deviceIdentifier");
        if ([ident hasPrefix:@"iPad"]) return @"iPad";
        if ([ident hasPrefix:@"iPod"]) return @"iPod touch";
        if ([ident hasPrefix:@"iPhone"]) return @"iPhone";
    }
    return %orig;
}
%end
%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion {
    if (spoofBool(@"enableSpoofSoftwareVersion")) {
        NSString *ver = spoofStr(@"iosVersion");
        if (ver.length) {
            NSArray *parts = [ver componentsSeparatedByString:@"."];
            NSOperatingSystemVersion v = {0, 0, 0};
            if (parts.count > 0) v.majorVersion = [parts[0] integerValue];
            if (parts.count > 1) v.minorVersion = [parts[1] integerValue];
            if (parts.count > 2) v.patchVersion = [parts[2] integerValue];
            return v;
        }
    }
    return %orig;
}
- (NSString *)operatingSystemVersionString {
    if (spoofBool(@"enableSpoofSoftwareVersion")) {
        NSString *ver = spoofStr(@"iosVersion");
        if (ver.length) return [NSString stringWithFormat:@"Version %@", ver];
    }
    return %orig;
}
- (unsigned long long)physicalMemory {
    return gcMemsize ? gcMemsize : %orig;
}
- (NSUInteger)processorCount {
    return gcCPU ? (NSUInteger)gcCPU : %orig;
}
- (NSUInteger)activeProcessorCount {
    return gcCPU ? (NSUInteger)gcCPU : %orig;
}
- (BOOL)isLowPowerModeEnabled {
    if (spoofBool(@"enableSpoofLowPowerMode")) return spoofBool(@"lowPowerModeEnabled");
    return %orig;
}
%end
// end DeviceSpoofHooks

// MARK: - Battery / Brightness / Orientation / Proximity

// group PhysicalHooks
%hook UIDevice
- (float)batteryLevel {
    if (spoofBool(@"enableSpoofBatteryLevel")) {
        NSInteger lvl = spoofInt(@"batteryLevel");
        if (lvl < 0) lvl = 0; if (lvl > 100) lvl = 100;
        return (float)lvl / 100.0f;
    }
    return %orig;
}
- (UIDeviceBatteryState)batteryState {
    if (spoofBool(@"enableSpoofBatteryState")) {
        NSInteger s = spoofInt(@"batteryState");
        if (s >= UIDeviceBatteryStateUnknown && s <= UIDeviceBatteryStateFull) return (UIDeviceBatteryState)s;
    }
    return %orig;
}
- (UIDeviceOrientation)orientation {
    if (spoofBool(@"enableSpoofOrientation")) {
        NSInteger o = spoofInt(@"orientation");
        return (UIDeviceOrientation)o;
    }
    return %orig;
}
- (BOOL)proximityState {
    if (spoofBool(@"enableSpoofProximity")) return spoofBool(@"proximityState");
    return %orig;
}
%end
%hook UIScreen
- (CGFloat)brightness {
    if (spoofBool(@"enableSpoofBrightness")) return (CGFloat)spoofDbl(@"brightnessLevel");
    return %orig;
}
%end
// end PhysicalHooks

// MARK: - Locale / TimeZone

// group LocaleHooks
%hook NSTimeZone
+ (NSTimeZone *)localTimeZone {
    if (spoofBool(@"enableSpoofTimeZone")) {
        NSString *tz = spoofStr(@"timeZoneID");
        NSTimeZone *z = tz.length ? [NSTimeZone timeZoneWithName:tz] : nil;
        if (z) return z;
    }
    return %orig;
}
+ (NSTimeZone *)systemTimeZone {
    if (spoofBool(@"enableSpoofTimeZone")) {
        NSString *tz = spoofStr(@"timeZoneID");
        NSTimeZone *z = tz.length ? [NSTimeZone timeZoneWithName:tz] : nil;
        if (z) return z;
    }
    return %orig;
}
%end
%hook NSLocale
+ (NSLocale *)currentLocale {
    if (spoofBool(@"enableSpoofLocale")) {
        NSString *lid = spoofStr(@"localeID");
        if (lid.length) return [NSLocale localeWithLocaleIdentifier:lid];
    }
    return %orig;
}
+ (NSArray<NSString *> *)preferredLanguages {
    if (spoofBool(@"enableSpoofLocale")) {
        NSString *lid = spoofStr(@"localeID");
        if (lid.length) {
            NSString *lang = [[lid componentsSeparatedByString:@"_"] firstObject];
            if (lang.length) return @[lang];
        }
    }
    return %orig;
}
%end
// end LocaleHooks

// MARK: - Carrier / Cellular type

// group CarrierHooks
%hook CTCarrier
- (NSString *)carrierName {
    if (spoofBool(@"enableSpoofCarrier")) return spoofStr(@"carrierName");
    return %orig;
}
- (NSString *)mobileCountryCode {
    if (spoofBool(@"enableSpoofCarrier")) return spoofStr(@"carrierMCC");
    return %orig;
}
- (NSString *)mobileNetworkCode {
    if (spoofBool(@"enableSpoofCarrier")) return spoofStr(@"carrierMNC");
    return %orig;
}
- (NSString *)isoCountryCode {
    if (spoofBool(@"enableSpoofCarrier")) return spoofStr(@"carrierCountryCode");
    return %orig;
}
%end
%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (spoofBool(@"enableSpoofCellularType")) {
        NSString *t = spoofStr(@"cellularType");
        if ([t isEqualToString:@"3G"]) return @"CTRadioAccessTechnologyWCDMA";
        if ([t isEqualToString:@"4G"]) return @"CTRadioAccessTechnologyLTE";
        if ([t isEqualToString:@"LTE"]) return @"CTRadioAccessTechnologyLTE";
        if ([t isEqualToString:@"5G"]) return @"CTRadioAccessTechnologyNRNSA";
    }
    return %orig;
}
- (NSDictionary<NSString *, NSString *> *)serviceCurrentRadioAccessTechnology {
    if (spoofBool(@"enableSpoofCellularType")) {
        NSString *tech = [self currentRadioAccessTechnology];
        if (tech.length) return @{@"0000000100000001": tech};
    }
    return %orig;
}
%end
// end CarrierHooks

// MARK: - Identifiers (IDFV / IDFA / DeviceCheck / iCloud)

// group IdentifierSpoofHooks
%hook UIDevice
- (NSUUID *)identifierForVendor {
    if (spoofBool(@"enableSpoofVendorID")) {
        NSString *v = spoofStr(@"vendorID");
        NSUUID *u = v.length ? [[NSUUID alloc] initWithUUIDString:v] : nil;
        if (u) return u;
    }
    return %orig;
}
%end
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    if (spoofBool(@"enableSpoofAdvertisingID")) {
        NSString *v = spoofStr(@"advertisingID");
        NSUUID *u = v.length ? [[NSUUID alloc] initWithUUIDString:v] : nil;
        if (u) return u;
    }
    return %orig;
}
- (BOOL)isAdvertisingTrackingEnabled {
    if (spoofBool(@"enableSpoofAdvertisingID")) return NO;
    return %orig;
}
%end
// DeviceCheck & App Attest are NOT hooked at all — removed completely to match Blaze, which
// does not touch either (it doesn't even link DeviceCheck.framework). DCDevice/DCAppAttestService
// run exactly as on a clean build.

// Network diagnostics. Logs every outbound NSURLSession request. During the registration
// spinner the LAST few NET lines show which endpoint the app is hitting and whether it's
// stuck retrying the same request (a retry loop) or waiting on one that never returns.
// This is how we tell a network/server stall from an App Attest / freeze cause.
//
// We log at TASK CREATION on NSURLSession (reliable — NSURLSessionTask is a class cluster
// whose concrete subclasses may override -resume, so hooking the base -resume is unreliable),
// and also at -resume as a best-effort start marker.
static void miosLogReq(NSString *tag, NSURLRequest *req) {
    @try {
        NSString *url = req.URL.absoluteString;
        if (url.length) miosLog(@"NET %@ %@ %@", tag, req.HTTPMethod ?: @"?", url);
    } @catch (__unused id e) {}
}
static NSData *miosRewriteHTTPBody(NSData *body);   // defined after the device-spoof cache
%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    miosLogReq(@"data", request); return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    miosLogReq(@"data+cb", request); return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    miosLogReq(@"upload", request); return %orig(request, miosRewriteHTTPBody(bodyData));
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    miosLogReq(@"upload+cb", request); return %orig(request, miosRewriteHTTPBody(bodyData), h);
}
%end

%hook NSFileManager
- (id)ubiquityIdentityToken {
    if (spoofBool(@"enableSpoofCloudToken")) return nil;
    return %orig;
}
%end
// end IdentifierSpoofHooks

// MARK: - Mail / Message availability

// group MailMessageHooks
%hook MFMailComposeViewController
+ (BOOL)canSendMail {
    if (spoofBool(@"enableSpoofMail")) return spoofBool(@"mailAvailable");
    return %orig;
}
%end
%hook MFMessageComposeViewController
+ (BOOL)canSendText {
    if (spoofBool(@"enableSpoofMessage")) return spoofBool(@"messageAvailable");
    return %orig;
}
%end
// end MailMessageHooks

// MARK: - Screenshot-detection suppression

// group ScreenshotHooks
%hook NSNotificationCenter
- (void)postNotificationName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo {
    if (spoofBool(@"enableSpoofScreenshot") &&
        ([name isEqualToString:UIApplicationUserDidTakeScreenshotNotification] ||
         [name isEqualToString:@"UIScreenCapturedDidChangeNotification"])) return;
    %orig;
}
- (void)postNotificationName:(NSNotificationName)name object:(id)object {
    if (spoofBool(@"enableSpoofScreenshot") &&
        ([name isEqualToString:UIApplicationUserDidTakeScreenshotNotification] ||
         [name isEqualToString:@"UIScreenCapturedDidChangeNotification"])) return;
    %orig;
}
%end
// end ScreenshotHooks

// MARK: - Gyroscope randomization

// group GyroscopeHooks
%hook CMMotionManager
- (id)gyroData {
    id orig = %orig;
    if (spoofBool(@"enableSpoofGyroscope")) {
        struct { double x, y, z; } g = {
            ((double)arc4random() / UINT32_MAX - 0.5) * 4.0,
            ((double)arc4random() / UINT32_MAX - 0.5) * 4.0,
            ((double)arc4random() / UINT32_MAX - 0.5) * 4.0 };
        if (orig) {
            @try { [orig setValue:@(g.x) forKeyPath:@"rotationRate.x"]; } @catch (__unused id e) {}
            @try { [orig setValue:@(g.y) forKeyPath:@"rotationRate.y"]; } @catch (__unused id e) {}
            @try { [orig setValue:@(g.z) forKeyPath:@"rotationRate.z"]; } @catch (__unused id e) {}
        }
    }
    return orig;
}
%end
// end GyroscopeHooks

// MARK: - Anti-detection (hide common jailbreak probes)

static int (*orig_access)(const char *, int) = NULL;
static int (*orig_stat)(const char *, struct stat *) = NULL;
static int (*orig_lstat)(const char *, struct stat *) = NULL;
static FILE *(*orig_fopen)(const char *, const char *) = NULL;

static const char *gJailbreakPaths[] = {
    "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
    "/Library/MobileSubstrate", "/Library/MobileSubstrate/MobileSubstrate.dylib",
    "/usr/lib/libsubstrate.dylib", "/usr/lib/libsubstitute.dylib",
    "/usr/libexec/sftp-server", "/usr/sbin/sshd", "/bin/sh", "/bin/bash",
    "/var/jb", "/var/lib/apt", "/private/var/stash", "/private/var/lib/apt",
    "/etc/apt", "/etc/apt/sources.list.d",
    NULL
};
static BOOL miosIsJbPath(const char *p) {
    if (!p || !spoofBool(@"enableDisableDetection")) return NO;
    for (int i = 0; gJailbreakPaths[i]; i++) {
        if (strncmp(p, gJailbreakPaths[i], strlen(gJailbreakPaths[i])) == 0) return YES;
    }
    return NO;
}
__attribute__((unused)) static int hook_access(const char *p, int m) {
    if (miosIsJbPath(p)) { errno = ENOENT; return -1; }
    return orig_access(p, m);
}
__attribute__((unused)) static int hook_stat(const char *p, struct stat *s) {
    if (miosIsJbPath(p)) { errno = ENOENT; return -1; }
    return orig_stat(p, s);
}
__attribute__((unused)) static int hook_lstat(const char *p, struct stat *s) {
    if (miosIsJbPath(p)) { errno = ENOENT; return -1; }
    return orig_lstat(p, s);
}
__attribute__((unused)) static FILE *hook_fopen(const char *p, const char *m) {
    if (miosIsJbPath(p)) { errno = ENOENT; return NULL; }
    return orig_fopen(p, m);
}

// group DetectionHooks
%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    if (spoofBool(@"enableDisableDetection")) {
        NSString *s = url.scheme.lowercaseString;
        if ([s isEqualToString:@"cydia"] || [s isEqualToString:@"sileo"] || [s isEqualToString:@"zbra"]) return NO;
    }
    return %orig;
}
%end
// end DetectionHooks

// MARK: - Keychain namespacing (per-container isolation inside the app's own access group)

static OSStatus (*orig_SecItemAdd)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *);
static OSStatus (*orig_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef);
static OSStatus (*orig_SecItemDelete)(CFDictionaryRef);

// MARK: - Keychain per-container isolation (Blaze-style: prefix kSecAttrService only)
//
// EXACTLY how Blaze does it (verified by disassembling its modifyAttributesForProfile): every
// SecItem call runs its dictionary through a modifier that prefixes kSecAttrService with the
// per-container id (idempotent — never double-prefixes), then calls the original. Instagram keys
// its keychain items by service, so prefixing the service on both writes and reads scopes each
// container to its own items. No result filtering, no account/server rewriting, no access-group
// changes — matching Blaze exactly.
static NSDictionary *kcModify(CFDictionaryRef dict) {
    NSMutableDictionary *m = dict ? [(__bridge NSDictionary *)dict mutableCopy]
                                  : [NSMutableDictionary dictionary];
    id svc = m[(__bridge id)kSecAttrService];
    if ([svc isKindOfClass:[NSString class]] && ![(NSString *)svc hasPrefix:gKcPrefix])
        m[(__bridge id)kSecAttrService] = [gKcPrefix stringByAppendingString:(NSString *)svc];
    return m;
}
static OSStatus new_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
    if (gKcPrefix.length == 0) return orig_SecItemAdd(a, r);
    return orig_SecItemAdd((__bridge CFDictionaryRef)kcModify(a), r);
}
static OSStatus new_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
    if (gKcPrefix.length == 0) return orig_SecItemCopyMatching(q, r);
    static int gKcQLog = 0;
    if (gKcQLog < 30) { gKcQLog++;
        NSDictionary *qq = (__bridge NSDictionary *)q;
        NSLog(@"[miOS-iso] SecItemCopyMatching ENGAGED service=%@ class=%@ kcPrefix=%@",
              qq[(__bridge id)kSecAttrService], qq[(__bridge id)kSecClass], gKcPrefix); }
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)kcModify(q), r);
}
static OSStatus new_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) {
    if (gKcPrefix.length == 0) return orig_SecItemUpdate(q, u);
    return orig_SecItemUpdate((__bridge CFDictionaryRef)kcModify(q), u);
}
static OSStatus new_SecItemDelete(CFDictionaryRef q) {
    if (gKcPrefix.length == 0) return orig_SecItemDelete(q);
    return orig_SecItemDelete((__bridge CFDictionaryRef)kcModify(q));
}
static void miosInitKeychainNamespace(void) {
    // fishhook (not MSHookFunction) so keychain isolation works on a sideloaded build without a
    // jailbreak/Substrate — this is exactly how Blaze intercepts SecItem* ([FISHHOOK] in its binary).
    rebind_symbols((struct rebinding[]){
        {"SecItemAdd",          (void *)new_SecItemAdd,          (void **)&orig_SecItemAdd},
        {"SecItemCopyMatching", (void *)new_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching},
        {"SecItemUpdate",       (void *)new_SecItemUpdate,       (void **)&orig_SecItemUpdate},
        {"SecItemDelete",       (void *)new_SecItemDelete,       (void **)&orig_SecItemDelete},
    }, 4);
}

// Delete every keychain item belonging to a container's namespace (service/account/server
// prefixed with __mios_<id>_). Uses the ORIGINAL SecItem functions so the prefixed items are
// seen and removed raw (our hooks would re-prefix). Non-static: called from the overlay (UI)
// to fully reset a container's saved logins/tokens. No-op if the keychain hooks aren't active.
void miosWipeContainerKeychain(NSString *containerID) {
    if (containerID.length == 0 || !orig_SecItemCopyMatching || !orig_SecItemDelete) return;
    NSString *prefix = [NSString stringWithFormat:@"__mios_%@_", containerID];
    // Cover every keychain class. Instagram's "remember me across reinstall" lives under
    // GenericPassword services like cloud_persistent_accounts.growth / reinstalls /
    // device_based_login.growth, but keys/certs/identities may be namespaced too.
    NSArray *classes = @[(__bridge id)kSecClassGenericPassword,
                         (__bridge id)kSecClassInternetPassword,
                         (__bridge id)kSecClassKey,
                         (__bridge id)kSecClassCertificate,
                         (__bridge id)kSecClassIdentity];
    for (id cls in classes) {
        // CRITICAL: kSecAttrSynchronizableAny — the "cloud_persistent_accounts" items are
        // iCloud-synchronizable; without this the query matches only LOCAL items and the
        // synced account list survives (exactly the "old accounts after reinstall" symptom).
        NSDictionary *q = @{ (__bridge id)kSecClass:             cls,
                             (__bridge id)kSecMatchLimit:        (__bridge id)kSecMatchLimitAll,
                             (__bridge id)kSecReturnAttributes:  @YES,
                             (__bridge id)kSecReturnPersistentRef:@YES,
                             (__bridge id)kSecAttrSynchronizable:(__bridge id)kSecAttrSynchronizableAny };
        CFTypeRef res = NULL;
        if (orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, &res) != errSecSuccess || !res) {
            if (res) CFRelease(res);
            continue;
        }
        NSArray *items = (__bridge_transfer NSArray *)res;
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            NSString *svc  = it[(__bridge id)kSecAttrService];
            NSString *acct = it[(__bridge id)kSecAttrAccount];
            NSString *srv  = it[(__bridge id)kSecAttrServer];
            BOOL match = ([svc  isKindOfClass:[NSString class]] && [svc  hasPrefix:prefix]) ||
                         ([acct isKindOfClass:[NSString class]] && [acct hasPrefix:prefix]) ||
                         ([srv  isKindOfClass:[NSString class]] && [srv  hasPrefix:prefix]);
            if (!match) continue;
            // Delete by persistent ref — uniquely identifies the exact item (incl. synced ones),
            // which is far more reliable than re-matching by attributes.
            id pref = it[(__bridge id)kSecValuePersistentRef];
            if (pref) {
                orig_SecItemDelete((__bridge CFDictionaryRef)@{ (__bridge id)kSecValuePersistentRef: pref });
                continue;
            }
            NSMutableDictionary *del = [NSMutableDictionary dictionary];
            del[(__bridge id)kSecClass] = cls;
            del[(__bridge id)kSecAttrSynchronizable] = (__bridge id)kSecAttrSynchronizableAny;
            if ([svc  isKindOfClass:[NSString class]]) del[(__bridge id)kSecAttrService] = svc;
            if ([acct isKindOfClass:[NSString class]]) del[(__bridge id)kSecAttrAccount] = acct;
            if ([srv  isKindOfClass:[NSString class]]) del[(__bridge id)kSecAttrServer]  = srv;
            orig_SecItemDelete((__bridge CFDictionaryRef)del);
        }
    }
    NSLog(@"[miOS-iso] miosWipeContainerKeychain done for id=%@ (prefix=%@)", containerID, prefix);
}

// MARK: - Container filesystem isolation (CFFIXED_USER_HOME + home-API hooks)

static NSString *gRealHome = nil;
static NSString *gContainerRoot = nil;

static NSString *(*orig_NSHomeDirectory)(void) = NULL;
static NSArray<NSString *> *(*orig_NSSearchPath)(NSUInteger, NSUInteger, BOOL) = NULL;
static NSString *(*orig_NSTemporaryDirectory)(void) = NULL;
static CFURLRef (*orig_CFCopyHomeDirectoryURL)(void) = NULL;

static NSString *miosRemap(NSString *p) {
    if (gContainerRoot.length == 0 || p.length == 0) return p;
    if ([p hasPrefix:gContainerRoot]) return p;
    if ([p isEqualToString:gRealHome]) return gContainerRoot;
    NSString *slash = [gRealHome stringByAppendingString:@"/"];
    if ([p hasPrefix:slash])
        return [gContainerRoot stringByAppendingString:[p substringFromIndex:gRealHome.length]];
    return p;
}
static NSString *new_NSHomeDirectory(void) { return gContainerRoot.length ? gContainerRoot : orig_NSHomeDirectory(); }
static NSString *new_NSTemporaryDirectory(void) { return miosRemap(orig_NSTemporaryDirectory()); }
static NSArray<NSString *> *new_NSSearchPath(NSUInteger d, NSUInteger m, BOOL e) {
    NSArray *o = orig_NSSearchPath(d, m, e);
    if (gContainerRoot.length == 0) return o;
    NSMutableArray *r = [NSMutableArray arrayWithCapacity:o.count];
    for (NSString *p in o) [r addObject:miosRemap(p)];
    return r;
}
static CFURLRef new_CFCopyHomeDirectoryURL(void) {
    if (gContainerRoot.length)
        return CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
            (__bridge CFStringRef)gContainerRoot, kCFURLPOSIXPathStyle, true);
    return orig_CFCopyHomeDirectoryURL ? orig_CFCopyHomeDirectoryURL() : NULL;
}
static void miosInstallContainerFS(MiOSContainer *c) {
    gContainerRoot = [[c containerRootEnsureCreated:YES] copy];
    if (!gContainerRoot.length) return;
    setenv("CFFIXED_USER_HOME", gContainerRoot.UTF8String, 1);
    setenv("HOME", gContainerRoot.UTF8String, 1);
    setenv("TMPDIR", [gContainerRoot stringByAppendingPathComponent:@"tmp"].UTF8String, 1);
    // fishhook so the FS redirect works on sideload without Substrate (like Blaze).
    rebind_symbols((struct rebinding[]){
        {"NSHomeDirectory",                      (void *)new_NSHomeDirectory,       (void **)&orig_NSHomeDirectory},
        {"NSTemporaryDirectory",                 (void *)new_NSTemporaryDirectory,  (void **)&orig_NSTemporaryDirectory},
        {"NSSearchPathForDirectoriesInDomains",  (void *)new_NSSearchPath,          (void **)&orig_NSSearchPath},
        {"CFCopyHomeDirectoryURL",               (void *)new_CFCopyHomeDirectoryURL,(void **)&orig_CFCopyHomeDirectoryURL},
    }, 4);
}

// CRITICAL container isolation — Blaze hooks exactly this. Modern apps (Instagram included) get
// their Documents/Library/Caches via -[NSFileManager URLsForDirectory:inDomains:], which does
// NOT route through NSHomeDirectory / NSSearchPathForDirectoriesInDomains — so the C-level
// redirects above miss it and the app reads/writes the REAL sandbox (session shared across
// containers). Redirect every returned URL into the active container's root.
%hook NSFileManager
- (NSArray<NSURL *> *)URLsForDirectory:(NSUInteger)directory inDomains:(NSUInteger)domainMask {
    NSArray<NSURL *> *res = %orig;
    if (gContainerRoot.length == 0 || res.count == 0) return res;
    NSMutableArray<NSURL *> *out = [NSMutableArray arrayWithCapacity:res.count];
    for (NSURL *u in res) {
        NSString *p = u.path;
        NSString *rp = miosRemap(p);
        if (rp.length && ![rp isEqualToString:p]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:rp
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            [out addObject:[NSURL fileURLWithPath:rp isDirectory:YES]];
        } else {
            [out addObject:u];
        }
    }
    return out;
}
- (NSURL *)URLForDirectory:(NSUInteger)directory inDomain:(NSUInteger)domain
         appropriateForURL:(NSURL *)url create:(BOOL)shouldCreate error:(NSError **)error {
    NSURL *u = %orig;
    if (gContainerRoot.length == 0 || !u) return u;
    NSString *rp = miosRemap(u.path);
    if (rp.length && ![rp isEqualToString:u.path]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:rp
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:rp isDirectory:YES];
    }
    return u;
}
%end

// MARK: - NSUserDefaults per-container isolation (Blaze-style)
//
// Instagram keeps the logged-in session in NSUserDefaults, which is served by the cfprefsd
// daemon — it ignores our CFFIXED_USER_HOME/HOME redirect, so without this the session is
// SHARED across containers and "switching container doesn't change the session". Blaze hooks
// the NSUserDefaults API (objectForKey/boolForKey/…/setObject/…/dictionaryRepresentation/
// persistentDomainForName/…) and backs it with a per-container store. We do the same.
//
// Model: all WRITES go only to the per-container plist (never the shared defaults). READS come
// from the per-container store; for keys the store doesn't have we fall back to the real
// defaults ONLY for system/global keys — a key that belongs to the app's own domain is served
// as "unset" so an old session in the shared defaults can't leak into a fresh container.
static NSMutableDictionary *gUD = nil;
static NSMutableDictionary *gUDReg = nil;   // registered defaults (volatile, registerDefaults:)
static NSString *gUDPath = nil;
static NSLock *gUDLock = nil;
static BOOL gUDDirty = NO;

static void miosUDPersist(void) {
    if (!gUD || !gUDPath) return;
    [gUDLock lock];
    NSDictionary *snap = gUDDirty ? [gUD copy] : nil;
    gUDDirty = NO;
    [gUDLock unlock];
    if (!snap) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:[gUDPath stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [snap writeToFile:gUDPath atomically:YES];
}
// Returns YES if the value was handled by the container store (so the hook should not read
// the shared defaults); *out gets the stored value (may be nil = app key, treat as unset).
// Only genuine system/global defaults should be read from the shared store; everything else is
// the app's own data and MUST stay isolated per container (never read from the shared defaults,
// or a pre-existing / another container's session leaks in). The old gRealAppKeys snapshot only
// covered the bundle domain, missing app-group suite keys — which is exactly where Instagram's
// "remembered account" lives, so it leaked. Classify by key namespace instead.
static BOOL miosUDIsSystemKey(NSString *k) {
    return [k hasPrefix:@"Apple"] || [k hasPrefix:@"NS"] || [k hasPrefix:@"com.apple."] ||
           [k hasPrefix:@"PK"]    || [k hasPrefix:@"WebKit"];
}
static BOOL miosUDLookup(NSString *key, id *out) {
    if (!gUD || ![key isKindOfClass:[NSString class]]) return NO;
    [gUDLock lock];
    id v = gUD[key];                       // 1. user-set value (highest priority)
    if (!v) v = gUDReg[key];               // 2. registered default
    [gUDLock unlock];
    if (v) { if (out) *out = v; return YES; }
    if (miosUDIsSystemKey(key)) return NO; // 3. system/global default → let %orig provide it
    if (out) *out = nil; return YES;       // 4. app key not set here → isolated (unset), no leak
}
static void miosUDSet(NSString *key, id value) {
    if (!gUD || ![key isKindOfClass:[NSString class]]) return;
    [gUDLock lock];
    if (value) gUD[key] = value; else [gUD removeObjectForKey:key];
    gUDDirty = YES;
    [gUDLock unlock];
}
static void miosInstallUserDefaultsIsolation(void) {
    if (gContainerRoot.length == 0) return;
    gUDLock = [NSLock new];
    gUDPath = [[[gContainerRoot stringByAppendingPathComponent:@"Library"]
                 stringByAppendingPathComponent:@"Preferences"]
                 stringByAppendingPathComponent:@"mios-userdefaults.plist"];
    NSMutableDictionary *loaded = [NSMutableDictionary dictionaryWithContentsOfFile:gUDPath];
    gUD = loaded ?: [NSMutableDictionary dictionary];
    gUDReg = [NSMutableDictionary dictionary];
    // Periodic flush of dirty writes.
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                  dispatch_get_global_queue(0, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                              (uint64_t)(1.5 * NSEC_PER_SEC), (uint64_t)(NSEC_PER_SEC / 3));
    dispatch_source_set_event_handler(t, ^{ miosUDPersist(); });
    static dispatch_source_t gUDTimer; gUDTimer = t; (void)gUDTimer;
    dispatch_resume(t);
}

%hook NSUserDefaults
- (id)objectForKey:(NSString *)key {
    id v = nil; if (miosUDLookup(key, &v)) return v;
    return %orig;
}
- (void)setObject:(id)value forKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, value); return; }
    %orig;
}
- (void)removeObjectForKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, nil); return; }
    %orig;
}
- (BOOL)boolForKey:(NSString *)key {
    id v = nil; if (miosUDLookup(key, &v)) return [v boolValue];
    return %orig;
}
- (NSInteger)integerForKey:(NSString *)key {
    id v = nil; if (miosUDLookup(key, &v)) return [v integerValue];
    return %orig;
}
- (double)doubleForKey:(NSString *)key {
    id v = nil; if (miosUDLookup(key, &v)) return [v doubleValue];
    return %orig;
}
- (float)floatForKey:(NSString *)key {
    id v = nil; if (miosUDLookup(key, &v)) return [v floatValue];
    return %orig;
}
- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, @(value)); return; }
    %orig;
}
- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, @(value)); return; }
    %orig;
}
- (void)setDouble:(double)value forKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, @(value)); return; }
    %orig;
}
- (void)setFloat:(float)value forKey:(NSString *)key {
    if (gUD && [key isKindOfClass:[NSString class]]) { miosUDSet(key, @(value)); return; }
    %orig;
}
- (void)registerDefaults:(NSDictionary *)registrationDictionary {
    if (gUD && [registrationDictionary isKindOfClass:[NSDictionary class]]) {
        [gUDLock lock]; [gUDReg addEntriesFromDictionary:registrationDictionary]; [gUDLock unlock];
    }
    %orig;   // keep the real NSRegistrationDomain populated too
}
- (BOOL)synchronize {
    miosUDPersist();
    return %orig;
}
- (NSDictionary *)dictionaryRepresentation {
    NSDictionary *o = %orig;
    if (!gUD) return o;
    NSMutableDictionary *m = o ? [o mutableCopy] : [NSMutableDictionary dictionary];
    [gUDLock lock];
    [m addEntriesFromDictionary:gUDReg];   // registered defaults (lower priority)
    [m addEntriesFromDictionary:gUD];       // user-set values (override)
    [gUDLock unlock];
    return m;
}
- (NSDictionary *)persistentDomainForName:(NSString *)domainName {
    if (gUD && [domainName isEqualToString:([[NSBundle mainBundle] bundleIdentifier] ?: @"")]) {
        [gUDLock lock]; NSDictionary *c = [gUD copy]; [gUDLock unlock];
        return c;
    }
    return %orig;
}
- (void)removePersistentDomainForName:(NSString *)domainName {
    if (gUD && [domainName isEqualToString:([[NSBundle mainBundle] bundleIdentifier] ?: @"")]) {
        [gUDLock lock]; [gUD removeAllObjects]; gUDDirty = YES; [gUDLock unlock];
        miosUDPersist();
        return;
    }
    %orig;
}
%end

// MARK: - sysctl / uname / CNCopy… / getifaddrs (allocation-free)

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_uname)(struct utsname *);
static int (*orig_getifaddrs)(struct ifaddrs **);
static CNCopyCurrentNetworkInfo_t orig_CNCopyCurrentNetworkInfo = NULL;

static int replyCString(void *oldp, size_t *oldlenp, const char *cstr) {
    size_t need = strlen(cstr) + 1;
    if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }
    if (oldlenp && *oldlenp < need) { errno = ENOMEM; return -1; }
    memcpy(oldp, cstr, need); if (oldlenp) *oldlenp = need; return 0;
}
static int copyIntOut(void *oldp, size_t *oldlenp, unsigned long long value) {
    if (*oldlenp >= 8) { *(uint64_t *)oldp = (uint64_t)value; *oldlenp = 8; }
    else if (*oldlenp >= 4) { *(uint32_t *)oldp = (uint32_t)value; *oldlenp = 4; }
    return 0;
}
static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && gDeviceSpoofActive) {
        if (gcMachine && strcmp(name, "hw.machine") == 0) return replyCString(oldp, oldlenp, gcMachine);
        if (gcModel   && strcmp(name, "hw.model")   == 0) return replyCString(oldp, oldlenp, gcModel);
        if (gcKernelVersion && (strcmp(name, "kern.version") == 0 || strcmp(name, "kern.osrelease") == 0))
            return replyCString(oldp, oldlenp, gcKernelVersion);
        if ((gcMemsize || gcCPU) && oldp && oldlenp) {
            int r = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
            if (r != 0) return r;
            if (gcMemsize && strcmp(name, "hw.memsize") == 0) return copyIntOut(oldp, oldlenp, gcMemsize);
            if (gcCPU && (strcmp(name, "hw.ncpu") == 0 || strcmp(name, "hw.logicalcpu") == 0 ||
                strcmp(name, "hw.logicalcpu_max") == 0 || strcmp(name, "hw.activecpu") == 0 ||
                strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.physicalcpu_max") == 0))
                return copyIntOut(oldp, oldlenp, (unsigned long long)gcCPU);
            return r;
        }
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}
static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && namelen >= 2 && gDeviceSpoofActive && name[0] == CTL_HW) {
        if (gcMachine && name[1] == HW_MACHINE) return replyCString(oldp, oldlenp, gcMachine);
        if (gcModel   && name[1] == HW_MODEL)   return replyCString(oldp, oldlenp, gcModel);
    }
    return orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}
static int hook_uname(struct utsname *buf) {
    int r = orig_uname(buf);
    if (r != 0 || !buf) return r;
    if (gDeviceSpoofActive && gcMachine) {
        strncpy(buf->machine, gcMachine, sizeof(buf->machine) - 1); buf->machine[sizeof(buf->machine)-1] = '\0';
    }
    if (gcKernelVersion) {
        strncpy(buf->release, gcKernelVersion, sizeof(buf->release) - 1); buf->release[sizeof(buf->release)-1] = '\0';
        strncpy(buf->version, gcKernelVersion, sizeof(buf->version) - 1); buf->version[sizeof(buf->version)-1] = '\0';
    }
    return r;
}
__attribute__((unused)) static CFDictionaryRef hook_CNCopyCurrentNetworkInfo(CFStringRef iface) {
    if (gcWifiInfo) return (CFDictionaryRef)CFRetain(gcWifiInfo);
    return orig_CNCopyCurrentNetworkInfo ? orig_CNCopyCurrentNetworkInfo(iface) : NULL;
}

// getifaddrs: rewrite the IPv4 of en0 (Wi-Fi) and pdp_ip0 (cellular) if spoofing is on.
static void miosRewriteIfaIPv4(struct ifaddrs *ifa, const char *addr) {
    if (!addr || !ifa || !ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) return;
    struct sockaddr_in *in = (struct sockaddr_in *)ifa->ifa_addr;
    struct in_addr tmp; if (inet_pton(AF_INET, addr, &tmp) == 1) in->sin_addr = tmp;
}
static int hook_getifaddrs(struct ifaddrs **ifap) {
    int r = orig_getifaddrs(ifap);
    if (r != 0 || !ifap || !*ifap) return r;
    BOOL spoofWiFi = spoofBool(@"enableSpoofWiFi");
    BOOL spoofCel  = spoofBool(@"enableSpoofCellular");
    if (!spoofWiFi && !spoofCel) return r;
    NSString *wifiIP = spoofStr(@"wifiAddress");
    NSString *celIP  = spoofStr(@"cellularAddress");
    for (struct ifaddrs *i = *ifap; i; i = i->ifa_next) {
        if (!i->ifa_name) continue;
        if (spoofWiFi && wifiIP.length && strcmp(i->ifa_name, "en0") == 0)
            miosRewriteIfaIPv4(i, wifiIP.UTF8String);
        else if (spoofCel && celIP.length && strncmp(i->ifa_name, "pdp_ip", 6) == 0)
            miosRewriteIfaIPv4(i, celIP.UTF8String);
    }
    return r;
}

// MARK: - MGCopyAnswer (MobileGestalt) — hook the INTERNAL implementation (iOS 15.7–16.7)
//
// Robust device-model / iOS-version spoofing. The public `MGCopyAnswer(key)` is just a thin
// thunk: `mov x1, #0` (clears the outTypeCode arg) then `B` into the real 2-argument internal
// `MGCopyAnswer_internal(key, outTypeCode)`. Both the app's anti-fraud code AND system
// frameworks (UIDevice, etc.) reach the internal, often bypassing the public symbol — so we
// follow the branch and hook the INTERNAL function (technique from ryannair05/MGSpoof &
// Lessica's iOS 15 gist). Falls back to hooking the public symbol if the prologue is unexpected.

// Shared: the spoofed value for a MobileGestalt key, or NULL to pass through.
static CFTypeRef miosMGSpoofedValue(CFStringRef key) {
    if (!gDeviceSpoofActive || !key) return NULL;
    if (gcMGProductType && CFEqual(key, CFSTR("ProductType")))              // e.g. iPhone14,2
        return CFRetain(gcMGProductType);
    if (gcMGHWModel && (CFEqual(key, CFSTR("HWModelStr")) ||                // board, e.g. D63AP
                        CFEqual(key, CFSTR("HardwarePlatform"))))
        return CFRetain(gcMGHWModel);
    if (gcMGDeviceName && (CFEqual(key, CFSTR("DeviceName")) ||
                           CFEqual(key, CFSTR("marketing-name")) ||
                           CFEqual(key, CFSTR("UserAssignedDeviceName"))))
        return CFRetain(gcMGDeviceName);
    if (gcMGProductVersion && CFEqual(key, CFSTR("ProductVersion")))        // iOS version
        return CFRetain(gcMGProductVersion);
    return NULL;
}
// Public thunk replacement (1-arg) — fallback path.
static CFTypeRef mios_MGCopyAnswer(CFStringRef key) {
    CFTypeRef v = miosMGSpoofedValue(key);
    if (v) return v;
    return gRealMGCopyAnswer ? gRealMGCopyAnswer(key) : NULL;
}
// Internal implementation replacement (2-arg) — primary path.
static CFTypeRef (*orig_MGCopyAnswer_internal)(CFStringRef, void *) = NULL;
static CFTypeRef mios_MGCopyAnswer_internal(CFStringRef key, void *outTypeCode) {
    CFTypeRef spoof = miosMGSpoofedValue(key);               // +1 CFString, or NULL
    // Always let the real impl run so it sets *outTypeCode correctly (the caller may read it to
    // decide how to interpret the return — a wrong/stale code on a spoofed CFString can crash). Our
    // spoofed keys are all strings, so the real string type code matches our replacement.
    CFTypeRef real = orig_MGCopyAnswer_internal ? orig_MGCopyAnswer_internal(key, outTypeCode) : NULL;
    if (spoof) {
        if (real) CFRelease(real);
        return spoof;
    }
    return real;
}
// Public-symbol inline-hook replacement. Unlike the fishhook import rebind (which only redirects
// an image's import pointers), MSHookFunction patches the REAL function bytes at MGCopyAnswer's
// address — so it also catches callers that resolved the pointer via dlsym (anti-fraud/telemetry
// SDKs do this to bypass import rebinding, which is why the app's login telemetry still saw the
// real model while the sysctl-built User-Agent was already spoofed).
static CFTypeRef (*orig_MGpub)(CFStringRef) = NULL;
static CFTypeRef mios_MGpub(CFStringRef key) {
    CFTypeRef v = miosMGSpoofedValue(key);
    if (v) return v;
    return orig_MGpub ? orig_MGpub(key) : NULL;
}
// NARROW, crash-safe dlsym interception — ONLY for "MGCopyAnswer". MSHookFunction is a no-op on
// this sideload runtime, so this is the only way to make dlsym-resolved MGCopyAnswer callers
// (IG's telemetry) see the spoofed device. The earlier GLOBAL dlsym hook crashed because (a) its
// fallback called the (now-rebound) dlsym and recursed, and (b) it also returned our sysctl/uname
// hooks, which get called during early init before their origs are ready. Both are fixed here:
//   - g_real_dlsym is captured BEFORE rebinding and always used for the fallthrough (no recursion),
//   - we intercept ONLY MGCopyAnswer, whose replacement (mios_MGpub) always has a valid real
//     fallback (orig_MGpub, set explicitly at install time).
static void *(*g_real_dlsym)(void *, const char *) = NULL;
static void *mios_dlsym(void *handle, const char *symbol) {
    if (symbol && gDeviceSpoofActive && orig_MGpub && strcmp(symbol, "MGCopyAnswer") == 0)
        return (void *)mios_MGpub;
    return g_real_dlsym ? g_real_dlsym(handle, symbol) : NULL;
}

// Real MGCopyAnswer address (captured before hooking) — the function Substitute inline-patches.
static void *gMGRealAddr = NULL;

// (MGCopyAnswerWithError is intentionally NOT hooked — uncertain iOS 18 ABI; a signature mismatch
// corrupts the call and crashes. Only MGCopyAnswer's import is rebound.)

// Old Substitute (comex) can't safely inline-patch arm64e shared-cache system code (iPhone 16 Pro /
// iOS 18): its trampoline faults → KERN_PROTECTION_FAILURE inside MGCopyAnswer_internal. So the
// Substitute inline path is OFF by default. Only a PAC-aware hooker (ElleKit) can inline-hook here.
static BOOL gUseSubstituteMG = NO;

// Substitute inline hook (comex/substitute). substitute_hook_functions patches the function's
// bytes in-process — it WORKS on sideload where MSHookFunction is a no-op — so dlsym/internal
// MGCopyAnswer callers (IG's telemetry) get the spoofed device too, without needing ElleKit.
// ABI mirrors <substitute.h>:
//   struct substitute_function_hook { void *function; void *replacement; void **old_ptr; int options; };
//   int substitute_hook_functions(const struct substitute_function_hook *, size_t, void **recordp, int options);
struct mios_sub_hook { void *function; void *replacement; void **old_ptr; int options; };
typedef int (*mios_sub_hook_fn)(const struct mios_sub_hook *, size_t, void **, int);
static void *miosFindMGInternal(const void *pub);   // defined below
static BOOL miosInstallMGViaSubstitute(void) {
    if (!(gcMGProductType || gcMGProductVersion || gcMGDeviceName || gcMGHWModel)) return NO;
    void *lh = dlopen("@loader_path/libsubstitute.0.dylib", RTLD_NOW);
    if (!lh) lh = dlopen("@executable_path/Frameworks/libsubstitute.0.dylib", RTLD_NOW);
    if (!lh) lh = dlopen("@loader_path/libsubstitute.dylib", RTLD_NOW);
    if (!lh) lh = dlopen("libsubstitute.0.dylib", RTLD_NOW);
    if (!lh) lh = dlopen("libsubstitute.dylib", RTLD_NOW);
    if (!lh) { NSLog(@"[miOS-iso] Substitute: dlopen failed (bundle libsubstitute.0.dylib in Frameworks/)"); return NO; }
    mios_sub_hook_fn hookfn = (mios_sub_hook_fn)dlsym(lh, "substitute_hook_functions");
    if (!hookfn) { NSLog(@"[miOS-iso] Substitute: no substitute_hook_functions symbol"); return NO; }

    if (!gMGRealAddr) return NO;
    // Hook the INTERNAL MGCopyAnswer (known 2-arg signature: key, outTypeCode). Both public entry
    // points — MGCopyAnswer (8-byte thunk) and MGCopyAnswerWithError — funnel through it, so this
    // one safe hook covers them all. Never patch the short public thunk; skip if internal unresolved.
    void *internal = NULL;
    @try { internal = miosFindMGInternal(gMGRealAddr); } @catch (__unused id e) { internal = NULL; }
    if (!internal || internal == gMGRealAddr) {
        NSLog(@"[miOS-iso] Substitute: internal MGCopyAnswer not resolved — skipping (won't patch short thunk)");
        return NO;
    }
    struct mios_sub_hook h = { internal, (void *)mios_MGCopyAnswer_internal, (void **)&orig_MGCopyAnswer_internal, 0 };
    int r = hookfn(&h, 1, NULL, 0);
    NSLog(@"[miOS-iso] Substitute MGCopyAnswer_internal inline-hook @%p -> %d (0=OK)", internal, r);
    return r == 0;
}
// Strip PAC from a code pointer so we can read its instruction bytes (no-op on plain arm64).
static const uint8_t *miosStripPAC(const void *p) {
#if __has_feature(ptrauth_calls)
    return (const uint8_t *)ptrauth_strip(p, ptrauth_key_function_pointer);
#else
    return (const uint8_t *)p;
#endif
}
// Follow an ARM64 B instruction at `pc` to its target address.
static const uint8_t *miosFollowB(const uint8_t *pc) {
    uint32_t ins = *(const uint32_t *)pc;
    int64_t imm = ins & 0x03FFFFFF;      // 26-bit signed
    imm = (imm << 38) >> 38;             // sign-extend
    return pc + (imm << 2);
}
// Given the public MGCopyAnswer thunk, return the internal implementation address, or NULL.
static void *miosFindMGInternal(const void *pub) {
    const uint8_t *p = miosStripPAC(pub);
    // Expected thunk prologue: mov x1, #0  ==  01 00 80 d2
    if (p[0] == 0x01 && p[1] == 0x00 && p[2] == 0x80 && p[3] == 0xd2) {
        uint32_t b = *(const uint32_t *)(p + 4);
        if ((b & 0xFC000000) == 0x14000000) {           // it's a B
            if ((b & 0x03FFFFFF) == 1) return (void *)(p + 8);   // legacy: B #4 → internal at +8
            return (void *)miosFollowB(p + 4);                   // modern: follow the branch
        }
    }
    // Fallback: first B within the first 16 bytes.
    for (int i = 0; i < 16; i += 4) {
        uint32_t ins = *(const uint32_t *)(p + i);
        if ((ins & 0xFC000000) == 0x14000000) return (void *)miosFollowB(p + i);
    }
    return NULL;
}
// (The old MSHookFunction-based MGCopyAnswer hook was removed: MSHookFunction is a no-op on this
// sideload substrate, and it targeted the 8-byte public thunk which crashes when patched. The
// device telemetry read is now covered by Substitute inline-hooking the INTERNAL impl —
// miosInstallMGViaSubstitute — plus the fishhook import rebind for linked callers.)

// MARK: - Per-container HTTPS proxy (NSURLSessionConfiguration)

// group ProxyHooks
%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSString *host = spoofStr(@"proxyHost"); NSInteger port = spoofInt(@"proxyPort");
    if (host.length && port > 0) {
        c.connectionProxyDictionary = @{
            @"HTTPSEnable": @YES,
            @"HTTPSProxy":  host,
            @"HTTPSPort":   @(port),
            @"HTTPEnable":  @YES,
            @"HTTPProxy":   host,
            @"HTTPPort":    @(port),
        };
    }
    return c;
}
+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    NSString *host = spoofStr(@"proxyHost"); NSInteger port = spoofInt(@"proxyPort");
    if (host.length && port > 0) {
        c.connectionProxyDictionary = @{
            @"HTTPSEnable": @YES, @"HTTPSProxy": host, @"HTTPSPort": @(port),
            @"HTTPEnable":  @YES, @"HTTPProxy":  host, @"HTTPPort":  @(port),
        };
    }
    return c;
}
%end
// end ProxyHooks

// MARK: - Build the allocation-free cache

static char *dupCString(NSString *s) { return s.length ? strdup(s.UTF8String ?: "") : NULL; }
static CFStringRef retainedCF(NSString *s) { return s.length ? (__bridge_retained CFStringRef)[s copy] : NULL; }

static void miosBuildSpoofCache(void) {
    gDeviceSpoofActive = spoofBool(@"enableSpoofDeviceModel") || spoofBool(@"enableSpoofSoftwareVersion") ||
                         spoofBool(@"enableSpoofMemory") || spoofBool(@"enableSpoofProcessor") ||
                         spoofBool(@"enableSpoofKernelVersion") || spoofBool(@"enableSpoofDeviceName");
    if (spoofBool(@"enableSpoofDeviceModel")) {
        gcMachine = dupCString(spoofStr(@"deviceIdentifier"));
        gcModel   = dupCString(spoofStr(@"deviceHardwareModel"));
        gcMGProductType = retainedCF(spoofStr(@"deviceIdentifier"));
        gcMGHWModel     = retainedCF(spoofStr(@"deviceHardwareModel"));
        gcMGDeviceName  = retainedCF(spoofStr(@"deviceDisplayName"));
    }
    if (spoofBool(@"enableSpoofSoftwareVersion"))
        gcMGProductVersion = retainedCF(spoofStr(@"iosVersion"));
    if (spoofBool(@"enableSpoofMemory")) {
        NSInteger gb = spoofInt(@"ramGB"); if (gb > 0)
            gcMemsize = (unsigned long long)gb * 1024ULL * 1024ULL * 1024ULL;
    }
    if (spoofBool(@"enableSpoofProcessor")) {
        NSInteger n = spoofInt(@"cpuCores"); if (n > 0) gcCPU = (int)n;
    }
    if (spoofBool(@"enableSpoofKernelVersion")) {
        NSString *kv = spoofStr(@"kernelVersion"); if (kv.length) gcKernelVersion = dupCString(kv);
    }
    if (spoofBool(@"enableSpoofWiFi")) {
        NSString *ssid = spoofStr(@"wifiSSID"); NSString *bssid = spoofStr(@"wifiBSSID");
        if (ssid.length && bssid.length) {
            NSDictionary *info = @{
                @"SSID": ssid, @"BSSID": bssid,
                @"SSIDDATA": [ssid dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data],
            };
            gcWifiInfo = (__bridge_retained CFDictionaryRef)[info copy];
        }
    }
}

// MARK: - Fresh-container reset (wipe cached App Group state once per container)

#define MIOS_CS_EMBEDDED_SIGNATURE    0xfade0cc0
#define MIOS_CS_EMBEDDED_ENTITLEMENTS 0xfade7171

static NSData *miosReadAt(NSFileHandle *fh, unsigned long long off, unsigned long long len) {
    @try { [fh seekToFileOffset:off]; return [fh readDataOfLength:(NSUInteger)len]; }
    @catch (__unused id e) { return nil; }
}
static NSArray<NSString *> *miosSelfAppGroups(void) {
    NSString *exe = [[NSBundle mainBundle] executablePath];
    NSFileHandle *fh = exe ? [NSFileHandle fileHandleForReadingAtPath:exe] : nil;
    if (!fh) return @[];
    NSArray *result = @[];
    @try {
        unsigned long long sliceOff = 0;
        NSData *m = miosReadAt(fh, 0, 4);
        if (m.length < 4) { [fh closeFile]; return @[]; }
        uint32_t magic = *(const uint32_t *)m.bytes;
        if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
            NSData *fhd = miosReadAt(fh, 0, sizeof(struct fat_header));
            uint32_t nfat = OSSwapBigToHostInt32(((const struct fat_header *)fhd.bytes)->nfat_arch);
            NSData *archs = miosReadAt(fh, sizeof(struct fat_header), nfat * sizeof(struct fat_arch));
            const struct fat_arch *a = (const struct fat_arch *)archs.bytes;
            for (uint32_t i = 0; i < nfat; i++)
                if (OSSwapBigToHostInt32(a[i].cputype) == CPU_TYPE_ARM64) { sliceOff = OSSwapBigToHostInt32(a[i].offset); break; }
            if (!sliceOff && nfat) sliceOff = OSSwapBigToHostInt32(a[0].offset);
            NSData *m2 = miosReadAt(fh, sliceOff, 4);
            magic = m2.length >= 4 ? *(const uint32_t *)m2.bytes : 0;
        }
        if (magic != MH_MAGIC_64 && magic != MH_CIGAM_64) { [fh closeFile]; return @[]; }
        NSData *hd = miosReadAt(fh, sliceOff, sizeof(struct mach_header_64));
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)hd.bytes;
        uint32_t ncmds = hdr->ncmds, sizeofcmds = hdr->sizeofcmds;
        NSData *cmds = miosReadAt(fh, sliceOff + sizeof(struct mach_header_64), sizeofcmds);
        const uint8_t *p = cmds.bytes, *end = p + cmds.length;
        uint32_t csOff = 0, csSize = 0;
        for (uint32_t i = 0; i < ncmds && p + sizeof(struct load_command) <= end; i++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmd == LC_CODE_SIGNATURE) {
                const struct linkedit_data_command *ld = (const struct linkedit_data_command *)p;
                csOff = ld->dataoff; csSize = ld->datasize; break;
            }
            if (lc->cmdsize == 0) break;
            p += lc->cmdsize;
        }
        if (csOff && csSize) {
            NSData *sig = miosReadAt(fh, sliceOff + csOff, csSize);
            const uint8_t *s = sig.bytes;
            if (sig.length >= 12 && OSSwapBigToHostInt32(*(const uint32_t *)s) == MIOS_CS_EMBEDDED_SIGNATURE) {
                uint32_t count = OSSwapBigToHostInt32(*(const uint32_t *)(s + 8));
                for (uint32_t i = 0; i < count; i++) {
                    const uint8_t *idx = s + 12 + i * 8;
                    if (idx + 8 > s + sig.length) break;
                    uint32_t bo = OSSwapBigToHostInt32(*(const uint32_t *)(idx + 4));
                    if (bo + 8 > sig.length) continue;
                    if (OSSwapBigToHostInt32(*(const uint32_t *)(s + bo)) == MIOS_CS_EMBEDDED_ENTITLEMENTS) {
                        uint32_t bl = OSSwapBigToHostInt32(*(const uint32_t *)(s + bo + 4));
                        if (bl > 8 && bo + bl <= sig.length) {
                            NSData *pl = [NSData dataWithBytes:(s + bo + 8) length:(bl - 8)];
                            id obj = [NSPropertyListSerialization propertyListWithData:pl options:0 format:NULL error:NULL];
                            id g = [obj isKindOfClass:[NSDictionary class]] ? obj[@"com.apple.security.application-groups"] : nil;
                            if ([g isKindOfClass:[NSArray class]]) result = g;
                        }
                        break;
                    }
                }
            }
        }
    } @catch (__unused id e) {}
    [fh closeFile];
    return result;
}
static void miosResetContainerCachesOnce(NSString *uuid) {
    if (uuid.length == 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *marker = [MiOSBaseDir() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@".init_%@", uuid]];
    if ([fm fileExistsAtPath:marker]) return;
    for (NSString *group in miosSelfAppGroups()) {
        if (![group isKindOfClass:[NSString class]] || group.length == 0) continue;
        @try {
            NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:group];
            [d removePersistentDomainForName:group]; [d synchronize];
        } @catch (__unused id e) {}
        NSURL *gurl = [fm containerURLForSecurityApplicationGroupIdentifier:group];
        if (gurl) {
            for (NSString *sub in @[@"Library/Preferences", @"Library/Caches", @"Library/Application Support"]) {
                NSString *dir = [gurl.path stringByAppendingPathComponent:sub];
                for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[])
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:item] error:nil];
            }
        }
    }
    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// MARK: - Diagnostics (capture silent exits / crashes during registration)
//
// Instagram "exits without a crash" (no .ips) usually means a silent exit(): either the
// app's own anti-tamper detected the injection and called exit()/abort(), or a signal
// (SIGSEGV/SIGABRT/…) was raised. A normal crash reporter won't show that reliably on a
// sideloaded build, so we install our own:
//   • a persistent fd to Documents/miOS-diag.log (append, line-buffered via raw write)
//   • signal handlers that dump a backtrace async-signal-safely, then re-raise the default
//   • an atexit() handler with a backtrace — this is the one that catches who called exit()
//   • an NSSetUncaughtExceptionHandler for Obj-C exceptions
// Retrieve the log afterwards via Files/TrollStore (Documents/miOS-diag.log). Enable
// UIFileSharingEnabled so it shows up in Finder.

static int gDiagFd = -1;
static pthread_t gMainPThread = NULL;   // captured in the ctor (which runs on the main thread)

// Async-signal-safe raw write of a C string.
static void diagRaw(const char *s) {
    if (gDiagFd < 0 || !s) return;
    size_t len = 0;
    while (s[len]) len++;
    ssize_t w = write(gDiagFd, s, len); (void)w;
}

// Async-signal-safe decimal write (avoids snprintf in signal context).
static void diagRawNum(long n) {
    if (gDiagFd < 0) return;
    char buf[32];
    int i = sizeof(buf);
    buf[--i] = '\0';
    if (n == 0) { buf[--i] = '0'; }
    int neg = n < 0;
    unsigned long u = neg ? (unsigned long)(-n) : (unsigned long)n;
    while (u && i > 0) { buf[--i] = (char)('0' + (u % 10)); u /= 10; }
    if (neg && i > 0) buf[--i] = '-';
    diagRaw(&buf[i]);
}

// Async-signal-safe hex writer (0x-prefixed).
static void diagRawHex(unsigned long v) {
    char buf[2 + 16 + 1];
    int i = (int)sizeof(buf);
    buf[--i] = '\0';
    const char *hx = "0123456789abcdef";
    if (v == 0) buf[--i] = '0';
    while (v && i > 0) { buf[--i] = hx[v & 0xf]; v >>= 4; }
    if (i >= 2) { buf[--i] = 'x'; buf[--i] = '0'; }
    diagRaw(&buf[i]);
}

// Read the __TEXT segment's vmaddr from a Mach-O image loaded at `base` — this is the base
// address Ghidra uses when it loads that same binary, so (addr - loadbase + textvmaddr) is
// the exact static address to type into Ghidra for that image.
static uintptr_t diagTextVMAddr(const void *base) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)base;
    if (!h || h->magic != MH_MAGIC_64) return 0;
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const struct segment_command_64 *)lc;
            if (strcmp(sc->segname, "__TEXT") == 0) return (uintptr_t)sc->vmaddr;
        }
        if (lc->cmdsize == 0) break;
        p += lc->cmdsize;
    }
    return 0;
}

// Per-frame table: which binary each return address is in, and its exact Ghidra address.
// Find the TOP frame whose image is Instagram (or an Instagram framework), load THAT binary
// in Ghidra, and jump to the printed ghidra= address — that's the precise spot to patch.
static void diagSymbolicate(void **frames, int n) {
    diagRaw("-- per-image addresses (load THIS binary in Ghidra, go to ghidra=) --\n");
    for (int i = 0; i < n; i++) {
        Dl_info info;
        if (dladdr(frames[i], &info) && info.dli_fbase) {
            uintptr_t rt = (uintptr_t)frames[i];
            uintptr_t off = rt - (uintptr_t)info.dli_fbase;
            uintptr_t ghidra = diagTextVMAddr(info.dli_fbase) + off;
            const char *nm = info.dli_fname ? info.dli_fname : "?";
            const char *bn = nm;
            for (const char *c = nm; *c; c++) if (*c == '/') bn = c + 1;   // basename
            diagRaw("#"); diagRawNum(i); diagRaw(" ");
            diagRaw(bn);
            diagRaw("  rt="); diagRawHex(rt);
            diagRaw("  ghidra="); diagRawHex(ghidra);
            diagRaw("\n");
        }
    }
    diagRaw("-- end per-image addresses --\n");
}

static void diagSignalHandler(int sig);

// (Re)install our fatal-signal handlers. Called at ctor time and again a few seconds later,
// because Instagram installs its own crash handler during launch that would shadow ours.
static void miosArmSignals(void) {
    int sigs[] = { SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS };
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = diagSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;   // restore default after first hit (we re-raise anyway)
    for (size_t i = 0; i < sizeof(sigs)/sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

// Signal handler: dump signal number + backtrace, then restore default disposition and
// re-raise so the OS still produces whatever report it would have.
static void diagSignalHandler(int sig) {
    diagRaw("\n*** miOS caught signal ");
    diagRawNum(sig);
    diagRaw(" ***\n");
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, gDiagFd);
    diagSymbolicate(frames, n);
    diagRaw("*** end signal backtrace ***\n");
    signal(sig, SIG_DFL);
    raise(sig);
}

// atexit handler: records that the process is terminating and dumps who called exit().
// If Instagram's anti-tamper calls exit(0) on detecting the injection, its frame shows here.
static void diagAtExit(void) {
    diagRaw("\n*** miOS atexit: process is exiting ***\n");
    void *frames[64];
    int n = backtrace(frames, 64);
    backtrace_symbols_fd(frames, n, gDiagFd);
    diagSymbolicate(frames, n);
    diagRaw("*** end atexit backtrace ***\n");
    if (gDiagFd >= 0) { fsync(gDiagFd); }
}

// SIGUSR1 handler: used to SAMPLE a thread's stack on demand (not a crash). The watchdog
// raises SIGUSR1 on the main thread when it detects a hang, so this runs *on the stuck main
// thread* and dumps exactly where it froze — the Instagram return addresses here are what
// you convert to Ghidra addresses (Ghidra_addr = runtime_addr - slide, slide logged at ctor)
// to find and patch the blocking check.
static void diagSampleHandler(int sig) {
    (void)sig;
    diagRaw("\n*** miOS main-thread sample (hang) ***\n");
    void *frames[96];
    int n = backtrace(frames, 96);
    backtrace_symbols_fd(frames, n, gDiagFd);
    diagSymbolicate(frames, n);
    diagRaw("*** end main-thread sample ***\n");
    if (gDiagFd >= 0) { fsync(gDiagFd); }
}

static void diagUncaughtException(NSException *e) {
    @try {
        NSString *msg = [NSString stringWithFormat:
            @"\n*** miOS uncaught Obj-C exception ***\nname=%@\nreason=%@\ncallStack=%@\n*** end exception ***\n",
            e.name, e.reason, e.callStackSymbols];
        diagRaw(msg.UTF8String);
    } @catch (__unused id x) {}
    if (gDiagFd >= 0) { fsync(gDiagFd); }
}

// Timestamped milestone line. Safe to call from normal (non-signal) context.
// Writes to the log file (fsync'd immediately so a freeze still leaves the last line on
// disk) AND mirrors to NSLog, so you can also watch it live in Console.app on a Mac —
// this is how you catch a *hang*: the last "[miOS] …" line printed is what Instagram was
// doing when it froze (e.g. the DeviceCheck / App Attest call right before the hang).
static void miosLog(NSString *fmt, ...) {
    if (!MIOS_DIAG) return;   // diagnostics off: no logging at all
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSLog(@"[miOS] %@", body);          // live view in Console.app / idevicesyslog
        if (gDiagFd >= 0) {
            time_t t = time(NULL);
            NSString *line = [NSString stringWithFormat:@"[%ld] %@\n", (long)t, body];
            diagRaw(line.UTF8String);
            fsync(gDiagFd);
        }
    } @catch (__unused id x) {}
}

static void miosInstallDiagnostics(NSString *home) {
    if (!MIOS_DIAG) return;     // diagnostics off: no fd, no signal handlers, no atexit
    if (gDiagFd >= 0) return;   // once
    @try {
        NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docs
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *logPath = [docs stringByAppendingPathComponent:@"miOS-diag.log"];
        gDiagFd = open(logPath.fileSystemRepresentation,
                       O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (gDiagFd < 0) return;
    } @catch (__unused id e) { return; }

    miosLog(@"==== miOS diagnostics session start ====");

    // Uncaught Obj-C exceptions.
    NSSetUncaughtExceptionHandler(&diagUncaughtException);

    // Fatal signals — those that indicate a crash or a forced abort. Instagram installs its
    // own crash handler during launch which would overwrite ours, so re-arm a few seconds in
    // (and again later) to make sure OUR handler is the one that logs the crash address.
    miosArmSignals();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{ miosArmSignals(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{ miosArmSignals(); });

    // SIGUSR1 — on-demand stack sample (the watchdog raises it on the main thread to
    // capture where a hang is stuck). No SA_RESETHAND so it can fire more than once.
    struct sigaction su;
    memset(&su, 0, sizeof(su));
    su.sa_handler = diagSampleHandler;
    sigemptyset(&su.sa_mask);
    su.sa_flags = 0;
    sigaction(SIGUSR1, &su, NULL);

    // Log the main executable's ASLR slide so any runtime address in a backtrace can be
    // converted to a static Ghidra address:  Ghidra_addr = runtime_addr - slide
    // (Ghidra loads Instagram at its __TEXT base 0x100000000; slide = runtime_base - that).
    @try {
        const char *name0 = _dyld_get_image_name(0);
        intptr_t slide0 = _dyld_get_image_vmaddr_slide(0);
        miosLog(@"image[0]=%s slide=0x%lx  (Ghidra_addr = runtime_addr - slide)",
                name0 ?: "?", (long)slide0);
    } @catch (__unused id e) {}

    // Catch exit() / abort() paths — this is the key one for a "no crash" silent quit.
    atexit(&diagAtExit);
}

// Main-thread watchdog. A background timer pings the main queue every 2s; if the main
// thread stops acknowledging, it's blocked (a freeze). If it keeps acknowledging while
// the UI shows an endless spinner, the app is alive and waiting on something external
// (a network request) — not frozen. Either way the log tells us which.
static void miosStartWatchdog(void) {
    if (!MIOS_DIAG) return;     // diagnostics off: no watchdog / SIGUSR1 sampling
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("com.mios.watchdog", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                  (uint64_t)(2 * NSEC_PER_SEC), (uint64_t)(NSEC_PER_SEC / 2));
        static uint64_t tick = 0, mainAck = 0;
        static int sampled = 0;
        dispatch_source_set_event_handler(timer, ^{
            tick++;
            uint64_t sent = tick;
            dispatch_async(dispatch_get_main_queue(), ^{ mainAck = sent; });
            uint64_t lag = tick - mainAck;
            if (lag >= 2) {
                if (!sampled) {
                    miosLog(@"WATCHDOG: main thread unresponsive ~%llus — sampling its stack (SIGUSR1)",
                            (unsigned long long)(lag * 2));
                    if (gMainPThread) pthread_kill(gMainPThread, SIGUSR1);  // dump where main is stuck
                    sampled = 1;   // once per hang episode
                }
            } else {
                sampled = 0;       // main recovered; arm again for the next hang
            }
        });
        // Keep a strong ref so the source isn't released.
        static dispatch_source_t gTimer; gTimer = timer; (void)gTimer;
        dispatch_resume(timer);
        miosLog(@"watchdog started");
    });
}

// MARK: - Sideload fixes (keychain access group + app-group container) — opa334/IGSideloadFix
//
// These are NOT spoofing — they're what makes a resigned Instagram able to log in at all.
// A sideloaded app gets a different keychain access group and no shared app-group container
// than the App Store build expects, so SecItem returns errSecMissingEntitlement and
// containerURLForSecurityApplicationGroupIdentifier: returns nil → crash at login/registration.

// Discover a keychain access group this (resigned) app is actually entitled to: add a probe
// item with no access group (lands in the app's default group), read back which group it got.
static NSString *gValidAccessGroup = nil;
static NSString *miosValidAccessGroup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *probe = @{
            (__bridge id)kSecClass:         (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:   @"com.mios.ag.probe",
            (__bridge id)kSecAttrAccount:   @"probe",
            (__bridge id)kSecReturnAttributes: @YES,
        };
        CFTypeRef result = NULL;
        OSStatus s = SecItemAdd((__bridge CFDictionaryRef)probe, &result);
        if (s == errSecDuplicateItem) {
            NSDictionary *q = @{
                (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: @"com.mios.ag.probe",
                (__bridge id)kSecAttrAccount: @"probe",
                (__bridge id)kSecReturnAttributes: @YES,
                (__bridge id)kSecMatchLimit:  (__bridge id)kSecMatchLimitOne,
            };
            s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
        }
        if (s == errSecSuccess && result) {
            NSDictionary *attrs = (__bridge_transfer NSDictionary *)result;
            gValidAccessGroup = [attrs[(__bridge id)kSecAttrAccessGroup] copy];
        }
        // Remove the probe so we don't leave junk behind.
        SecItemDelete((__bridge CFDictionaryRef)@{
            (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"com.mios.ag.probe",
            (__bridge id)kSecAttrAccount: @"probe",
        });
        miosLog(@"sideload fix: valid keychain access group = %@", gValidAccessGroup ?: @"(none)");
    });
    return gValidAccessGroup;
}

%group SideloadFixes
// Skip Instagram's CloudKit-backed Cloud ID validation — it _os_crashes on the nil CloudKit
// result when sideloaded. Making it a no-op lets signup proceed without the iCloud signal.
%hook IGCloudIDValidation
- (void)startCloudIDValidationWithNetworker:(id)networker {
    miosLog(@"sideload fix: skipping IGCloudIDValidation (avoids CloudKit nil _os_crash)");
    // intentionally do NOT call %orig
}
%end
%hook NSFileManager
- (NSURL *)containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupID {
    // PER-CONTAINER app-group isolation. Instagram stores "remembered accounts" (saved logins,
    // avatars) in its App Group container, so if this is shared the same profile leaks into
    // every container. Always redirect into the ACTIVE container's own root (never the real
    // shared home, and never %orig which would be the shared system group when entitled).
    NSString *root = gContainerRoot.length ? gContainerRoot : gRealHome;
    NSString *base = [root stringByAppendingPathComponent:@"AppGroups"];
    NSString *dir = groupID.length ? [base stringByAppendingPathComponent:groupID] : base;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:[dir stringByAppendingPathComponent:@"Library/Caches"]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [NSURL fileURLWithPath:dir isDirectory:YES];
}
%end
%hook FBSDKKeychainStore
- (NSString *)accessGroup { NSString *g = miosValidAccessGroup(); return g ?: %orig; }
%end
%hook FBKeychainItemController
- (NSString *)accessGroup { NSString *g = miosValidAccessGroup(); return g ?: %orig; }
%end
%hook UICKeyChainStore
- (NSString *)accessGroup { NSString *g = miosValidAccessGroup(); return g ?: %orig; }
%end
%end
// end group SideloadFixes

// MARK: - Telemetry JSON device rewrite (TinderSpoofer-style)
//
// Even with every device-read API hooked, an app can serialize a device value it cached earlier
// (or read through a path we miss) into its login/analytics JSON body — which is what IG's servers
// record and show in "account settings". We intercept NSJSONSerialization and replace any value
// that exactly equals the REAL model identifier / marketing name / iOS version with the spoofed
// one, so the real device cannot reach the server through a JSON payload. Uses MSHookMessageEx
// (ObjC), which is confirmed working on this sideload.
static id miosRewriteDeviceJSON(id obj, NSInteger depth) {
    if (depth > 24 || obj == nil) return obj;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        NSString *rep = nil;
        if (gRealMachineNS.length  && [s isEqualToString:gRealMachineNS])  rep = spoofStr(@"deviceIdentifier");
        else if (gRealFriendlyNS.length && [s isEqualToString:gRealFriendlyNS]) rep = spoofStr(@"deviceDisplayName");
        else if (gRealIOSNS.length      && [s isEqualToString:gRealIOSNS])      rep = spoofStr(@"iosVersion");
        return rep.length ? rep : s;   // never replace with an empty value
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:[(NSArray *)obj count]];
        for (id e in (NSArray *)obj) [a addObject:miosRewriteDeviceJSON(e, depth + 1)];
        return a;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:[(NSDictionary *)obj count]];
        for (id k in (NSDictionary *)obj) d[k] = miosRewriteDeviceJSON(((NSDictionary *)obj)[k], depth + 1);
        return d;
    }
    return obj;
}
%hook NSJSONSerialization
+ (NSData *)dataWithJSONObject:(id)obj options:(NSJSONWritingOptions)opt error:(NSError **)error {
    if (gDeviceSpoofActive && (gRealMachineNS.length || gRealIOSNS.length || gRealFriendlyNS.length)) {
        @try {
            id rep = miosRewriteDeviceJSON(obj, 0);
            if (rep) return %orig(rep, opt, error);
        } @catch (__unused id e) {}
    }
    return %orig;
}
%end

// Network-body device rewrite. Because MSHookFunction is a NO-OP on this sideload runtime, we
// cannot inline-patch the dlsym/internal MGCopyAnswer that IG's telemetry uses — so the real model
// reaches the request body. Instead we rewrite the body as it leaves the app (ObjC hooks, which DO
// work). We only touch TEXT bodies (JSON/form/query) and replace the specific model identifier and
// marketing name (unambiguous substrings); iOS version is handled structurally by the JSON hook to
// avoid corrupting unrelated numbers.
static NSData *miosRewriteHTTPBody(NSData *body) {
    if (!gDeviceSpoofActive || body.length < 6) return body;
    if (!(gRealMachineNS.length || gRealFriendlyNS.length)) return body;
    NSString *s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (!s.length) return body;   // binary (protobuf/thrift) — don't risk corrupting it
    NSString *spM = spoofStr(@"deviceIdentifier");
    NSString *spF = spoofStr(@"deviceDisplayName");
    NSString *out = s; BOOL ch = NO;
    if (gRealMachineNS.length && spM.length && [out containsString:gRealMachineNS]) {
        out = [out stringByReplacingOccurrencesOfString:gRealMachineNS withString:spM]; ch = YES;
    }
    if (gRealFriendlyNS.length && spF.length && [out containsString:gRealFriendlyNS]) {
        out = [out stringByReplacingOccurrencesOfString:gRealFriendlyNS withString:spF]; ch = YES;
    }
    if (ch) {
        NSData *nd = [out dataUsingEncoding:NSUTF8StringEncoding];
        if (nd) { NSLog(@"[miOS-iso] rewrote real device out of HTTP body (%lu bytes)", (unsigned long)nd.length); return nd; }
    }
    return body;
}
%hook NSMutableURLRequest
- (void)setHTTPBody:(NSData *)body { %orig(miosRewriteHTTPBody(body)); }
%end
// NOTE: NSURLSession uploadTaskWithRequest:fromData: is already hooked above (search
// "%hook NSURLSession"); the body rewrite is wired into those existing methods to avoid a
// duplicate-hook compile error.

// MARK: - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exeName = [[[NSBundle mainBundle] executablePath] lastPathComponent] ?: @"";

        // Loose Instagram detection: signer-renamed bundle IDs still match. We only need to
        // avoid firing inside SpringBoard or an unrelated app that happens to load this dylib.
        NSString *low = bundleID.lowercaseString;
        BOOL isInstagram = ([low containsString:@"burbn"] ||
                            [low containsString:@"instagram"] ||
                            [exeName isEqualToString:@"Instagram"]);
        if (!isInstagram) return;

        gRealHome = [NSHomeDirectory() copy];
        MiOSSetRealHome(gRealHome);
        setenv("MIOS_REAL_HOME", gRealHome.UTF8String, 1);

        // Install the diagnostic logger as early as possible so it captures a silent exit
        // during registration. Writes to <home>/Documents/miOS-diag.log.
        gMainPThread = pthread_self();   // the ctor runs on the main thread during dyld load
        miosInstallDiagnostics(gRealHome);
        miosLog(@"ctor engaged: bundleID=%@ exe=%@ home=%@", bundleID, exeName, gRealHome);
        // Confirm the main-thread handle from the main queue too (belt and suspenders).
        dispatch_async(dispatch_get_main_queue(), ^{ gMainPThread = pthread_self(); });
        miosStartWatchdog();   // detect main-thread freeze vs. network wait during the spinner

        // Diagnostic: a 'did I load?' marker overwritten each launch. If none of these files
        // exist after you open Instagram, dyld didn't load the dylib (signing stripped it,
        // LC_LOAD_DYLIB wasn't injected, or ldid signature was invalid).
        @try {
            NSString *diag = [NSString stringWithFormat:
                @"miOS loaded at %@\nbundleID=%@\nexecutable=%@\nhome=%@\ntmp=%@\n",
                [NSDate date], bundleID, exeName, gRealHome, NSTemporaryDirectory()];
            NSArray<NSString *> *paths = @[
                [[gRealHome stringByAppendingPathComponent:@"Documents"]
                    stringByAppendingPathComponent:@"mios-loaded.txt"],
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"mios-loaded.txt"],
                [[gRealHome stringByAppendingPathComponent:@"Library/Caches"]
                    stringByAppendingPathComponent:@"mios-loaded.txt"],
            ];
            for (NSString *path in paths) {
                [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                          withIntermediateDirectories:YES attributes:nil error:nil];
                [diag writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        } @catch (__unused id e) {}

        [MiOSUI install];   // floating button is always available

        // Sideload fixes are ALWAYS on (independent of spoof mode): without them a resigned
        // Instagram crashes at login regardless of containers/spoofing. Mirrors opa334.
        %init(SideloadFixes);
        miosLog(@"SideloadFixes installed (keychain access group + app-group container)");

        // Default is the permanent base container: if nothing is selected (e.g. first launch),
        // activate Default rather than passing through. Pass-through would route accounts to the
        // REAL, un-namespaced keychain (which survives reinstall and leaks across containers) —
        // the root cause of "old accounts still show in Default after clearing cache".
        MiOSContainer *active = [MiOSContainer activeOrDefaultContainer];
        if (!active) {
            miosLog(@"no active container and Default unavailable — passing through");
            return;
        }

        gContainerUUID = [active.identifier copy];
        // CONTAINER ISOLATION is independent of the Spoof toggle: EVERY active container
        // (including Default, which has enableSpoof = NO) gets its own fully isolated sandbox —
        // filesystem, NSUserDefaults (the session store), and keychain. Device-fingerprint
        // spoofing is the only thing gated by enableSpoof.
        gSpoof = active.enableSpoof ? [[active spoofPrefs] copy] : @{};
        miosLog(@"active container=%@ enableSpoof=%d — installing isolation",
                gContainerUUID, (int)active.enableSpoof);

        // 1. Filesystem isolation first.
        miosInstallContainerFS(active);

        // 1b. NSUserDefaults isolation (the session store cfprefsd keeps outside our FS redirect).
        miosInstallUserDefaultsIsolation();

        // 2. Keychain namespacing.
        gKcPrefix = [NSString stringWithFormat:@"__mios_%@_", gContainerUUID];
        miosInitKeychainNamespace();

        // --- isolation diagnostics (always-on NSLog; filter Console by "miOS-iso") ---
        NSLog(@"[miOS-iso] container=%@ root=%@ kcPrefix=%@", gContainerUUID, gContainerRoot, gKcPrefix);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSLog(@"[miOS-iso] NSHomeDirectory -> %@", NSHomeDirectory());
            NSURL *ag = [[NSFileManager defaultManager]
                         containerURLForSecurityApplicationGroupIdentifier:@"group.com.burbn.instagram"];
            NSLog(@"[miOS-iso] app-group url -> %@", ag.path);
        });

        // 3. First-launch App-Group wipe.
        miosResetContainerCachesOnce(gContainerUUID);

        // 4. Precompute spoof cache + install hooks (gDeviceSpoofActive stays NO when spoof off).
        miosBuildSpoofCache();

        // 4b. Capture the REAL device values NOW — before any sysctl/MGCopyAnswer hook is installed
        // below — so the telemetry JSON rewrite can swap them out of outgoing login/analytics bodies.
        if (gDeviceSpoofActive) {
            char m[128] = {0}; size_t ml = sizeof(m);
            if (sysctlbyname("hw.machine", m, &ml, NULL, 0) == 0 && m[0])
                gRealMachineNS = [NSString stringWithUTF8String:m];
            char v[128] = {0}; size_t vl = sizeof(v);
            if (sysctlbyname("kern.osproductversion", v, &vl, NULL, 0) == 0 && v[0])
                gRealIOSNS = [NSString stringWithUTF8String:v];
            // Capture the REAL dlsym now (before we rebind it) so the narrow dlsym hook's
            // fallthrough can never recurse.
            g_real_dlsym = (void *(*)(void *, const char *))dlsym(RTLD_DEFAULT, "dlsym");
            void *mgH = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
            if (mgH) {
                CFTypeRef (*mg)(CFStringRef) = (CFTypeRef (*)(CFStringRef))dlsym(mgH, "MGCopyAnswer");
                if (mg) {
                    // Real MGCopyAnswer — the guaranteed fallback for mios_MGpub (so dlsym callers
                    // of non-spoofed keys always get a valid value, never NULL) + the address
                    // Substitute inline-patches.
                    gMGRealAddr = (void *)mg;
                    if (!orig_MGpub) orig_MGpub = (CFTypeRef (*)(CFStringRef))mg;
                    CFTypeRef fn = mg(CFSTR("marketing-name"));
                    if (fn && CFGetTypeID(fn) == CFStringGetTypeID()) gRealFriendlyNS = (__bridge_transfer NSString *)fn;
                    else if (fn) CFRelease(fn);
                }
            }
            NSLog(@"[miOS-iso] captured REAL device: machine=%@ ios=%@ friendly=%@ (dlsym=%p mgpub=%p)",
                  gRealMachineNS, gRealIOSNS, gRealFriendlyNS, (void *)g_real_dlsym, (void *)orig_MGpub);
        }

        // Bind the always-on hooks (device/identifier/network/etc. — each self-gates with
        // its own spoofBool(...) check).
        %init;

        // DeviceCheck and App Attest are not hooked at all (removed to match Blaze).

        // Low-level C hooks via fishhook (like Blaze) so they fire on sideload without Substrate.
        // We cover EVERY path the app can read the device through:
        //   - sysctlbyname("hw.machine"/"hw.model")  — string-keyed sysctl
        //   - sysctl({CTL_HW, HW_MACHINE/HW_MODEL})  — array-keyed sysctl (IG uses this form too!)
        //   - uname()                                 — utsname.machine
        //   - MGCopyAnswer (import)                   — linked MobileGestalt callers
        //   - dlsym("MGCopyAnswer"/"sysctl*"/"uname") — runtime-resolved (anti-fraud bypass)
        if (gDeviceSpoofActive) {
            rebind_symbols((struct rebinding[]){
                {"sysctlbyname", (void *)hook_sysctlbyname, (void **)&orig_sysctlbyname},
                {"sysctl",       (void *)hook_sysctl,       (void **)&orig_sysctl},
                {"uname",        (void *)hook_uname,        (void **)&orig_uname},
            }, 3);
            // MobileGestalt: fishhook the public MGCopyAnswer import (what the app calls for
            // ProductType/ProductVersion), plus a best-effort internal hook for system callers.
            if (gcMGProductType || gcMGProductVersion || gcMGDeviceName || gcMGHWModel) {
                // fishhook the MGCopyAnswer IMPORT — safe table rewrite (no code patching, no PAC
                // issue), 1-arg signature is well-known. We deliberately do NOT rebind
                // MGCopyAnswerWithError: its iOS 18 ABI is uncertain (likely >2 args), and a
                // signature mismatch in the replacement corrupts the call → crash.
                rebind_symbols((struct rebinding[]){
                    {"MGCopyAnswer", (void *)mios_MGCopyAnswer, (void **)&gRealMGCopyAnswer},
                }, 1);
                // Substitute inline-hook is OFF: old comex Substitute can't relocate the arm64e
                // (PAC) prologue of system libMobileGestalt — it returns error 6 and corrupts the
                // function → crash. Only a PAC-aware hooker (ElleKit) can inline-hook here.
                if (gUseSubstituteMG) miosInstallMGViaSubstitute();
                // NARROW dlsym hook for MGCopyAnswer ONLY. Since MSHookFunction is a no-op on this
                // runtime, this is what actually makes IG's dlsym-resolved telemetry read return the
                // spoofed model. Safe: captured g_real_dlsym avoids recursion, orig_MGpub is a valid
                // real fallback, and we intercept nothing but "MGCopyAnswer". Pass NULL `replaced`
                // so fishhook doesn't overwrite our manually-captured g_real_dlsym.
                if (g_real_dlsym && orig_MGpub) {
                    rebind_symbols((struct rebinding[]){
                        {"dlsym", (void *)mios_dlsym, NULL},
                    }, 1);
                    NSLog(@"[miOS-iso] narrow dlsym(MGCopyAnswer) hook installed");
                }
            }
        }

        // getifaddrs — Wi-Fi + cellular IP spoofing (Blaze fishhooks this too).
        if (spoofBool(@"enableSpoofWiFi") || spoofBool(@"enableSpoofCellular"))
            rebind_symbols((struct rebinding[]){
                {"getifaddrs", (void *)hook_getifaddrs, (void **)&orig_getifaddrs},
            }, 1);

        // ---- HOOK SELF-TEST (always-on NSLog) ----------------------------------------------
        // Decisive check of whether MSHookFunction actually works on this sideload runtime.
        // We call the hooked C functions ourselves: if our inline hooks installed, these return
        // the SPOOFED values; if MSHookFunction is a no-op here, they return the REAL device.
        // Also tests the ObjC %hook path via UIDevice. Filter Console by "miOS-iso".
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                char machine[96] = {0}; size_t ms = sizeof(machine);
                sysctlbyname("hw.machine", machine, &ms, NULL, 0);
                NSString *wantModel = spoofStr(@"deviceIdentifier");
                NSLog(@"[miOS-iso] SELFTEST sysctlbyname hw.machine=%s  want=%@  (C-hook %@)",
                      machine, wantModel.length ? wantModel : @"(n/a)",
                      (wantModel.length && strcmp(machine, wantModel.UTF8String) == 0) ? @"WORKS" : @"NOT firing");
                // Array-form sysctl({CTL_HW, HW_MACHINE}) — the other sysctl path IG may use.
                char amch[96] = {0}; size_t aml = sizeof(amch);
                int mib[2] = { CTL_HW, HW_MACHINE };
                sysctl(mib, 2, amch, &aml, NULL, 0);
                NSLog(@"[miOS-iso] SELFTEST sysctl[CTL_HW,HW_MACHINE]=%s  (array-form C-hook %@)",
                      amch, (wantModel.length && strcmp(amch, wantModel.UTF8String) == 0) ? @"WORKS" : @"NOT firing");
                // HONEST MGCopyAnswer test: call OUR replacement directly. This is exactly what
                // IG sees, because fishhook rebinds the MGCopyAnswer import in every image to
                // mios_MGCopyAnswer. (Calling via dlsym would resolve the REAL function address
                // and bypass fishhook, so it always shows the real device — useless as a test.)
                CFTypeRef pt = mios_MGCopyAnswer(CFSTR("ProductType"));
                CFTypeRef pv = mios_MGCopyAnswer(CFSTR("ProductVersion"));
                NSLog(@"[miOS-iso] SELFTEST MGCopyAnswer(ours) ProductType=%@ ProductVersion=%@  want model=%@ ios=%@",
                      (__bridge id)pt, (__bridge id)pv, spoofStr(@"deviceIdentifier"), spoofStr(@"iosVersion"));
                if (pt) CFRelease(pt);
                if (pv) CFRelease(pv);
                // DECISIVE: dlsym("MGCopyAnswer") now goes through our NARROW dlsym hook, so this
                // must return SPOOFED — proving IG's dlsym-based telemetry device reads are spoofed.
                void *mg = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
                CFTypeRef(*mgfn)(CFStringRef) = mg ? (CFTypeRef(*)(CFStringRef))dlsym(mg, "MGCopyAnswer") : NULL;
                if (mgfn) {
                    CFTypeRef rpt = mgfn(CFSTR("ProductType"));
                    NSLog(@"[miOS-iso] SELFTEST MGCopyAnswer(via dlsym) ProductType=%@  (dlsym-hook %@)",
                          (__bridge id)rpt,
                          (wantModel.length && [(__bridge id)rpt isEqual:wantModel]) ? @"WORKS — dlsym spoofed" : @"NOT firing — still real");
                    if (rpt) CFRelease(rpt);
                }
                // (No raw MGCopyAnswerWithError probe — its iOS 18 ABI isn't the simple 2-arg form
                // we assumed, and calling it directly crashed. The internal hook covers it; the
                // MGCopyAnswer(via dlsym) line above already reflects whether the spoof reaches it.)
                NSLog(@"[miOS-iso] SELFTEST UIDevice.systemVersion=%@ model=%@ (ObjC-hook path; enableSpoofSW=%d ios=%@)",
                      [UIDevice currentDevice].systemVersion, [UIDevice currentDevice].model,
                      (int)spoofBool(@"enableSpoofSoftwareVersion"), spoofStr(@"iosVersion"));
            } @catch (__unused id e) {}
        });

        miosLog(@"ctor complete — all hooks installed (deviceSpoof=%d)", (int)gDeviceSpoofActive);
    }
}
