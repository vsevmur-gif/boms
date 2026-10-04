#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <SafariServices/SafariServices.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
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
#import <math.h>
#import <fcntl.h>
#import <unistd.h>
#import <time.h>
#import <pthread.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <mach/mach.h>
#import <uuid/uuid.h>
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

// DeviceCheck (DCDevice). Hooked per-container (enableSpoofDeviceCheck) so each container does not
// hand Apple's hardware-attested device token to the app — otherwise every container on one phone
// attests as the same physical device. Declared here (DeviceCheck.framework is resolved at runtime).
@interface DCDevice : NSObject
+ (instancetype)currentDevice;
+ (BOOL)isSupported;
- (void)generateTokenWithCompletionHandler:(void (^)(NSData *token, NSError *error))completion;
@end
@interface DCAppAttestService : NSObject
+ (instancetype)sharedService;
@property (readonly, getter=isSupported) BOOL supported;
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))completion;
- (void)attestKey:(NSString *)keyId clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *attestation, NSError *error))completion;
- (void)generateAssertion:(NSString *)keyId clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *assertion, NSError *error))completion;
@end

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

// IGUserAgent — the Swift singleton (_TtC11IGUserAgent11IGUserAgent) that builds Instagram's
// User-Agent (device part "(iPhone17,1; iOS 18_5; Scale/3.00)"). It caches lazily, so if it built
// its UA before our device hooks were up (or from a +load before our ctor) the real model stays in
// the UA that registers the login session — which is what the Accounts Center page shows. Rewriting
// the returned string here is timing-independent.
@interface _TtC11IGUserAgent11IGUserAgent : NSObject
- (NSString *)userAgent;
- (NSString *)sanitizedUserAgent;
- (NSString *)customUserAgent;
@end

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

// AVCaptureSession, AVCapturePhoto, AVCapturePhotoOutput provided by AVFoundation.h

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
static uint32_t  gcCPUFamily = 0;         // hw.cpufamily (0 = pass through real value)
static char     *gcKernelVersion = NULL;  // uname.release-style + full kern.version

// hw.optional.arm.FEAT_* overrides. IG reads ~18 of these as part of its device fingerprint;
// they must stay consistent with the spoofed SoC. CRASH-SAFE INVARIANT: we never report a
// feature as PRESENT unless the real CPU also has it (some libraries use these to pick
// instructions; claiming a missing feature → SIGILL). So the effective value is
// (requested && real): features can be HIDDEN to match an older target, never synthesized.
typedef struct { char *name; int value; } MiOSFeatOverride;
static MiOSFeatOverride *gcFeatOverrides = NULL;
static size_t gcFeatOverrideCount = 0;

// Screen fingerprint. IG sends media_layout_screen_width/height/density (real native pixels),
// which must match the spoofed model or the server sees model/resolution mismatch. We spoof ONLY
// UIScreen.nativeBounds (pixels) and .nativeScale (density) — NEVER -bounds (points) or -scale,
// which drive UI layout and would break/crash rendering if lied about. 0 = pass through.
static CGFloat gcScreenW = 0, gcScreenH = 0;   // native pixels, portrait
static CGFloat gcScreenNativeScale = 0;

// Startup timing — to test whether IG reads/caches the device model before our hooks install.
static uint64_t gT0 = 0;   // set at the very start of the ctor
static double miosMsSinceStart(void) {
    if (!gT0) return -1;
    static double scale = 0;
    if (scale == 0) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); scale = (double)tb.numer / tb.denom / 1e6; }
    return (double)(mach_absolute_time() - gT0) * scale;
}
static CFDictionaryRef gcWifiInfo     = NULL;
static CFStringRef gcMGProductType    = NULL;
static CFStringRef gcMGHWModel        = NULL;
static CFStringRef gcMGDeviceName     = NULL;
static CFStringRef gcMGProductVersion = NULL;
static CFStringRef gcMGDeviceClass    = NULL;   // "iPhone"/"iPad"/"iPod touch"

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
// EARLY identity hooks are in %group EarlyIdentity (initialized first in %ctor, before FS/keychain).

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
// MARK: - EarlyIdentity group — initialized FIRST in %ctor, before FS/keychain/App-Group,
// so Instagram cannot cache real values from +load or early initializers.
%group EarlyIdentity
%hook UIDevice
- (NSString *)systemVersion {
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
- (NSString *)localizedModel {
    if (spoofBool(@"enableSpoofDeviceModel")) {
        NSString *ident = spoofStr(@"deviceIdentifier");
        if ([ident hasPrefix:@"iPad"]) return @"iPad";
        if ([ident hasPrefix:@"iPod"]) return @"iPod touch";
        if ([ident hasPrefix:@"iPhone"]) return @"iPhone";
    }
    return %orig;
}
- (NSUUID *)identifierForVendor {
    if (spoofBool(@"enableSpoofVendorID")) {
        NSString *v = spoofStr(@"vendorID");
        NSUUID *u = v.length ? [[NSUUID alloc] initWithUUIDString:v] : nil;
        if (u) return u;
    }
    return %orig;
}
- (id)_deviceInfoForKey:(NSString *)key {
    if (gDeviceSpoofActive && [key isKindOfClass:[NSString class]]) {
        if (gcMachine && ([key isEqualToString:@"HWModelStr"] || [key isEqualToString:@"ProductType"] ||
                          [key isEqualToString:@"machine"]))
            return [NSString stringWithUTF8String:gcMachine];
        if (gcMGDeviceName && ([key isEqualToString:@"marketing-name"] || [key isEqualToString:@"DeviceName"] ||
                               [key isEqualToString:@"UserAssignedDeviceName"]))
            return (__bridge NSString *)gcMGDeviceName;
    }
    return %orig;
}
+ (NSString *)machineName {
    if (gDeviceSpoofActive && gcMachine) return [NSString stringWithUTF8String:gcMachine];
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

%hook UIScreen
- (CGRect)nativeBounds {
    if (gcScreenW > 0 && gcScreenH > 0) return CGRectMake(0, 0, gcScreenW, gcScreenH);
    return %orig;
}
- (CGFloat)nativeScale {
    if (gcScreenNativeScale > 0) return gcScreenNativeScale;
    return %orig;
}
%end
%hook DCDevice
+ (BOOL)isSupported {
    BOOL on = spoofBool(@"enableSpoofDeviceCheck");
    if (on) return NO;
    return %orig;
}
- (void)generateTokenWithCompletionHandler:(void (^)(NSData *token, NSError *error))completion {
    if (spoofBool(@"enableSpoofDeviceCheck")) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"com.apple.devicecheck.error" code:1
                                           userInfo:@{NSLocalizedDescriptionKey: @"DeviceCheck unavailable"}];
            completion(nil, err);
        }
        return;
    }
    %orig;
}
%end
%hook DCAppAttestService
- (BOOL)isSupported {
    if (spoofBool(@"enableSpoofDeviceCheck")) return NO;
    return %orig;
}
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))completion {
    if (spoofBool(@"enableSpoofDeviceCheck")) {
        if (completion) completion(nil, [NSError errorWithDomain:@"com.apple.devicecheck.error" code:2
                                       userInfo:@{NSLocalizedDescriptionKey: @"App Attest unavailable"}]);
        return;
    }
    %orig;
}
- (void)attestKey:(NSString *)keyId clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *attestation, NSError *error))completion {
    if (spoofBool(@"enableSpoofDeviceCheck")) {
        if (completion) completion(nil, [NSError errorWithDomain:@"com.apple.devicecheck.error" code:3
                                       userInfo:@{NSLocalizedDescriptionKey: @"App Attest unavailable"}]);
        return;
    }
    %orig;
}
- (void)generateAssertion:(NSString *)keyId clientDataHash:(NSData *)hash completionHandler:(void (^)(NSData *assertion, NSError *error))completion {
    if (spoofBool(@"enableSpoofDeviceCheck")) {
        if (completion) completion(nil, [NSError errorWithDomain:@"com.apple.devicecheck.error" code:4
                                       userInfo:@{NSLocalizedDescriptionKey: @"App Attest unavailable"}]);
        return;
    }
    %orig;
}
%end
%end
// end EarlyIdentity

// MARK: - Facebook Family Device ID — prevents Meta from linking containers via a shared device ID
%hook FBFamilyDeviceIDReportInternal
- (NSString *)deviceID {
    if (gDeviceSpoofActive && spoofBool(@"enableSpoofVendorID")) {
        NSString *v = spoofStr(@"vendorID");
        if (v.length) return v;
    }
    return %orig;
}
- (NSString *)reportDeviceID {
    if (gDeviceSpoofActive && spoofBool(@"enableSpoofVendorID")) {
        NSString *v = spoofStr(@"vendorID");
        if (v.length) return v;
    }
    return %orig;
}
%end
%hook FBFamilyIDDeviceIsJailbroken
+ (BOOL)isJailbroken { return NO; }
+ (BOOL)isDeviceJailbroken { return NO; }
- (BOOL)isJailbroken { return NO; }
%end
%hook GADMobileAds
- (BOOL)disableAfmaIdfaCollection {
    if (spoofBool(@"enableSpoofAdvertisingID")) return YES;
    return %orig;
}
%end

// MARK: - Background Task Blocker — prevents Instagram background telemetry
%group BackgroundBlocker
%hook UIApplication
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithExpirationHandler:(void (^)(void))handler {
    NSLog(@"[miOS-bg] Background task prevented (no name)");
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
    return UIBackgroundTaskInvalid;
}
- (UIBackgroundTaskIdentifier)beginBackgroundTaskWithName:(NSString *)name expirationHandler:(void (^)(void))handler {
    NSLog(@"[miOS-bg] Background task prevented: %@", name);
    if (handler) {
        dispatch_async(dispatch_get_main_queue(), handler);
    }
    return UIBackgroundTaskInvalid;
}
%end
%end

// MARK: - Camera Hooker — allows photo substitution from gallery for selfie verification
static NSData *gCachedPhotoData = nil;
static BOOL gCameraHookerEnabled = NO;

%group CameraHooker
%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (gCameraHookerEnabled && gCachedPhotoData) {
        NSLog(@"[miOS-cam] Using cached photo instead of camera capture");
        if ([delegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
            __weak AVCapturePhotoOutput *weakSelf = (AVCapturePhotoOutput *)self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
                [delegate captureOutput:weakSelf didFinishProcessingPhoto:nil error:nil];
#pragma clang diagnostic pop
            });
        }
        return;
    }
    %orig;
}
%end
%end

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

