#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// miOS — Instagram-only, Blaze-parity edition.
// A container holds the full fingerprint, location, proxy and per-module toggles.
// Everything is persisted inside Instagram's own sandbox (…/Documents/miOS),
// optionally encrypted on disk (see MiOSCrypt).

FOUNDATION_EXPORT NSString *MiOSRealHome(void);
FOUNDATION_EXPORT void MiOSSetRealHome(NSString *home);
FOUNDATION_EXPORT NSString *MiOSBaseDir(void);          // …/Documents/miOS

@interface MiOSContainer : NSObject

#pragma mark Identity

@property (nonatomic, copy) NSString *identifier;      // UUID — also data subtree + keychain tag
@property (nonatomic, copy) NSString *name;

// A stable "persistent device id" (what Blaze calls persistentDeviceID): some apps cache this
// in a group container; we expose it per-container so the app re-registers correctly.
@property (nonatomic, copy) NSString *persistentDeviceID;

#pragma mark Modes (per-container master switches — maps to Blaze Ghost / Orbit / Proxy)

@property (nonatomic, assign) BOOL enableSpoof;        // "Spoof mode" (was Ghost in Blaze)
@property (nonatomic, assign) BOOL enableLocationMode; // "Location mode" (was Orbit in Blaze)
@property (nonatomic, assign) BOOL enableProxy;        // Proxy (BETA)

#pragma mark Location (map-picker + manual coords)

@property (nonatomic, assign) BOOL spoofLocation;                 // the hook on CLLocation
@property (nonatomic, assign) CLLocationCoordinate2D coordinate;
@property (nonatomic, assign) double altitude;
@property (nonatomic, assign) double horizontalAccuracy;
@property (nonatomic, assign) double speed;
@property (nonatomic, assign) double course;
@property (nonatomic, copy) NSString *locationName;    // reverse-geocoded label
@property (nonatomic, copy) NSString *locationCountryCode;

#pragma mark Device fingerprint (enableSpoof* parity with Blaze)

@property (nonatomic, assign) BOOL enableSpoofDeviceModel;
@property (nonatomic, copy) NSString *deviceIdentifier;      // hw.machine / ProductType
@property (nonatomic, copy) NSString *deviceDisplayName;     // marketing name (iPhone 14 Pro)
@property (nonatomic, copy) NSString *deviceHardwareModel;   // hw.model / HardwarePlatform
@property (nonatomic, assign) NSInteger deviceStorageGB;
@property (nonatomic, copy) NSString *chipName;

@property (nonatomic, assign) BOOL enableSpoofDeviceName;
@property (nonatomic, copy) NSString *deviceName;            // UIDevice.name override

@property (nonatomic, assign) BOOL enableSpoofSoftwareVersion;
@property (nonatomic, copy) NSString *iosVersion;

@property (nonatomic, assign) BOOL enableSpoofKernelVersion;
@property (nonatomic, copy) NSString *kernelVersion;         // kern.version + uname.release

@property (nonatomic, assign) BOOL enableSpoofMemory;
@property (nonatomic, assign) NSInteger ramGB;

@property (nonatomic, assign) BOOL enableSpoofProcessor;
@property (nonatomic, assign) NSInteger cpuCores;

#pragma mark Carrier / Cellular

@property (nonatomic, assign) BOOL enableSpoofCarrier;
@property (nonatomic, copy) NSString *carrierName;
@property (nonatomic, copy) NSString *carrierMCC;
@property (nonatomic, copy) NSString *carrierMNC;
@property (nonatomic, copy) NSString *carrierCountryCode;    // iso
@property (nonatomic, copy) NSString *carrierFlag;           // emoji

@property (nonatomic, assign) BOOL enableSpoofCellularType;
@property (nonatomic, copy) NSString *cellularType;          // 3G / 4G / LTE / 5G / 5G-NSA / 5G-SA

@property (nonatomic, assign) BOOL enableSpoofCellular;      // cellular (pdp_ip0) IPv4
@property (nonatomic, copy) NSString *cellularAddress;

#pragma mark Wi-Fi

@property (nonatomic, assign) BOOL enableSpoofWiFi;
@property (nonatomic, copy) NSString *wifiSSID;
@property (nonatomic, copy) NSString *wifiBSSID;
@property (nonatomic, copy) NSString *wifiAddress;           // en0 IPv4

#pragma mark Battery / Brightness / LowPowerMode / Orientation / Proximity / Gyroscope

@property (nonatomic, assign) BOOL enableSpoofBatteryLevel;
@property (nonatomic, assign) NSInteger batteryLevel;        // 0..100

@property (nonatomic, assign) BOOL enableSpoofBatteryState;
@property (nonatomic, assign) NSInteger batteryState;        // 0 unknown, 1 unplugged, 2 charging, 3 full

@property (nonatomic, assign) BOOL enableSpoofBrightness;
@property (nonatomic, assign) double brightnessLevel;        // 0..1

@property (nonatomic, assign) BOOL enableSpoofLowPowerMode;
@property (nonatomic, assign) BOOL lowPowerModeEnabled;

@property (nonatomic, assign) BOOL enableSpoofOrientation;
@property (nonatomic, assign) NSInteger orientation;         // UIDeviceOrientation raw

@property (nonatomic, assign) BOOL enableSpoofProximity;
@property (nonatomic, assign) BOOL proximityState;

@property (nonatomic, assign) BOOL enableSpoofGyroscope;     // random x/y/z each read

#pragma mark Locale / TimeZone

@property (nonatomic, assign) BOOL enableSpoofLocale;
@property (nonatomic, copy) NSString *localeID;
@property (nonatomic, assign) BOOL enableSpoofTimeZone;
@property (nonatomic, copy) NSString *timeZoneID;

#pragma mark Identifiers (IDFV / IDFA / DeviceCheck / iCloud)

@property (nonatomic, assign) BOOL enableSpoofVendorID;
@property (nonatomic, copy) NSString *vendorID;
@property (nonatomic, assign) BOOL enableSpoofAdvertisingID;
@property (nonatomic, copy) NSString *advertisingID;
@property (nonatomic, assign) BOOL enableSpoofDeviceCheck;
@property (nonatomic, assign) BOOL enableSpoofCloudToken;

#pragma mark Mail / Messages / Screenshot / Anti-detection

@property (nonatomic, assign) BOOL enableSpoofMail;          // canSendMail
@property (nonatomic, assign) BOOL mailAvailable;
@property (nonatomic, assign) BOOL enableSpoofMessage;       // canSendText
@property (nonatomic, assign) BOOL messageAvailable;
@property (nonatomic, assign) BOOL enableSpoofScreenshot;    // suppress UIApplicationUserDidTakeScreenshot
@property (nonatomic, assign) BOOL enableDisableDetection;   // anti-anti-jailbreak

#pragma mark Proxy (per-container HTTPS)

@property (nonatomic, copy) NSString *proxyHost;
@property (nonatomic, assign) NSInteger proxyPort;
@property (nonatomic, copy) NSString *proxyUsername;
@property (nonatomic, copy) NSString *proxyPassword;

#pragma mark - Persistence

+ (NSArray<MiOSContainer *> *)loadAll;
+ (void)saveAll:(NSArray<MiOSContainer *> *)containers;
+ (NSString *)activeContainerID;
+ (void)setActiveContainerID:(NSString *)containerID;
+ (MiOSContainer *)activeContainer;
// The permanent base container id. Default = the real device (no spoof) but a fully isolated,
// wipeable sandbox — and it is ALWAYS the active container when nothing else is selected.
+ (NSString *)defaultContainerID;
+ (MiOSContainer *)ensureDefaultContainer;        // create-if-missing, returns the Default container
+ (MiOSContainer *)activeOrDefaultContainer;      // active container, or Default (made active) if none
+ (MiOSContainer *)containerWithID:(NSString *)containerID;
+ (void)removeContainerWithID:(NSString *)containerID;
+ (void)resetAll;   // wipe every container and settings — "Reset miOS"

- (void)save;

#pragma mark - Factory / randomizers

+ (MiOSContainer *)newRandomContainerNamed:(NSString *)name;
- (void)applyDeviceModelIdentifier:(NSString *)identifier iosVersion:(NSString *)iosVersion;
- (void)randomizeAllModules;             // "Random data for all modules"
- (void)randomizeModule:(NSString *)key; // "Random data for the %@ module only"
- (void)randomizeIdentifiers;
- (void)randomizeCarrier;
- (void)randomizeWiFi;
- (void)randomizeLocale;
- (void)randomizeCellular;
- (void)randomizeKernelVersion;

#pragma mark - Runtime (consumed by hooks)

- (NSString *)containerRootEnsureCreated:(BOOL)create;
- (NSDictionary *)spoofPrefs;

- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end