// MARK: - Identifiers (IDFV / IDFA / DeviceCheck moved to %group EarlyIdentity above)

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

// Token-dumper: capture Authorization / MID / WWW-Claim / DS-USER-ID headers from
// Instagram's live API traffic and persist them under the active container's root. The
// MiOS UI reads this snapshot via -[MiOSContainer extractIAMToken] for the Extract Token
// action. We only save when values actually change to keep writes rare.
static NSMutableDictionary<NSString *, NSString *> *gLastCapturedIGHeaders = nil;
static NSTimeInterval gLastCapturedIGSave = 0;
static void miosCaptureIGHeaders(NSURLRequest *req) {
    @try {
        if (!req) return;
        NSString *host = req.URL.host.lowercaseString;
        if (!host.length) return;
        // Instagram API hosts only — avoids spam from third-party SDKs / Meta Analytics.
        if (!([host hasSuffix:@"instagram.com"] || [host hasSuffix:@"cdninstagram.com"] ||
              [host containsString:@"i.instagram.com"] || [host containsString:@"b.i.instagram.com"] ||
              [host containsString:@"graph.instagram.com"])) return;

        NSDictionary *hdrs = req.allHTTPHeaderFields;
        if (!hdrs.count) return;

        static NSArray *keys = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            keys = @[@"Authorization", @"IG-U-DS-USER-ID", @"X-IG-DS-USER-ID",
                     @"X-MID", @"X-IG-WWW-Claim", @"X-IG-Device-ID",
                     @"User-Agent", @"IG-U-IG-DIRECT-REGION-HINT",
                     @"X-IG-Family-Device-ID", @"X-Bloks-Version-Id"];
        });

        if (!gLastCapturedIGHeaders) gLastCapturedIGHeaders = [NSMutableDictionary dictionary];
        BOOL changed = NO;
        for (NSString *k in keys) {
            NSString *v = hdrs[k];
            if (![v isKindOfClass:[NSString class]] || !v.length) continue;
            NSString *cur = gLastCapturedIGHeaders[k];
            if (![cur isEqualToString:v]) {
                gLastCapturedIGHeaders[k] = v;
                changed = YES;
            }
        }
        if (!changed) return;

        // Throttle disk writes to once every 10s even if things keep changing.
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - gLastCapturedIGSave < 10.0) return;
        gLastCapturedIGSave = now;

        NSString *cid = gContainerUUID;
        if (!cid.length) return;
        NSDictionary *snapshot = [gLastCapturedIGHeaders copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [MiOSContainer recordIGHeaders:snapshot forContainerID:cid];
        });
    } @catch (__unused id e) {}
}

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    miosLogReq(@"data", request); miosCaptureIGHeaders(request); return %orig;
}
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    miosLogReq(@"data+cb", request); miosCaptureIGHeaders(request); return %orig;
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData {
    miosLogReq(@"upload", request); miosCaptureIGHeaders(request); return %orig(request, miosRewriteHTTPBody(bodyData));
}
- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)bodyData completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))h {
    miosLogReq(@"upload+cb", request); miosCaptureIGHeaders(request); return %orig(request, miosRewriteHTTPBody(bodyData), h);
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

// --- Keychain diagnostics (aimed at IG's device header / FB_FINGERPRINT) ------------------------
// kcModify isolates a keychain item ONLY when it carries kSecAttrService. If IG stores its device
// header keyed by account / server / label with NO service, our namespace never touches it and
// every container shares ONE header (the "same device across containers" symptom). These logs
// show, per call, how each item is keyed and whether it is actually isolated. Always-on but
// capped, so it is visible in Console / idevicesyslog without a MIOS_DIAG rebuild. Filter by
// "miOS-kc".
static BOOL miosStrDeviceish(id s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSString *l = [(NSString *)s lowercaseString];
    for (NSString *needle in @[@"device", @"header", @"fingerprint", @"pigeon", @"familydevice",
                               @"waterfall", @"bedrock", @"machineid", @"deviceid", @"device_id", @"mid"])
        if ([l containsString:needle]) return YES;
    return NO;
}
static void miosLogSecItem(const char *op, CFDictionaryRef dict) {
    static int n = 0; if (n >= 400) return; n++;
    @try {
        NSDictionary *d = dict ? (__bridge NSDictionary *)dict : @{};
        id svc = d[(__bridge id)kSecAttrService], acct = d[(__bridge id)kSecAttrAccount];
        id srv = d[(__bridge id)kSecAttrServer],  grp  = d[(__bridge id)kSecAttrAccessGroup];
        id lbl = d[(__bridge id)kSecAttrLabel],   cls  = d[(__bridge id)kSecClass];
        BOOL hasSvc = [svc isKindOfClass:[NSString class]] && [(NSString *)svc length] > 0;
        BOOL deviceish = miosStrDeviceish(svc) || miosStrDeviceish(acct) ||
                         miosStrDeviceish(srv) || miosStrDeviceish(lbl);
        NSLog(@"[miOS-kc] %s class=%@ service=%@ acct=%@ server=%@ grp=%@ label=%@ isolated=%@%@",
              op, cls, svc, acct, srv, grp, lbl,
              hasSvc ? @"YES(service-keyed)" : @"NO(not service-keyed -> SHARED across containers)",
              deviceish ? @"  <== DEVICE-HEADER-LIKE" : @"");
    } @catch (__unused id e) {}
}

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
    if ([svc isKindOfClass:[NSString class]] && [(NSString *)svc length] > 0) {
        if (![(NSString *)svc hasPrefix:gKcPrefix])
            m[(__bridge id)kSecAttrService] = [gKcPrefix stringByAppendingString:(NSString *)svc];
    } else {
        // No service to namespace by — e.g. the shared Family Device ID, a genp item keyed ONLY by
        // access group group.com.facebook.family (service/account/server all null). Without this it
        // is the SAME item in every container, so every container reports the same device id (and
        // the Bloks GetFamilyDeviceId/FetchDeviceID the Accounts Center WebView reads returns it).
        // Inject a per-container service so each container gets its own copy; applied identically on
        // add/copy/update/delete, so the item stays findable within the container and isolated
        // across containers. The old shared item is simply never matched again.
        NSString *ns = [gKcPrefix stringByAppendingString:@"__noservice__"];
        m[(__bridge id)kSecAttrService] = ns;
        static int lg = 0;
        if (lg < 40) { lg++;
            NSLog(@"[miOS-kc] NAMESPACED serviceless item grp=%@ -> service=%@ (now container-private)",
                  m[(__bridge id)kSecAttrAccessGroup], ns); }
    }
    return m;
}
static OSStatus new_SecItemAdd(CFDictionaryRef a, CFTypeRef *r) {
    miosLogSecItem("ADD ", a);
    if (gKcPrefix.length == 0) return orig_SecItemAdd(a, r);
    return orig_SecItemAdd((__bridge CFDictionaryRef)kcModify(a), r);
}
static OSStatus new_SecItemCopyMatching(CFDictionaryRef q, CFTypeRef *r) {
    miosLogSecItem("COPY", q);
    if (gKcPrefix.length == 0) return orig_SecItemCopyMatching(q, r);
    return orig_SecItemCopyMatching((__bridge CFDictionaryRef)kcModify(q), r);
}
static OSStatus new_SecItemUpdate(CFDictionaryRef q, CFDictionaryRef u) {
    miosLogSecItem("UPD ", q);
    if (gKcPrefix.length == 0) return orig_SecItemUpdate(q, u);
    return orig_SecItemUpdate((__bridge CFDictionaryRef)kcModify(q), u);
}
static OSStatus new_SecItemDelete(CFDictionaryRef q) {
    miosLogSecItem("DEL ", q);
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

// One-shot dump of device-header-like keychain items, WITH their stored value and whether each one
// lives in THIS container's namespace (service carries our prefix) or in the shared, un-prefixed
// keychain. Reads raw via the ORIGINAL SecItem. Only items whose service/account/label look
// device-related are printed, so login tokens are not dumped. This is the decisive answer to "is
// the device header shared across containers?": if a device-header item prints
// namespace=SHARED/un-prefixed, every container reads the same one. Filter Console by "miOS-kc".
static void miosProbeDeviceHeaders(void) {
    if (!orig_SecItemCopyMatching) return;
    for (id cls in @[(__bridge id)kSecClassGenericPassword, (__bridge id)kSecClassInternetPassword]) {
        NSDictionary *q = @{ (__bridge id)kSecClass:              cls,
                             (__bridge id)kSecMatchLimit:         (__bridge id)kSecMatchLimitAll,
                             (__bridge id)kSecReturnAttributes:   @YES,
                             (__bridge id)kSecReturnData:         @YES,
                             (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny };
        CFTypeRef res = NULL;
        if (orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, &res) != errSecSuccess || !res) {
            if (res) CFRelease(res);
            continue;
        }
        NSArray *items = (__bridge_transfer NSArray *)res;
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            id svc = it[(__bridge id)kSecAttrService], acct = it[(__bridge id)kSecAttrAccount];
            id lbl = it[(__bridge id)kSecAttrLabel];
            if (!(miosStrDeviceish(svc) || miosStrDeviceish(acct) || miosStrDeviceish(lbl))) continue;
            BOOL isSvcStr = [svc isKindOfClass:[NSString class]];
            BOOL isolated = isSvcStr && gKcPrefix.length && [(NSString *)svc hasPrefix:gKcPrefix];
            // An item prefixed with __mios_<other-uuid>_ belongs to ANOTHER container — it is
            // isolated, just not this one's. Only a service with NO __mios_ prefix is truly shared.
            BOOL otherContainer = isSvcStr && !isolated && [(NSString *)svc hasPrefix:@"__mios_"];
            NSString *nsLabel = isolated ? @"THIS-container(prefixed)"
                              : otherContainer ? @"OTHER-container(isolated)"
                              : @"TRULY-SHARED(no __mios_ prefix)";
            id val = it[(__bridge id)kSecValueData];
            NSString *vs = nil;
            if ([val isKindOfClass:[NSData class]]) {
                NSData *dv = val;
                vs = [[NSString alloc] initWithData:dv encoding:NSUTF8StringEncoding];
                if (!vs) vs = [NSString stringWithFormat:@"<%lu bytes, hex head=%@>",
                               (unsigned long)dv.length,
                               [dv subdataWithRange:NSMakeRange(0, MIN((NSUInteger)24, dv.length))]];
                if (vs.length > 300) vs = [[vs substringToIndex:300] stringByAppendingString:@"…"];
            }
            NSLog(@"[miOS-kc] DEVICE-HEADER item service=%@ acct=%@ label=%@ namespace=%@ value=%@",
                  svc, acct, lbl, nsLabel, vs);
        }
    }
    NSLog(@"[miOS-kc] device-header probe complete (kcPrefix=%@)", gKcPrefix);
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

// _dyld_get_image_header: hide our dylib from image enumeration (anti-detection)
static const struct mach_header *(*orig_dyld_get_image_header)(uint32_t) = NULL;
static const char *(*orig_dyld_get_image_name)(uint32_t) = NULL;
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t) = NULL;
static uint32_t (*orig_dyld_image_count)(void) = NULL;

static BOOL miosIsMiOSImage(uint32_t idx) {
    const char *name = orig_dyld_get_image_name ? orig_dyld_get_image_name(idx) : _dyld_get_image_name(idx);
    if (!name) return NO;
    return (strstr(name, "miOS") != NULL || strstr(name, "nomix") != NULL ||
            strstr(name, "CydiaSubstrate") != NULL || strstr(name, "substrate") != NULL);
}
static uint32_t hook_dyld_image_count(void) {
    uint32_t real = orig_dyld_image_count();
    uint32_t hidden = 0;
    for (uint32_t i = 0; i < real; i++)
        if (miosIsMiOSImage(i)) hidden++;
    return real - hidden;
}
static uint32_t miosTranslateImageIndex(uint32_t idx) {
    uint32_t real = orig_dyld_image_count();
    uint32_t visible = 0;
    for (uint32_t i = 0; i < real; i++) {
        if (miosIsMiOSImage(i)) continue;
        if (visible == idx) return i;
        visible++;
    }
    return idx;
}
static const struct mach_header *hook_dyld_get_image_header(uint32_t idx) {
    return orig_dyld_get_image_header(miosTranslateImageIndex(idx));
}
static const char *hook_dyld_get_image_name_fn(uint32_t idx) {
    return orig_dyld_get_image_name(miosTranslateImageIndex(idx));
}
static intptr_t hook_dyld_get_image_vmaddr_slide(uint32_t idx) {
    return orig_dyld_get_image_vmaddr_slide(miosTranslateImageIndex(idx));
}

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
// Reply a 32-bit int, honoring the size-probe convention (oldp==NULL asks only for the length).
// hw.cpufamily and hw.optional.* are all 32-bit ints.
static int replyU32(void *oldp, size_t *oldlenp, uint32_t value) {
    if (!oldp) { if (oldlenp) *oldlenp = sizeof(uint32_t); return 0; }
    if (oldlenp && *oldlenp < sizeof(uint32_t)) { errno = ENOMEM; return -1; }
    *(uint32_t *)oldp = value; if (oldlenp) *oldlenp = sizeof(uint32_t); return 0;
}
static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (name && strcmp(name, "hw.machine") == 0) {
        static int tlog = 0;
        if (tlog < 16) { tlog++;
            NSLog(@"[miOS-time] sysctl hw.machine @%.0fms spoofActive=%d (hook up)",
                  miosMsSinceStart(), (int)gDeviceSpoofActive); }
    }
    if (name && gDeviceSpoofActive) {
        if (gcMachine && strcmp(name, "hw.machine") == 0) return replyCString(oldp, oldlenp, gcMachine);
        if (gcModel   && strcmp(name, "hw.model")   == 0) return replyCString(oldp, oldlenp, gcModel);
        if (gcKernelVersion && (strcmp(name, "kern.version") == 0 || strcmp(name, "kern.osrelease") == 0))
            return replyCString(oldp, oldlenp, gcKernelVersion);
        // hw.cpufamily — must match the spoofed SoC, or ProductType (e.g. iPhone15,2/A16) contradicts
        // a real-CPU cpufamily. Pure fingerprint int, no instruction-selection impact → safe to force.
        if (gcCPUFamily && strcmp(name, "hw.cpufamily") == 0)
            return replyU32(oldp, oldlenp, gcCPUFamily);
        // hw.optional.arm.FEAT_* — precomputed crash-safe overrides (requested && real). Keys we have
        // no override for fall through to the real value below.
        if (gcFeatOverrideCount && strncmp(name, "hw.optional.arm.FEAT_", 21) == 0) {
            for (size_t i = 0; i < gcFeatOverrideCount; i++)
                if (strcmp(name, gcFeatOverrides[i].name) == 0)
                    return replyU32(oldp, oldlenp, (uint32_t)gcFeatOverrides[i].value);
        }
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

// MARK: - MobileGestalt (MGCopyAnswer) — SAFE fishhook import rebind only
//
// The model IG shows in-app (and sends as device info) is the MobileGestalt marketing-name /
// ProductType, NOT hw.machine — so spoofing sysctl alone leaves the real "iPhone 16 Pro" on
// screen. We re-bind the MGCopyAnswer IMPORT (a plain pointer-table rewrite, no code patching, no
// PAC, no dlsym) so linked callers — which is how IG resolves it — get the spoofed value. This is
// the safe mechanism; the process-wide dlsym("MGCopyAnswer") rebind that crashed arm64e/iOS 18 and
// the Substitute inline hook are intentionally NOT reinstated.
static CFTypeRef (*orig_MGCopyAnswer)(CFStringRef) = NULL;
static CFTypeRef mios_MGCopyAnswer(CFStringRef key) {
    if (key) {
        static int tlog = 0;
        if (tlog < 16 && (CFEqual(key, CFSTR("ProductType")) || CFEqual(key, CFSTR("marketing-name")) ||
                          CFEqual(key, CFSTR("ProductVersion")))) {
            tlog++;
            NSLog(@"[miOS-time] MGCopyAnswer(%@) @%.0fms spoofActive=%d (hook up)",
                  (__bridge NSString *)key, miosMsSinceStart(), (int)gDeviceSpoofActive);
        }
    }
    if (gDeviceSpoofActive && key) {
        if (gcMGProductType && CFEqual(key, CFSTR("ProductType")))      return CFRetain(gcMGProductType);
        if (gcMGProductVersion && CFEqual(key, CFSTR("ProductVersion"))) return CFRetain(gcMGProductVersion);
        if (gcMGHWModel && (CFEqual(key, CFSTR("HWModelStr")) || CFEqual(key, CFSTR("HardwarePlatform"))))
            return CFRetain(gcMGHWModel);
        if (gcMGDeviceName && (CFEqual(key, CFSTR("marketing-name")) ||
                               CFEqual(key, CFSTR("DeviceName")) ||
                               CFEqual(key, CFSTR("UserAssignedDeviceName"))))
            return CFRetain(gcMGDeviceName);
        if (gcMGDeviceClass && CFEqual(key, CFSTR("DeviceClass")))     return CFRetain(gcMGDeviceClass);
    }
    return orig_MGCopyAnswer ? orig_MGCopyAnswer(key) : NULL;
}

// MGCopyAnswer_internal — the internal version called directly by some system frameworks,
// bypassing the public MGCopyAnswer wrapper. Nomix hooks this for deeper coverage.
static CFTypeRef (*orig_MGCopyAnswer_internal)(CFStringRef, CFDictionaryRef) = NULL;
static CFTypeRef mios_MGCopyAnswer_internal(CFStringRef key, CFDictionaryRef options) {
    if (gDeviceSpoofActive && key) {
        if (gcMGProductType && CFEqual(key, CFSTR("ProductType")))      return CFRetain(gcMGProductType);
        if (gcMGProductVersion && CFEqual(key, CFSTR("ProductVersion"))) return CFRetain(gcMGProductVersion);
        if (gcMGHWModel && (CFEqual(key, CFSTR("HWModelStr")) || CFEqual(key, CFSTR("HardwarePlatform"))))
            return CFRetain(gcMGHWModel);
        if (gcMGDeviceName && (CFEqual(key, CFSTR("marketing-name")) ||
                               CFEqual(key, CFSTR("DeviceName")) ||
                               CFEqual(key, CFSTR("UserAssignedDeviceName"))))
            return CFRetain(gcMGDeviceName);
        if (gcMGDeviceClass && CFEqual(key, CFSTR("DeviceClass")))     return CFRetain(gcMGDeviceClass);
    }
    return orig_MGCopyAnswer_internal ? orig_MGCopyAnswer_internal(key, options) : NULL;
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


// MARK: - Full per-container isolation of the remaining identity channels
//
// Native model reads are spoofed, but the device IDENTITY (family/device id) can still be read from
// stores the NSUserDefaults/Keychain/FS isolation does not cover. To make every container look like a
// completely distinct device, isolate the rest too: CFPreferences (C API — bypasses the
// NSUserDefaults ObjC hook), the iCloud key-value store, gethostuuid(), and IORegistry
// (IOPlatformUUID/serial). Scoped so genuine system domains (com.apple.*, .GlobalPreferences,
// AnyApplication) pass through untouched; the app's own domain and Meta/group domains are backed by
// the per-container store, and the two hardware ids are replaced with a deterministic per-container
// value. Filter Console by "miOS-id".
static CFPropertyListRef (*orig_CFPrefCopyAppValue)(CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPrefSetAppValue)(CFStringRef, CFPropertyListRef, CFStringRef) = NULL;
static CFPropertyListRef (*orig_CFPrefCopyValue)(CFStringRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static void (*orig_CFPrefSetValue)(CFStringRef, CFPropertyListRef, CFStringRef, CFStringRef, CFStringRef) = NULL;
static Boolean (*orig_CFPrefAppSync)(CFStringRef) = NULL;
static int (*orig_gethostuuid)(uuid_t, const struct timespec *) = NULL;
static CFTypeRef (*orig_IORegCreateCFProp)(mach_port_t, CFStringRef, CFAllocatorRef, uint32_t) = NULL;

// Deterministic 16 bytes derived from the container id — stable across launches, unique per container.
static void miosContainerUUIDBytes(uuid_t out) {
    const char *s = gContainerUUID.length ? gContainerUUID.UTF8String : "mios-default";
    uint64_t h1 = 1469598103934665603ULL, h2 = 0x9e3779b97f4a7c15ULL;
    for (const char *p = s; *p; p++) { h1 ^= (unsigned char)*p; h1 *= 1099511628211ULL; }
    for (const char *p = s; *p; p++) { h2 ^= (unsigned char)*p; h2 *= 1099511628211ULL; }
    memcpy(out, &h1, 8); memcpy(out + 8, &h2, 8);
    out[6] = (out[6] & 0x0F) | 0x40;   // UUID v4 marker
    out[8] = (out[8] & 0x3F) | 0x80;
}
static NSString *miosContainerUUIDString(void) {
    uuid_t u; miosContainerUUIDBytes(u); uuid_string_t s; uuid_unparse_upper(u, s);
    return [NSString stringWithUTF8String:s];
}
static NSString *miosContainerSerial(void) {
    uuid_t u; miosContainerUUIDBytes(u);
    static const char *abc = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
    char s[13]; for (int i = 0; i < 12; i++) s[i] = abc[u[i] % 34]; s[12] = 0;
    return [NSString stringWithUTF8String:s];
}
// Isolate the app's own prefs domain + Meta/group domains; pass genuine system domains through.
static BOOL miosPrefsDomainIsolated(CFStringRef appID) {
    if (!appID || gUD == nil) return NO;
    if (appID == kCFPreferencesCurrentApplication) return YES;
    if (appID == kCFPreferencesAnyApplication) return NO;
    NSString *d = (__bridge NSString *)appID;
    if (![d isKindOfClass:[NSString class]] || d.length == 0) return NO;
    NSString *l = d.lowercaseString;
    if ([l hasPrefix:@"com.apple."] || [l isEqualToString:@".globalpreferences"]) return NO;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length && [d isEqualToString:bid]) return YES;
    if ([l containsString:@"facebook"] || [l containsString:@"burbn"] || [l containsString:@"instagram"] ||
        [l containsString:@"meta"] || [l hasPrefix:@"group."]) return YES;
    return NO;   // unknown non-Meta domain → leave alone (don't risk breaking a system read)
}
static CFPropertyListRef hook_CFPrefCopyAppValue(CFStringRef key, CFStringRef appID) {
    if (key && miosPrefsDomainIsolated(appID)) {
        id v = nil;
        if (miosUDLookup((__bridge NSString *)key, &v)) return v ? (CFPropertyListRef)CFBridgingRetain(v) : NULL;
    }
    return orig_CFPrefCopyAppValue ? orig_CFPrefCopyAppValue(key, appID) : NULL;
}
static void hook_CFPrefSetAppValue(CFStringRef key, CFPropertyListRef value, CFStringRef appID) {
    if (key && miosPrefsDomainIsolated(appID)) { miosUDSet((__bridge NSString *)key, (__bridge id)value); return; }
    if (orig_CFPrefSetAppValue) orig_CFPrefSetAppValue(key, value, appID);
}
static CFPropertyListRef hook_CFPrefCopyValue(CFStringRef key, CFStringRef appID, CFStringRef user, CFStringRef host) {
    if (key && miosPrefsDomainIsolated(appID)) {
        id v = nil;
        if (miosUDLookup((__bridge NSString *)key, &v)) return v ? (CFPropertyListRef)CFBridgingRetain(v) : NULL;
    }
    return orig_CFPrefCopyValue ? orig_CFPrefCopyValue(key, appID, user, host) : NULL;
}
static void hook_CFPrefSetValue(CFStringRef key, CFPropertyListRef value, CFStringRef appID, CFStringRef user, CFStringRef host) {
    if (key && miosPrefsDomainIsolated(appID)) { miosUDSet((__bridge NSString *)key, (__bridge id)value); return; }
    if (orig_CFPrefSetValue) orig_CFPrefSetValue(key, value, appID, user, host);
}
static Boolean hook_CFPrefAppSync(CFStringRef appID) {
    if (miosPrefsDomainIsolated(appID)) { miosUDPersist(); return true; }
    return orig_CFPrefAppSync ? orig_CFPrefAppSync(appID) : true;
}
static int hook_gethostuuid(uuid_t uu, const struct timespec *w) {
    if (uu && gContainerUUID.length) {
        miosContainerUUIDBytes(uu);
        static int n = 0; if (n < 2) { n++; NSLog(@"[miOS-id] gethostuuid -> per-container %@", miosContainerUUIDString()); }
        return 0;
    }
    return orig_gethostuuid ? orig_gethostuuid(uu, w) : -1;
}
static CFTypeRef hook_IORegCreateCFProp(mach_port_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t opts) {
    if (key && gContainerUUID.length) {
        NSString *k = (__bridge NSString *)key;
        if ([k isEqualToString:@"IOPlatformUUID"])         return (CFTypeRef)CFBridgingRetain(miosContainerUUIDString());
        if ([k isEqualToString:@"IOPlatformSerialNumber"]) return (CFTypeRef)CFBridgingRetain(miosContainerSerial());
    }
    return orig_IORegCreateCFProp ? orig_IORegCreateCFProp(entry, key, alloc, opts) : NULL;
}
%hook NSUbiquitousKeyValueStore
- (id)objectForKey:(NSString *)key {
    id v = nil; if (gUD && miosUDLookup(key, &v)) return v;   // isolate iCloud KVS into the container
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
- (NSString *)stringForKey:(NSString *)key {
    id v = nil; if (gUD && miosUDLookup(key, &v)) return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
    return %orig;
}
%end

// MARK: - Per-container HTTPS proxy (NSURLSessionConfiguration)

// group ProxyHooks
static NSString *miosRewriteUA(NSString *ua);   // defined with the request hooks below
%hook NSURLSessionConfiguration
- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    if (gDeviceSpoofActive && [headers isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [headers mutableCopy];
        for (id k in headers) {
            if ([k isKindOfClass:[NSString class]] && [k caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
                m[k] = miosRewriteUA(headers[k]);
        }
        %orig(m);
        return;
    }
    %orig;
}
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

// MARK: - WebView (Accounts Center / In-App-Browser) device spoof
//
// Instagram's Accounts Center ("Where you're logged in") is a Meta web page (accountscenter.meta.com)
// loaded in a WKWebView. WebKit renders it in a SEPARATE process (com.apple.WebKit.WebContent) that
// our native sysctl/MGCopyAnswer/UIScreen hooks never reach, so the page reads the REAL device via
// navigator.userAgent, navigator.hardwareConcurrency, screen.* and devicePixelRatio (IG also pulls
// navigator.userAgent back over a JS bridge). We inject a documentStart WKUserScript — evaluated in
// the content process before the page's own scripts — that overrides exactly those signals to match
// the spoofed device. Only properties that real iOS Safari actually exposes are touched (no
// navigator.deviceMemory — Safari lacks it, so adding it would itself be a tell), and window.inner*
// is left alone so page layout is not disturbed.
// Rewrite a WebKit-style UA string. WebKit UA looks like:
//   Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 ...
// Unlike IG's own UA, it does NOT contain the hw.machine (iPhone17,1), so miosRewriteUA's
// machine-name replacement misses it. This function handles the "iPhone OS XX_Y" pattern
// and the "Version/XX.Y" pattern that WebKit uses.
static NSString *miosRewriteWebKitUA(NSString *ua) {
    if (!gDeviceSpoofActive || ![ua isKindOfClass:[NSString class]] || ua.length == 0) return ua;
    NSString *out = ua;
    // Also apply the standard IG-style rewrite (machine name, iOS version in dotted form)
    out = miosRewriteUA(out);
    // WebKit uses "iPhone OS 18_2" (underscored) — miosRewriteUA already handles the underscore
    // form, but only if gRealIOSNS is set. Double-check by also doing a regex replacement.
    if (spoofBool(@"enableSpoofSoftwareVersion")) {
        NSString *spIOS = spoofStr(@"iosVersion");
        if (spIOS.length) {
            NSString *spU = [spIOS stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            @try {
                NSRegularExpression *rx = [NSRegularExpression
                    regularExpressionWithPattern:@"iPhone OS \\d+_\\d+(_\\d+)?"
                    options:0 error:nil];
                if (rx) out = [rx stringByReplacingMatchesInString:out options:0
                    range:NSMakeRange(0, out.length)
                    withTemplate:[NSString stringWithFormat:@"iPhone OS %@", spU]];
                NSRegularExpression *vr = [NSRegularExpression
                    regularExpressionWithPattern:@"Version/\\d+\\.\\d+(\\.\\d+)?"
                    options:0 error:nil];
                if (vr) out = [vr stringByReplacingMatchesInString:out options:0
                    range:NSMakeRange(0, out.length)
                    withTemplate:[NSString stringWithFormat:@"Version/%@", spIOS]];
            } @catch (__unused id e) {}
        }
    }
    return out;
}

// Build a complete spoofed WebKit UA from scratch. Used when WKWebView has no customUserAgent
// set, so we need to construct the full string rather than rewriting an existing one.
// Format: Mozilla/5.0 (iPhone; CPU iPhone OS <ver> like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/<ver> Mobile/15E148 Safari/604.1
static NSString *miosBuildSpoofedWebKitUA(void) {
    if (!gDeviceSpoofActive) return nil;
    NSString *ios = spoofBool(@"enableSpoofSoftwareVersion") ? spoofStr(@"iosVersion") : nil;
    if (!ios.length) return nil;
    NSString *iosU = [ios stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    return [NSString stringWithFormat:
        @"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) "
        @"AppleWebKit/605.1.15 (KHTML, like Gecko) Version/%@ Mobile/15E148 Safari/604.1",
        iosU, ios];
}

static NSString *miosWebSpoofJS(void) {
    if (!gDeviceSpoofActive) return nil;
    NSMutableString *js = [NSMutableString stringWithString:@"(function(){"];
    NSString *ios = spoofBool(@"enableSpoofSoftwareVersion") ? spoofStr(@"iosVersion") : nil;
    if (ios.length) {
        NSString *u = [ios stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        [js appendFormat:@"try{var p='iPhone OS %@';var ua=navigator.userAgent"
                         @".replace(/iPhone OS \\d+_\\d+(_\\d+)?/,p)"
                         @".replace(/Version\\/\\d+\\.\\d+(\\.\\d+)?/,'Version/%@');"
                         @"Object.defineProperty(navigator,'userAgent',{get:function(){return ua;}});}catch(e){}",
                         u, ios];
    }
    NSInteger cores = spoofInt(@"cpuCores");
    if (cores > 0)
        [js appendFormat:@"try{Object.defineProperty(navigator,'hardwareConcurrency',{get:function(){return %ld;}});}catch(e){}", (long)cores];
    if (gcScreenNativeScale > 0)
        [js appendFormat:@"try{Object.defineProperty(window,'devicePixelRatio',{get:function(){return %g;}});}catch(e){}", (double)gcScreenNativeScale];
    if (gcScreenW > 0 && gcScreenH > 0 && gcScreenNativeScale > 0) {
        long cssW = lround(gcScreenW / gcScreenNativeScale);
        long cssH = lround(gcScreenH / gcScreenNativeScale);
        [js appendFormat:@"try{Object.defineProperty(screen,'width',{get:function(){return %ld;}});"
                         @"Object.defineProperty(screen,'height',{get:function(){return %ld;}});"
                         @"Object.defineProperty(screen,'availWidth',{get:function(){return %ld;}});"
                         @"Object.defineProperty(screen,'availHeight',{get:function(){return %ld;}});}catch(e){}",
                         cssW, cssH, cssW, cssH];
    }
    [js appendString:@"})();"];
    return js.length > 14 ? js : nil;   // >"(function(){})();" means at least one override added
}
%hook WKWebView
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    NSLog(@"[miOS-web] WKWebView init FIRED class=%@ spoofActive=%d cfg=%d",
          NSStringFromClass([self class]), (int)gDeviceSpoofActive, configuration != nil);
    @try {
        NSString *js = miosWebSpoofJS();
        if (js && configuration) {
            WKUserContentController *ucc = configuration.userContentController ?: [WKUserContentController new];
            [ucc addUserScript:[[WKUserScript alloc] initWithSource:js
                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                    forMainFrameOnly:NO]];
            configuration.userContentController = ucc;
            NSLog(@"[miOS-web] injected device-spoof user script (len=%lu)", (unsigned long)js.length);
        } else {
            NSLog(@"[miOS-web] NOT injected (js=%d cfg=%d)", js != nil, configuration != nil);
        }
    } @catch (__unused id e) {}
    WKWebView *wv = %orig;
    @try {
        if (gDeviceSpoofActive && wv) {
            NSString *existing = wv.customUserAgent;
            if (existing.length) {
                wv.customUserAgent = miosRewriteWebKitUA(existing);
                NSLog(@"[miOS-web] proactive customUserAgent rewrite: %@", wv.customUserAgent);
            } else {
                NSString *spoofUA = miosBuildSpoofedWebKitUA();
                if (spoofUA.length) {
                    wv.customUserAgent = spoofUA;
                    NSLog(@"[miOS-web] proactive customUserAgent SET: %@", spoofUA);
                }
            }
        }
    } @catch (__unused id e) {}
    return wv;
}
- (void)setCustomUserAgent:(NSString *)ua {
    if (gDeviceSpoofActive && [ua isKindOfClass:[NSString class]] && ua.length > 0) {
        NSString *rewritten = miosRewriteWebKitUA(ua);
        NSLog(@"[miOS-ua] WKWebView setCustomUserAgent in=%@ out=%@", ua, rewritten);
        %orig(rewritten);
        return;
    }
    %orig;
}
- (NSString *)customUserAgent {
    NSString *ua = %orig;
    if (gDeviceSpoofActive && [ua isKindOfClass:[NSString class]] && ua.length > 0)
        return miosRewriteWebKitUA(ua);
    return ua;
}
- (void)loadRequest:(NSURLRequest *)request {
    NSLog(@"[miOS-web] WKWebView loadRequest %@", request.URL.absoluteString);
    %orig;
}
%end
%hook WKWebViewConfiguration
- (void)setApplicationNameForUserAgent:(NSString *)name {
    if (gDeviceSpoofActive && [name isKindOfClass:[NSString class]] && name.length > 0) {
        NSString *rewritten = miosRewriteWebKitUA(name);
        NSLog(@"[miOS-ua] WKWebViewConfig setApplicationNameForUserAgent in=%@ out=%@", name, rewritten);
        %orig(rewritten);
        return;
    }
    %orig;
}
- (NSString *)applicationNameForUserAgent {
    NSString *name = %orig;
    if (gDeviceSpoofActive && [name isKindOfClass:[NSString class]] && name.length > 0)
        return miosRewriteWebKitUA(name);
    return name;
}
%end
// If the Accounts Center opens in a system Safari view instead of an in-process WKWebView, our
// WKUserScript injection is impossible — log that path so we can tell which one IG uses.
%hook SFSafariViewController
- (instancetype)initWithURL:(NSURL *)url {
    NSLog(@"[miOS-web] SFSafariViewController(URL) %@ — CANNOT inject (separate process)", url.absoluteString);
    return %orig;
}
%end

// MARK: - Build the allocation-free cache

static char *dupCString(NSString *s) { return s.length ? strdup(s.UTF8String ?: "") : NULL; }
static CFStringRef retainedCF(NSString *s) { return s.length ? (__bridge_retained CFStringRef)[s copy] : NULL; }

// Resolve hw.cpufamily for a spoofed SoC. Values are the Apple CPUFAMILY_* constants from
// <mach/machine.h>. Only the generations whose constant is known-good are mapped; newer chips
// (A17 Pro / A18 / A19) return 0 = pass through the real value, since a wrong constant would be
// a worse fingerprint than the honest one. Matched on the leading "A<n>" token of chipName
// ("A16 Bionic" and "A16" both → A16).
static uint32_t miosCPUFamilyForChip(NSString *chip) {
    if (chip.length == 0) return 0;
    NSString *tok = [[chip componentsSeparatedByString:@" "] firstObject];
    if (tok.length == 0) return 0;
    static NSDictionary<NSString *, NSNumber *> *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"A10": @(0x67ceee93u),  // Hurricane/Zephyr  (iPhone 7)
            @"A11": @(0xe81e7ef6u),  // Monsoon/Mistral   (iPhone 8 / X)
            @"A12": @(0x07d34b9fu),  // Vortex/Tempest    (iPhone XS/XR)
            @"A13": @(0x462504d2u),  // Lightning/Thunder (iPhone 11)
            @"A14": @(0x1b588bb3u),  // Firestorm/Icestorm(iPhone 12)
            @"A15": @(0xda33d83du),  // Avalanche/Blizzard(iPhone 13 / 14 / 14 Plus)
            @"A16": @(0x8765edeau),  // Everest/Sawtooth  (iPhone 14 Pro / 15 / 15 Plus / 16e)
        };
    });
    NSNumber *v = map[tok];
    return v ? (uint32_t)v.unsignedIntValue : 0;
}

// Build the crash-safe hw.optional.arm.FEAT_* override table from an optional config dictionary
// (key "cpuFeatures": { "hw.optional.arm.FEAT_LSE": @1, ... }). Must run in the ctor BEFORE the
// sysctl fishhook is installed, so the sysctlbyname() below reads the REAL CPU. Invariant:
// effective = requested && real — a feature is only ever reported present if the real CPU has it.
static void miosBuildFeatureOverrides(id cpuFeatures) {
    if (![cpuFeatures isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *feats = cpuFeatures;
    if (feats.count == 0) return;
    MiOSFeatOverride *arr = calloc(feats.count, sizeof(MiOSFeatOverride));
    if (!arr) return;
    size_t i = 0;
    for (NSString *k in feats) {
        if (![k isKindOfClass:[NSString class]]) continue;
        if (![k hasPrefix:@"hw.optional.arm.FEAT_"]) continue;
        int requested = [feats[k] boolValue] ? 1 : 0;
        int realv = 0; size_t rl = sizeof(realv);
        if (sysctlbyname(k.UTF8String, &realv, &rl, NULL, 0) != 0) realv = 0;  // real sysctl (pre-hook)
        arr[i].name  = strdup(k.UTF8String);
        arr[i].value = (requested && realv) ? 1 : 0;
        i++;
    }
    if (i) { gcFeatOverrides = arr; gcFeatOverrideCount = i; }
    else   { free(arr); }
}

// Native screen resolution (portrait pixels) + nativeScale per iPhone identifier. Only models with
// a confidently known resolution are listed; anything else (e.g. the iPhone 17 line) returns 0 and
// passes through the real screen. Values are the documented device native resolutions.
static void miosScreenForIdentifier(NSString *ident, CGFloat *w, CGFloat *h, CGFloat *scale) {
    *w = *h = *scale = 0;
    if (ident.length == 0) return;
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *map; static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone9,1":  @[@750,  @1334, @2],       // iPhone 7
            @"iPhone9,2":  @[@1080, @1920, @2.608],   // iPhone 7 Plus (downsampled from @3x)
            @"iPhone10,1": @[@750,  @1334, @2],       // iPhone 8
            @"iPhone10,2": @[@1080, @1920, @2.608],   // iPhone 8 Plus (downsampled from @3x)
            @"iPhone10,3": @[@1125, @2436, @3],   // iPhone X
            @"iPhone11,8": @[@828,  @1792, @2],   // iPhone XR
            @"iPhone11,2": @[@1125, @2436, @3],   // iPhone XS
            @"iPhone11,6": @[@1242, @2688, @3],   // iPhone XS Max
            @"iPhone12,1": @[@828,  @1792, @2],   // iPhone 11
            @"iPhone12,3": @[@1125, @2436, @3],   // iPhone 11 Pro
            @"iPhone12,5": @[@1242, @2688, @3],   // iPhone 11 Pro Max
            @"iPhone13,1": @[@1080, @2340, @3],   // iPhone 12 mini
            @"iPhone13,2": @[@1170, @2532, @3],   // iPhone 12
            @"iPhone13,3": @[@1170, @2532, @3],   // iPhone 12 Pro
            @"iPhone13,4": @[@1284, @2778, @3],   // iPhone 12 Pro Max
            @"iPhone14,4": @[@1080, @2340, @3],   // iPhone 13 mini
            @"iPhone14,5": @[@1170, @2532, @3],   // iPhone 13
            @"iPhone14,2": @[@1170, @2532, @3],   // iPhone 13 Pro
            @"iPhone14,3": @[@1284, @2778, @3],   // iPhone 13 Pro Max
            @"iPhone14,7": @[@1170, @2532, @3],   // iPhone 14
            @"iPhone14,8": @[@1284, @2778, @3],   // iPhone 14 Plus
            @"iPhone15,2": @[@1179, @2556, @3],   // iPhone 14 Pro
            @"iPhone15,3": @[@1290, @2796, @3],   // iPhone 14 Pro Max
            @"iPhone15,4": @[@1179, @2556, @3],   // iPhone 15
            @"iPhone15,5": @[@1290, @2796, @3],   // iPhone 15 Plus
            @"iPhone16,1": @[@1179, @2556, @3],   // iPhone 15 Pro
            @"iPhone16,2": @[@1290, @2796, @3],   // iPhone 15 Pro Max
            @"iPhone17,3": @[@1179, @2556, @3],   // iPhone 16
            @"iPhone17,4": @[@1290, @2796, @3],   // iPhone 16 Plus
            @"iPhone17,1": @[@1206, @2622, @3],   // iPhone 16 Pro
            @"iPhone17,2": @[@1320, @2868, @3],   // iPhone 16 Pro Max
            @"iPhone18,1": @[@1170, @2532, @3],   // iPhone 16e
        };
    });
    NSArray<NSNumber *> *v = map[ident];
    if (v.count == 3) { *w = [v[0] floatValue]; *h = [v[1] floatValue]; *scale = [v[2] floatValue]; }
}

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
        NSString *ident = spoofStr(@"deviceIdentifier");
        NSString *cls = [ident hasPrefix:@"iPad"] ? @"iPad"
                      : [ident hasPrefix:@"iPod"] ? @"iPod touch"
                      : [ident hasPrefix:@"iPhone"] ? @"iPhone" : nil;
        gcMGDeviceClass = retainedCF(cls);
        // hw.cpufamily + hw.optional.arm.FEAT_* must track the spoofed SoC (IG reads both as part
        // of its device fingerprint). cpuFamily from config wins; else derive from the chip name.
        uint32_t fam = (uint32_t)[gSpoof[@"cpuFamily"] unsignedIntValue];
        if (!fam) fam = miosCPUFamilyForChip(spoofStr(@"chipName"));
        gcCPUFamily = fam;
        miosBuildFeatureOverrides(gSpoof[@"cpuFeatures"]);
        // Screen native resolution must match the spoofed model (media_layout_screen_* telemetry).
        // Config overrides win; else derive from the identifier. Only nativeBounds/nativeScale.
        CGFloat sw = 0, sh = 0, ss = 0;
        miosScreenForIdentifier(spoofStr(@"deviceIdentifier"), &sw, &sh, &ss);
        if ([gSpoof[@"screenWidthPx"] doubleValue]  > 0) sw = (CGFloat)[gSpoof[@"screenWidthPx"] doubleValue];
        if ([gSpoof[@"screenHeightPx"] doubleValue] > 0) sh = (CGFloat)[gSpoof[@"screenHeightPx"] doubleValue];
        if ([gSpoof[@"screenNativeScale"] doubleValue] > 0) ss = (CGFloat)[gSpoof[@"screenNativeScale"] doubleValue];
        gcScreenW = sw; gcScreenH = sh; gcScreenNativeScale = ss;
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
- (NSString *)accessGroup {
    NSString *g = miosValidAccessGroup();
    if (g) return g;
    return %orig;
}
%end
%hook FBKeychainItemController
- (NSString *)accessGroup {
    NSString *g = miosValidAccessGroup();
    if (g) return g;
    return %orig;
}
%end
%hook UICKeyChainStore
- (NSString *)accessGroup {
    NSString *g = miosValidAccessGroup();
    if (g) return g;
    return %orig;
}
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
// User-Agent header rewrite — TIMING-INDEPENDENT. Even if IGUserAgent (a lazy Swift singleton)
// cached its UA string before our hooks installed (or a framework +load read hw.machine before our
// ctor), the UA leaves the app through a request header, which we rewrite here at send time. The IG
// UA embeds the model identifier (e.g. iPhone17,1), the iOS version (16_7 / 16.7) and the screen
// resolution — swap the real values for the spoofed ones. This does not depend on winning any race.
static NSString *miosRewriteUA(NSString *ua) {
    if (!gDeviceSpoofActive || ![ua isKindOfClass:[NSString class]] || ua.length == 0) return ua;
    NSString *out = ua;
    NSString *spM = spoofStr(@"deviceIdentifier");
    if (gRealMachineNS.length && spM.length)
        out = [out stringByReplacingOccurrencesOfString:gRealMachineNS withString:spM];
    if (spoofBool(@"enableSpoofSoftwareVersion")) {
        NSString *spIOS = spoofStr(@"iosVersion");
        if (gRealIOSNS.length && spIOS.length) {
            NSString *realU = [gRealIOSNS stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            NSString *spU   = [spIOS      stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            out = [out stringByReplacingOccurrencesOfString:realU withString:spU];   // 16_7 form
            out = [out stringByReplacingOccurrencesOfString:gRealIOSNS withString:spIOS]; // 16.7 form
        }
    }
    if (out != ua && ![out isEqualToString:ua])
        NSLog(@"[miOS-ua] rewrote User-Agent -> %@", out);
    return out;
}

// FBSharedFramework C UA builders (confirmed present via dlsym). METAGenerateInstagramStyleUser-
// AgentInfoString builds the device part "(iPhone17,1; iOS 18_5; Scale/3.00)" of IG's UA — IG does
// NOT use -[IGUserAgent userAgent] (our ObjC hook never fired), it goes through these. Rewrite the
// returned string. Args are passed through as up to 4 pointers (a UA builder takes 0-few pointer
// args); when nothing matches, miosRewriteUA returns the original pointer unchanged (no ARC/owner
// risk). METAUserAgentInfoDefaultValue is a DATA symbol (different segment), so it is NOT hooked.
static NSString *(*orig_METAGenUA)(void *, void *, void *, void *) = NULL;
static NSString *hook_METAGenUA(void *a0, void *a1, void *a2, void *a3) {
    NSString *r = orig_METAGenUA(a0, a1, a2, a3);
    if (!gDeviceSpoofActive || ![r isKindOfClass:[NSString class]]) return r;
    static int lg = 0; if (lg < 4) { lg++; NSLog(@"[miOS-ua] METAGenerate in=%@", r); }
    return miosRewriteUA(r);
}
static NSString *(*orig_METAWKUA)(void *, void *, void *, void *) = NULL;
static NSString *hook_METAWKUA(void *a0, void *a1, void *a2, void *a3) {
    NSString *r = orig_METAWKUA(a0, a1, a2, a3);
    if (!gDeviceSpoofActive || ![r isKindOfClass:[NSString class]]) return r;
    static int lg = 0; if (lg < 4) { lg++; NSLog(@"[miOS-ua] METAGetWKWebViewUA in=%@", r); }
    return miosRewriteUA(r);
}
static NSString *(*orig_METAWKUADef)(void *, void *, void *, void *) = NULL;
static NSString *hook_METAWKUADef(void *a0, void *a1, void *a2, void *a3) {
    NSString *r = orig_METAWKUADef(a0, a1, a2, a3);
    if (!gDeviceSpoofActive || ![r isKindOfClass:[NSString class]]) return r;
    return miosRewriteUA(r);
}

// IGUserAgent singleton — rewrite the composed UA at its source (timing-independent, defeats a
// cached real-model UA). This is the string that registers the login session's device.
%hook _TtC11IGUserAgent11IGUserAgent
- (NSString *)userAgent {
    NSString *ua = %orig;
    if (!gDeviceSpoofActive) return ua;
    NSString *nu = miosRewriteUA(ua);
    static int lg = 0; if (lg < 4) { lg++; NSLog(@"[miOS-ua] IGUserAgent.userAgent in=%@", ua); }
    return nu;
}
- (NSString *)sanitizedUserAgent {
    NSString *ua = %orig;
    return gDeviceSpoofActive ? miosRewriteUA(ua) : ua;
}
- (NSString *)customUserAgent {
    NSString *ua = %orig;
    return gDeviceSpoofActive ? miosRewriteUA(ua) : ua;
}
- (void)setCustomUserAgent:(NSString *)ua {
    if (gDeviceSpoofActive && [ua isKindOfClass:[NSString class]] && ua.length > 0) {
        NSString *rewritten = miosRewriteUA(ua);
        NSLog(@"[miOS-ua] IGUserAgent setCustomUserAgent in=%@ out=%@", ua, rewritten);
        %orig(rewritten);
        return;
    }
    %orig;
}
%end
%hook NSMutableURLRequest
- (void)setHTTPBody:(NSData *)body {
    NSData *rewritten = miosRewriteHTTPBody(body);
    %orig(rewritten);
}
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (gDeviceSpoofActive && [field isKindOfClass:[NSString class]] &&
        [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *nv = miosRewriteUA(value);
        %orig(nv, field);
        return;
    }
    %orig;
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (gDeviceSpoofActive && [field isKindOfClass:[NSString class]] &&
        [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *nv = miosRewriteUA(value);
        %orig(nv, field);
        return;
    }
    %orig;
}
- (void)setAllHTTPHeaderFields:(NSDictionary<NSString *, NSString *> *)headers {
    if (gDeviceSpoofActive && [headers isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [headers mutableCopy];
        for (NSString *k in headers) {
            if ([k isKindOfClass:[NSString class]] && [k caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
                m[k] = miosRewriteUA(headers[k]);
        }
        %orig(m);
        return;
    }
    %orig;
}
%end
// NOTE: NSURLSession uploadTaskWithRequest:fromData: is already hooked above (search
// "%hook NSURLSession"); the body rewrite is wired into those existing methods to avoid a
// duplicate-hook compile error.

// MARK: - Earliest boot (+load)
//
// +load runs BEFORE any __attribute__((constructor)) — including Instagram's own constructors
// and +load methods in its classes, because our dylib is a dependency (LC_LOAD_DYLIB) of the
// main executable, so dyld loads and initializes us first. This is the absolute earliest point
// we can run code in userspace without DYLD_INTERPOSE.
//
// We do: Instagram detection → container resolution → spoof cache → fishhook (C functions).
// By the time IG's own +load fires, sysctl/uname/MGCopyAnswer are already hooked.

static BOOL gEarlyBootDone = NO;
static MiOSContainer *gEarlyBootActiveContainer = nil;

@interface MiOSEarlyBoot : NSObject @end
@implementation MiOSEarlyBoot
+ (void)load {
    @autoreleasepool {
        gT0 = mach_absolute_time();
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *exeName = [[[NSBundle mainBundle] executablePath] lastPathComponent] ?: @"";
        NSString *low = bundleID.lowercaseString;
        BOOL isInstagram = ([low containsString:@"burbn"] ||
                            [low containsString:@"instagram"] ||
                            [exeName isEqualToString:@"Instagram"]);
        if (!isInstagram) return;

        gRealHome = [NSHomeDirectory() copy];
        MiOSSetRealHome(gRealHome);
        setenv("MIOS_REAL_HOME", gRealHome.UTF8String, 1);

        MiOSContainer *active = [MiOSContainer activeOrDefaultContainer];
        if (!active) return;

        gContainerUUID = [active.identifier copy];
        gSpoof = active.enableSpoof ? [[active spoofPrefs] copy] : @{};

        miosBuildSpoofCache();
        if (gDeviceSpoofActive) {
            char m[128] = {0}; size_t ml = sizeof(m);
            if (sysctlbyname("hw.machine", m, &ml, NULL, 0) == 0 && m[0])
                gRealMachineNS = [NSString stringWithUTF8String:m];
            char v[128] = {0}; size_t vl = sizeof(v);
            if (sysctlbyname("kern.osproductversion", v, &vl, NULL, 0) == 0 && v[0])
                gRealIOSNS = [NSString stringWithUTF8String:v];
            void *mgH = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
            if (mgH) {
                CFTypeRef (*mg)(CFStringRef) = (CFTypeRef (*)(CFStringRef))dlsym(mgH, "MGCopyAnswer");
                if (mg) {
                    CFTypeRef fn = mg(CFSTR("marketing-name"));
                    if (fn && CFGetTypeID(fn) == CFStringGetTypeID()) gRealFriendlyNS = (__bridge_transfer NSString *)fn;
                    else if (fn) CFRelease(fn);
                }
            }
            NSLog(@"[miOS-time] +load: captured REAL device @%.0fms machine=%@ ios=%@",
                  miosMsSinceStart(), gRealMachineNS, gRealIOSNS);
            rebind_symbols((struct rebinding[]){
                {"sysctlbyname", (void *)hook_sysctlbyname, (void **)&orig_sysctlbyname},
                {"sysctl",       (void *)hook_sysctl,       (void **)&orig_sysctl},
                {"uname",        (void *)hook_uname,        (void **)&orig_uname},
            }, 3);
            if (gcMGProductType || gcMGProductVersion || gcMGDeviceName || gcMGHWModel || gcMGDeviceClass) {
                rebind_symbols((struct rebinding[]){
                    {"MGCopyAnswer", (void *)mios_MGCopyAnswer, (void **)&orig_MGCopyAnswer},
                }, 1);
                void *mgH2 = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
                if (mgH2 && dlsym(mgH2, "MGCopyAnswer_internal"))
                    rebind_symbols((struct rebinding[]){
                        {"MGCopyAnswer_internal", (void *)mios_MGCopyAnswer_internal, (void **)&orig_MGCopyAnswer_internal},
                    }, 1);
            }
            rebind_symbols((struct rebinding[]){
                {"METAGenerateInstagramStyleUserAgentInfoString", (void *)hook_METAGenUA,    (void **)&orig_METAGenUA},
                {"METAGetWKWebViewUserAgent",                     (void *)hook_METAWKUA,     (void **)&orig_METAWKUA},
                {"METAWKWebViewDefaultUserAgentForCurrentApp",    (void *)hook_METAWKUADef,  (void **)&orig_METAWKUADef},
            }, 3);
            NSLog(@"[miOS-time] +load: C hooks INSTALLED @%.0fms (before ANY IG +load/ctor)",
                  miosMsSinceStart());
        }
        rebind_symbols((struct rebinding[]){
            {"_dyld_image_count",          (void *)hook_dyld_image_count,          (void **)&orig_dyld_image_count},
            {"_dyld_get_image_header",     (void *)hook_dyld_get_image_header,     (void **)&orig_dyld_get_image_header},
            {"_dyld_get_image_name",       (void *)hook_dyld_get_image_name_fn,    (void **)&orig_dyld_get_image_name},
            {"_dyld_get_image_vmaddr_slide",(void *)hook_dyld_get_image_vmaddr_slide,(void **)&orig_dyld_get_image_vmaddr_slide},
        }, 4);
        gEarlyBootActiveContainer = active;
        gEarlyBootDone = YES;
    }
}
@end

// MARK: - Constructor

%ctor {
    @autoreleasepool {
        if (!gEarlyBootDone) {
            // +load didn't fire (shouldn't happen, but defensive fallback)
            gT0 = mach_absolute_time();
            NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
            NSString *exeName = [[[NSBundle mainBundle] executablePath] lastPathComponent] ?: @"";
            NSString *low = bundleID.lowercaseString;
            BOOL isInstagram = ([low containsString:@"burbn"] ||
                                [low containsString:@"instagram"] ||
                                [exeName isEqualToString:@"Instagram"]);
            if (!isInstagram) return;
            gRealHome = [NSHomeDirectory() copy];
            MiOSSetRealHome(gRealHome);
            setenv("MIOS_REAL_HOME", gRealHome.UTF8String, 1);
        } else if (!gRealHome) {
            return;
        }

        gMainPThread = pthread_self();
        miosInstallDiagnostics(gRealHome);
        miosLog(@"ctor engaged: earlyBoot=%d home=%@", (int)gEarlyBootDone, gRealHome);
        dispatch_async(dispatch_get_main_queue(), ^{ gMainPThread = pthread_self(); });
        miosStartWatchdog();

        @try {
            NSString *diag = [NSString stringWithFormat:
                @"miOS loaded at %@\nhome=%@\ntmp=%@\nearlyBoot=%d\n",
                [NSDate date], gRealHome, NSTemporaryDirectory(), (int)gEarlyBootDone];
            NSString *path = [[gRealHome stringByAppendingPathComponent:@"Documents"]
                                stringByAppendingPathComponent:@"mios-loaded.txt"];
            [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            [diag writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } @catch (__unused id e) {}

        [MiOSUI install];

        %init(SideloadFixes);
        miosLog(@"SideloadFixes installed (keychain access group + app-group container)");

        MiOSContainer *active = gEarlyBootActiveContainer;
        if (!active) {
            active = [MiOSContainer activeOrDefaultContainer];
            if (!active) {
                miosLog(@"no active container and Default unavailable — passing through");
                return;
            }
            gContainerUUID = [active.identifier copy];
            gSpoof = active.enableSpoof ? [[active spoofPrefs] copy] : @{};
        }
        miosLog(@"active container=%@ enableSpoof=%d earlyBoot=%d",
                gContainerUUID, (int)active.enableSpoof, (int)gEarlyBootDone);

        if (!gEarlyBootDone) {
            miosBuildSpoofCache();
            if (gDeviceSpoofActive) {
                char m[128] = {0}; size_t ml = sizeof(m);
                if (sysctlbyname("hw.machine", m, &ml, NULL, 0) == 0 && m[0])
                    gRealMachineNS = [NSString stringWithUTF8String:m];
                char v[128] = {0}; size_t vl = sizeof(v);
                if (sysctlbyname("kern.osproductversion", v, &vl, NULL, 0) == 0 && v[0])
                    gRealIOSNS = [NSString stringWithUTF8String:v];
                void *mgH = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
                if (mgH) {
                    CFTypeRef (*mg)(CFStringRef) = (CFTypeRef (*)(CFStringRef))dlsym(mgH, "MGCopyAnswer");
                    if (mg) {
                        CFTypeRef fn = mg(CFSTR("marketing-name"));
                        if (fn && CFGetTypeID(fn) == CFStringGetTypeID()) gRealFriendlyNS = (__bridge_transfer NSString *)fn;
                        else if (fn) CFRelease(fn);
                    }
                }
                rebind_symbols((struct rebinding[]){
                    {"sysctlbyname", (void *)hook_sysctlbyname, (void **)&orig_sysctlbyname},
                    {"sysctl",       (void *)hook_sysctl,       (void **)&orig_sysctl},
                    {"uname",        (void *)hook_uname,        (void **)&orig_uname},
                }, 3);
                if (gcMGProductType || gcMGProductVersion || gcMGDeviceName || gcMGHWModel || gcMGDeviceClass) {
                    rebind_symbols((struct rebinding[]){
                        {"MGCopyAnswer", (void *)mios_MGCopyAnswer, (void **)&orig_MGCopyAnswer},
                    }, 1);
                    void *mgH2 = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
                    if (mgH2 && dlsym(mgH2, "MGCopyAnswer_internal"))
                        rebind_symbols((struct rebinding[]){
                            {"MGCopyAnswer_internal", (void *)mios_MGCopyAnswer_internal, (void **)&orig_MGCopyAnswer_internal},
                        }, 1);
                }
                rebind_symbols((struct rebinding[]){
                    {"METAGenerateInstagramStyleUserAgentInfoString", (void *)hook_METAGenUA,    (void **)&orig_METAGenUA},
                    {"METAGetWKWebViewUserAgent",                     (void *)hook_METAWKUA,     (void **)&orig_METAWKUA},
                    {"METAWKWebViewDefaultUserAgentForCurrentApp",    (void *)hook_METAWKUADef,  (void **)&orig_METAWKUADef},
                }, 3);
            }
            rebind_symbols((struct rebinding[]){
                {"_dyld_image_count",          (void *)hook_dyld_image_count,          (void **)&orig_dyld_image_count},
                {"_dyld_get_image_header",     (void *)hook_dyld_get_image_header,     (void **)&orig_dyld_get_image_header},
                {"_dyld_get_image_name",       (void *)hook_dyld_get_image_name_fn,    (void **)&orig_dyld_get_image_name},
                {"_dyld_get_image_vmaddr_slide",(void *)hook_dyld_get_image_vmaddr_slide,(void **)&orig_dyld_get_image_vmaddr_slide},
            }, 4);
            NSLog(@"[miOS-time] ctor fallback: C hooks INSTALLED @%.0fms", miosMsSinceStart());
        }

        dlopen("/System/Library/Frameworks/DeviceCheck.framework/DeviceCheck", RTLD_LAZY);
        %init(EarlyIdentity);
        if (spoofBool(@"enableBlockBackground")) {
            %init(BackgroundBlocker);
            NSLog(@"[miOS-bg] Background task blocker INSTALLED");
        }
        if (spoofBool(@"enableCameraHooker")) {
            %init(CameraHooker);
            NSLog(@"[miOS-cam] Camera hooker INSTALLED");
        }
        NSLog(@"[miOS-time] EarlyIdentity + extra ObjC hooks @%.0fms", miosMsSinceStart());

        // 1. Filesystem isolation.
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
        // Device-header keychain probe: ~1s in (what's stored at launch) and again at ~6s (after IG
        // has had a chance to read/create its header this session). Shows value + whether isolated.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ miosProbeDeviceHeaders(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ miosProbeDeviceHeaders(); });

        // 3. First-launch App-Group wipe.
        miosResetContainerCachesOnce(gContainerUUID);

        // (Device spoof cache, real-device capture, and the sysctl/uname/MGCopyAnswer hooks were
        // installed FIRST, above — see "DEVICE SPOOF FIRST" — before FS/keychain, to shrink the
        // pre-read window.)

        // Bind the remaining ObjC hooks (battery/brightness/locale/carrier/location/network/
        // WKWebView/IGUserAgent/NSMutableURLRequest — non-identity hooks that can wait).
        %init;

        // Diagnostic: did the IGUserAgent %hook have a class to attach to, and what are the real
        // UA class names + do the FBSharedFramework UA C functions exist? Tells us why [miOS-ua]
        // may be silent (wrong class name / class not loaded / IG uses the C builders instead).
        @try {
            NSLog(@"[miOS-ua] _TtC11IGUserAgent11IGUserAgent class = %p",
                  (__bridge void *)objc_getClass("_TtC11IGUserAgent11IGUserAgent"));
            unsigned int ncls = 0; Class *all = objc_copyClassList(&ncls);
            int logged = 0;
            for (unsigned int i = 0; i < ncls && logged < 40; i++) {
                const char *cn = class_getName(all[i]);
                if (cn && (strstr(cn, "UserAgent") || strstr(cn, "userAgent"))) {
                    NSLog(@"[miOS-ua] UA class present: %s", cn); logged++;
                }
            }
            if (all) free(all);
            const char *fns[] = { "METAGenerateInstagramStyleUserAgentInfoString",
                                  "METAGetWKWebViewUserAgent",
                                  "METAWKWebViewDefaultUserAgentForCurrentApp",
                                  "METAUserAgentInfoDefaultValue" };
            for (int i = 0; i < 4; i++)
                NSLog(@"[miOS-ua] C fn %s = %p", fns[i], dlsym(RTLD_DEFAULT, fns[i]));
        } @catch (__unused id e) {}

        // DeviceCheck and App Attest are not hooked at all (removed to match Blaze).

        // getifaddrs — Wi-Fi + cellular IP spoofing (Blaze fishhooks this too).
        if (spoofBool(@"enableSpoofWiFi") || spoofBool(@"enableSpoofCellular"))
            rebind_symbols((struct rebinding[]){
                {"getifaddrs", (void *)hook_getifaddrs, (void **)&orig_getifaddrs},
            }, 1);

        // Full identity isolation — CFPreferences (read+write+sync), gethostuuid and IORegistry
        // routed per-container. fishhook needs only the symbol names (IOKit not linked).
        rebind_symbols((struct rebinding[]){
            {"CFPreferencesCopyAppValue",         (void *)hook_CFPrefCopyAppValue, (void **)&orig_CFPrefCopyAppValue},
            {"CFPreferencesSetAppValue",          (void *)hook_CFPrefSetAppValue,  (void **)&orig_CFPrefSetAppValue},
            {"CFPreferencesCopyValue",            (void *)hook_CFPrefCopyValue,    (void **)&orig_CFPrefCopyValue},
            {"CFPreferencesSetValue",             (void *)hook_CFPrefSetValue,     (void **)&orig_CFPrefSetValue},
            {"CFPreferencesAppSynchronize",       (void *)hook_CFPrefAppSync,      (void **)&orig_CFPrefAppSync},
            {"gethostuuid",                       (void *)hook_gethostuuid,        (void **)&orig_gethostuuid},
            {"IORegistryEntryCreateCFProperty",   (void *)hook_IORegCreateCFProp,  (void **)&orig_IORegCreateCFProp},
        }, 7);
        NSLog(@"[miOS-id] full identity isolation installed (CFPreferences/iCloudKVS/gethostuuid/IORegistry) container=%@", miosContainerUUIDString());

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
                // hw.cpufamily — must equal gcCPUFamily when the spoofed chip is in the known table.
                uint32_t fam = 0; size_t fl = sizeof(fam);
                sysctlbyname("hw.cpufamily", &fam, &fl, NULL, 0);
                NSLog(@"[miOS-iso] SELFTEST hw.cpufamily=0x%08x  want=0x%08x  (cpufamily-hook %@)",
                      fam, gcCPUFamily,
                      gcCPUFamily ? (fam == gcCPUFamily ? @"WORKS" : @"NOT firing") : @"(passthrough)");
                NSLog(@"[miOS-iso] SELFTEST FEAT overrides=%zu (crash-safe: requested && real)", gcFeatOverrideCount);
                CGRect nb = [UIScreen mainScreen].nativeBounds;
                NSLog(@"[miOS-iso] SELFTEST UIScreen.nativeBounds=%.0fx%.0f nativeScale=%.2f  want=%.0fx%.0f@%.2f (%@)",
                      nb.size.width, nb.size.height, [UIScreen mainScreen].nativeScale,
                      gcScreenW, gcScreenH, gcScreenNativeScale,
                      (gcScreenW > 0 && nb.size.width == gcScreenW && nb.size.height == gcScreenH) ? @"WORKS"
                        : (gcScreenW > 0 ? @"NOT firing" : @"(passthrough)"));
                NSLog(@"[miOS-iso] SELFTEST UIDevice.systemVersion=%@ model=%@ (ObjC-hook path; enableSpoofSW=%d ios=%@)",
                      [UIDevice currentDevice].systemVersion, [UIDevice currentDevice].model,
                      (int)spoofBool(@"enableSpoofSoftwareVersion"), spoofStr(@"iosVersion"));
                // MGCopyAnswer import rebind — this is the value IG shows in-app for the model.
                CFTypeRef pt = mios_MGCopyAnswer(CFSTR("ProductType"));
                CFTypeRef mn = mios_MGCopyAnswer(CFSTR("marketing-name"));
                NSLog(@"[miOS-iso] SELFTEST MGCopyAnswer ProductType=%@ marketing-name=%@  want=%@ / %@",
                      (__bridge id)pt, (__bridge id)mn,
                      spoofStr(@"deviceIdentifier"), spoofStr(@"deviceDisplayName"));
                if (pt) CFRelease(pt);
                if (mn) CFRelease(mn);

                // --- Identity IDs ---
                NSUUID *vid = [UIDevice currentDevice].identifierForVendor;
                NSString *wantVendor = spoofStr(@"vendorID");
                NSLog(@"[miOS-iso] SELFTEST identifierForVendor=%@  want=%@  (%@)",
                      vid.UUIDString, wantVendor.length ? wantVendor : @"(n/a)",
                      (wantVendor.length && [vid.UUIDString.lowercaseString isEqualToString:wantVendor.lowercaseString]) ? @"WORKS" : @"check manually");

                Class asiClass = NSClassFromString(@"ASIdentifierManager");
                if (asiClass) {
                    id mgr = [asiClass performSelector:@selector(sharedManager)];
                    NSUUID *adid = [mgr performSelector:@selector(advertisingIdentifier)];
                    NSString *wantAd = spoofStr(@"advertisingID");
                    BOOL tracking = [[mgr valueForKey:@"advertisingTrackingEnabled"] boolValue];
                    NSLog(@"[miOS-iso] SELFTEST advertisingID=%@  want=%@  tracking=%d  (%@)",
                          adid.UUIDString, wantAd.length ? wantAd : @"(n/a)", tracking,
                          spoofBool(@"enableSpoofAdvertisingID") ? @"spoofing ON" : @"passthrough");
                } else {
                    NSLog(@"[miOS-iso] SELFTEST ASIdentifierManager not loaded (ok for iOS 14.5+)");
                }

                // --- FBFamily device ID ---
                Class fbFamily = NSClassFromString(@"FBFamilyDeviceIDReportInternal");
                NSLog(@"[miOS-iso] SELFTEST FBFamilyDeviceIDReportInternal class=%@ (%@)",
                      fbFamily ? @"loaded" : @"not loaded",
                      fbFamily ? @"hook active" : @"hook waiting for class load");

                // --- FBFamily jailbreak ---
                Class fbJB = NSClassFromString(@"FBFamilyIDDeviceIsJailbroken");
                if (fbJB) {
                    BOOL jb = NO;
                    @try { jb = ((BOOL (*)(id, SEL))objc_msgSend)(fbJB, @selector(isJailbroken)); } @catch(__unused id e) {}
                    NSLog(@"[miOS-iso] SELFTEST FBFamilyIDDeviceIsJailbroken.isJailbroken=%d  want=0  (%@)",
                          jb, jb == NO ? @"WORKS" : @"NOT firing");
                } else {
                    NSLog(@"[miOS-iso] SELFTEST FBFamilyIDDeviceIsJailbroken not loaded yet");
                }

                // --- uname ---
                struct utsname uts;
                uname(&uts);
                NSLog(@"[miOS-iso] SELFTEST uname.machine=%s  uname.sysname=%s  want=%@  (%@)",
                      uts.machine, uts.sysname, wantModel.length ? wantModel : @"(n/a)",
                      (wantModel.length && strcmp(uts.machine, wantModel.UTF8String) == 0) ? @"WORKS" : @"NOT firing");

                // --- NSProcessInfo ---
                NSOperatingSystemVersion osv = [[NSProcessInfo processInfo] operatingSystemVersion];
                unsigned long long physMem = [NSProcessInfo processInfo].physicalMemory;
                NSUInteger cpuCount = [NSProcessInfo processInfo].processorCount;
                NSLog(@"[miOS-iso] SELFTEST NSProcessInfo osVersion=%ld.%ld.%ld  physMem=%llu  cpuCount=%lu",
                      (long)osv.majorVersion, (long)osv.minorVersion, (long)osv.patchVersion,
                      physMem, (unsigned long)cpuCount);

                // --- dyld hiding ---
                uint32_t visibleCount = _dyld_image_count();
                uint32_t realCount = orig_dyld_image_count ? orig_dyld_image_count() : visibleCount;
                uint32_t hiddenCount = realCount - visibleCount;
                NSLog(@"[miOS-iso] SELFTEST dyld images: visible=%u  real=%u  hidden=%u  (%@)",
                      visibleCount, realCount, hiddenCount,
                      hiddenCount > 0 ? @"WORKS" : (orig_dyld_image_count ? @"no tweak libs found" : @"hook not installed"));

                // --- Summary ---
                NSLog(@"[miOS-iso] SELFTEST === SUMMARY ===");
                NSLog(@"[miOS-iso] SELFTEST deviceSpoof=%d  vendorSpoof=%d  adIDSpoof=%d  swSpoof=%d  bgBlock=%d  camHook=%d",
                      (int)gDeviceSpoofActive,
                      (int)spoofBool(@"enableSpoofVendorID"),
                      (int)spoofBool(@"enableSpoofAdvertisingID"),
                      (int)spoofBool(@"enableSpoofSoftwareVersion"),
                      (int)spoofBool(@"enableBlockBackground"),
                      (int)gCameraHookerEnabled);
            } @catch (__unused id e) {
                NSLog(@"[miOS-iso] SELFTEST exception: %@", e);
            }
        });

        miosLog(@"ctor complete — all hooks installed (deviceSpoof=%d)", (int)gDeviceSpoofActive);
    }
}
