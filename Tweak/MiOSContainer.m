#import "MiOSContainer.h"
#import "MiOSDeviceDB.h"
#import "MiOSCrypt.h"

#pragma mark - Real sandbox HOME (captured before container redirect)

static NSString *gMiOSRealHome = nil;
void MiOSSetRealHome(NSString *home) { if (home.length) gMiOSRealHome = [home copy]; }
NSString *MiOSRealHome(void) {
    if (gMiOSRealHome.length) return gMiOSRealHome;
    const char *h = getenv("MIOS_REAL_HOME");
    if (h) return [NSString stringWithUTF8String:h];
    return NSHomeDirectory();
}
NSString *MiOSBaseDir(void) {
    NSString *dir = [[MiOSRealHome() stringByAppendingPathComponent:@"Documents"]
                     stringByAppendingPathComponent:@"miOS"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

#pragma mark - Encrypted-plist I/O helper

static NSDictionary *miosReadPlist(NSString *path) {
    NSData *blob = [NSData dataWithContentsOfFile:path];
    if (blob.length == 0) return @{};
    // The ciphertext is version-tagged (byte 0 == 0x01); fall back to plain plist for migrations.
    NSData *plain = ((const uint8_t *)blob.bytes)[0] == 0x01 ? [MiOSCrypt decrypt:blob] : blob;
    if (plain.length == 0) plain = blob;
    id obj = [NSPropertyListSerialization propertyListWithData:plain options:0 format:NULL error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}
static void miosWritePlist(NSDictionary *dict, NSString *path) {
    NSData *plain = [NSPropertyListSerialization dataWithPropertyList:(dict ?: @{})
                                                               format:NSPropertyListBinaryFormat_v1_0
                                                              options:0 error:NULL];
    NSData *enc = [MiOSCrypt encrypt:plain] ?: plain;
    [enc writeToFile:path atomically:YES];
}

static NSString *kListPath(void)   { return [MiOSBaseDir() stringByAppendingPathComponent:@"miOS.container-list.plist"]; }
static NSString *kConfigPath(void) { return [MiOSBaseDir() stringByAppendingPathComponent:@"miOS.container-config.plist"]; }

@implementation MiOSContainer

#pragma mark - Persistence

+ (NSArray<MiOSContainer *> *)loadAll {
    NSArray *dicts = miosReadPlist(kListPath())[@"containers"];
    if (![dicts isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *d in dicts)
        if ([d isKindOfClass:[NSDictionary class]])
            [out addObject:[[MiOSContainer alloc] initWithDictionary:d]];
    return out;
}

+ (void)saveAll:(NSArray<MiOSContainer *> *)containers {
    NSMutableArray *dicts = [NSMutableArray array];
    for (MiOSContainer *c in containers) [dicts addObject:[c toDictionary]];
    NSMutableDictionary *list = [miosReadPlist(kListPath()) mutableCopy];
    list[@"containers"] = dicts;
    miosWritePlist(list, kListPath());
}

+ (NSString *)activeContainerID {
    id v = miosReadPlist(kConfigPath())[@"activeContainerID"];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
+ (void)setActiveContainerID:(NSString *)containerID {
    NSMutableDictionary *cfg = [miosReadPlist(kConfigPath()) mutableCopy];
    if (containerID.length) cfg[@"activeContainerID"] = containerID;
    else [cfg removeObjectForKey:@"activeContainerID"];
    miosWritePlist(cfg, kConfigPath());
}
+ (MiOSContainer *)containerWithID:(NSString *)containerID {
    if (containerID.length == 0) return nil;
    for (MiOSContainer *c in [self loadAll])
        if ([c.identifier isEqualToString:containerID]) return c;
    return nil;
}
+ (MiOSContainer *)activeContainer {
    return [self containerWithID:[self activeContainerID]];
}
+ (NSString *)defaultContainerID { return @"default"; }
+ (MiOSContainer *)ensureDefaultContainer {
    MiOSContainer *d = [self containerWithID:[self defaultContainerID]];
    if (d) return d;
    d = [[MiOSContainer alloc] initWithDictionary:@{}];
    d.identifier  = [self defaultContainerID];
    d.name        = @"Default";
    d.enableSpoof = NO;                 // Default = the REAL device/iOS, no fingerprint spoofing
    [d save];
    return d;
}
// Always hand back a container to isolate into. If the user has never picked one, make Default
// the active base container (so the app launches into Default, not an un-isolated pass-through
// where accounts would land in the real, shared, reinstall-surviving keychain).
+ (MiOSContainer *)activeOrDefaultContainer {
    MiOSContainer *a = [self activeContainer];
    if (a) return a;
    // The selected container id resolved to nothing (never saved, or wiped on reinstall). Falling
    // back to Default means NO spoof — log it loudly so this isn't mistaken for a broken spoof.
    NSString *wanted = [self activeContainerID];
    if (wanted.length)
        NSLog(@"[miOS-iso] WARNING active container id=%@ not found on disk — falling back to Default (NO spoof). Re-activate your spoof container.", wanted);
    MiOSContainer *d = [self ensureDefaultContainer];
    [self setActiveContainerID:d.identifier];
    return d;
}
- (void)save {
    NSMutableArray<MiOSContainer *> *all = [[MiOSContainer loadAll] mutableCopy];
    NSUInteger idx = NSNotFound;
    for (NSUInteger i = 0; i < all.count; i++) {
        MiOSContainer *c = all[i];
        if ([c.identifier isEqualToString:self.identifier]) { idx = i; break; }
    }
    if (idx == NSNotFound) [all addObject:self]; else all[idx] = self;
    [MiOSContainer saveAll:all];
}

+ (void)removeContainerWithID:(NSString *)containerID {
    if (containerID.length == 0) return;
    NSMutableArray<MiOSContainer *> *all = [[self loadAll] mutableCopy];
    MiOSContainer *removed = nil;
    for (MiOSContainer *c in all) if ([c.identifier isEqualToString:containerID]) { removed = c; break; }
    if (!removed) return;
    NSString *root = [removed containerRootEnsureCreated:NO];
    if (root.length) [[NSFileManager defaultManager] removeItemAtPath:root error:nil];
    [all removeObject:removed];
    [self saveAll:all];
    if ([[self activeContainerID] isEqualToString:containerID]) {
        MiOSContainer *next = all.firstObject;
        [self setActiveContainerID:next.identifier];
    }
}

+ (void)resetAll {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:[MiOSBaseDir() stringByAppendingPathComponent:@"c"] error:nil];
    [fm removeItemAtPath:kListPath() error:nil];
    [fm removeItemAtPath:kConfigPath() error:nil];
    // Keep the device password so re-adding containers remains readable.
}

#pragma mark - Runtime

- (NSString *)containerRootEnsureCreated:(BOOL)create {
    if (self.identifier.length == 0) return nil;
    NSString *root = [[[MiOSBaseDir() stringByAppendingPathComponent:@"c"]
                       stringByAppendingPathComponent:self.identifier] copy];
    if (create) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *subdirs = @[@"Documents", @"Library", @"Library/Preferences", @"Library/Caches",
                             @"Library/Application Support", @"Library/Cookies", @"Library/SplashBoard",
                             @"Library/WebKit", @"SystemData", @"tmp", @"StoreKit"];
        for (NSString *sub in subdirs)
            [fm createDirectoryAtPath:[root stringByAppendingPathComponent:sub]
          withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return root;
}

- (NSDictionary *)spoofPrefs { return [self toDictionary]; }

#pragma mark - Serialization

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if ((self = [super init])) {
        _identifier = dict[@"id"] ?: [[NSUUID UUID] UUIDString];
        _name = dict[@"name"] ?: @"Container";
        _persistentDeviceID = dict[@"persistentDeviceID"] ?: @"";

        _enableSpoof = [dict[@"enableSpoof"] boolValue];
        _enableLocationMode = [dict[@"enableLocationMode"] boolValue];
        _enableProxy = [dict[@"enableProxy"] boolValue];

        _spoofLocation = [dict[@"spoofLocation"] boolValue];
        _coordinate = CLLocationCoordinate2DMake([dict[@"latitude"] doubleValue], [dict[@"longitude"] doubleValue]);
        _altitude = [dict[@"altitude"] doubleValue];
        _horizontalAccuracy = dict[@"horizontalAccuracy"] ? [dict[@"horizontalAccuracy"] doubleValue] : 5.0;
        _speed = dict[@"speed"] ? [dict[@"speed"] doubleValue] : -1;
        _course = dict[@"course"] ? [dict[@"course"] doubleValue] : -1;
        _locationName = dict[@"locationName"] ?: @"";
        _locationCountryCode = dict[@"locationCountryCode"] ?: @"";

        _enableSpoofDeviceModel = [dict[@"enableSpoofDeviceModel"] boolValue];
        _deviceIdentifier = dict[@"deviceIdentifier"] ?: @"";
        _deviceDisplayName = dict[@"deviceDisplayName"] ?: @"";
        _deviceHardwareModel = dict[@"deviceHardwareModel"] ?: @"";
        _deviceStorageGB = [dict[@"deviceStorageGB"] integerValue];
        _chipName = dict[@"chipName"] ?: @"";

        _enableSpoofDeviceName = [dict[@"enableSpoofDeviceName"] boolValue];
        _deviceName = dict[@"deviceName"] ?: @"";

        _enableSpoofSoftwareVersion = [dict[@"enableSpoofSoftwareVersion"] boolValue];
        _iosVersion = dict[@"iosVersion"] ?: @"";

        _enableSpoofKernelVersion = [dict[@"enableSpoofKernelVersion"] boolValue];
        _kernelVersion = dict[@"kernelVersion"] ?: @"";

        _enableSpoofMemory = [dict[@"enableSpoofMemory"] boolValue];
        _ramGB = [dict[@"ramGB"] integerValue];

        _enableSpoofProcessor = [dict[@"enableSpoofProcessor"] boolValue];
        _cpuCores = [dict[@"cpuCores"] integerValue];

        _enableSpoofCarrier = [dict[@"enableSpoofCarrier"] boolValue];
        _carrierName = dict[@"carrierName"] ?: @"";
        _carrierMCC = dict[@"carrierMCC"] ?: @"";
        _carrierMNC = dict[@"carrierMNC"] ?: @"";
        _carrierCountryCode = dict[@"carrierCountryCode"] ?: @"";
        _carrierFlag = dict[@"carrierFlag"] ?: @"";

        _enableSpoofCellularType = [dict[@"enableSpoofCellularType"] boolValue];
        _cellularType = dict[@"cellularType"] ?: @"";

        _enableSpoofCellular = [dict[@"enableSpoofCellular"] boolValue];
        _cellularAddress = dict[@"cellularAddress"] ?: @"";

        _enableSpoofWiFi = [dict[@"enableSpoofWiFi"] boolValue];
        _wifiSSID = dict[@"wifiSSID"] ?: @"";
        _wifiBSSID = dict[@"wifiBSSID"] ?: @"";
        _wifiAddress = dict[@"wifiAddress"] ?: @"";

        _enableSpoofBatteryLevel = [dict[@"enableSpoofBatteryLevel"] boolValue];
        _batteryLevel = dict[@"batteryLevel"] ? [dict[@"batteryLevel"] integerValue] : 100;
        _enableSpoofBatteryState = [dict[@"enableSpoofBatteryState"] boolValue];
        _batteryState = [dict[@"batteryState"] integerValue];

        _enableSpoofBrightness = [dict[@"enableSpoofBrightness"] boolValue];
        _brightnessLevel = dict[@"brightnessLevel"] ? [dict[@"brightnessLevel"] doubleValue] : 0.5;

        _enableSpoofLowPowerMode = [dict[@"enableSpoofLowPowerMode"] boolValue];
        _lowPowerModeEnabled = [dict[@"lowPowerModeEnabled"] boolValue];

        _enableSpoofOrientation = [dict[@"enableSpoofOrientation"] boolValue];
        _orientation = [dict[@"orientation"] integerValue];

        _enableSpoofProximity = [dict[@"enableSpoofProximity"] boolValue];
        _proximityState = [dict[@"proximityState"] boolValue];

        _enableSpoofGyroscope = [dict[@"enableSpoofGyroscope"] boolValue];

        _enableSpoofLocale = [dict[@"enableSpoofLocale"] boolValue];
        _localeID = dict[@"localeID"] ?: @"";
        _enableSpoofTimeZone = [dict[@"enableSpoofTimeZone"] boolValue];
        _timeZoneID = dict[@"timeZoneID"] ?: @"";

        _enableSpoofVendorID = [dict[@"enableSpoofVendorID"] boolValue];
        _vendorID = dict[@"vendorID"] ?: @"";
        _enableSpoofAdvertisingID = [dict[@"enableSpoofAdvertisingID"] boolValue];
        _advertisingID = dict[@"advertisingID"] ?: @"";
        _enableSpoofDeviceCheck = [dict[@"enableSpoofDeviceCheck"] boolValue];
        _enableSpoofCloudToken = [dict[@"enableSpoofCloudToken"] boolValue];

        _enableSpoofMail = [dict[@"enableSpoofMail"] boolValue];
        _mailAvailable = [dict[@"mailAvailable"] boolValue];
        _enableSpoofMessage = [dict[@"enableSpoofMessage"] boolValue];
        _messageAvailable = [dict[@"messageAvailable"] boolValue];
        _enableSpoofScreenshot = [dict[@"enableSpoofScreenshot"] boolValue];
        _enableDisableDetection = [dict[@"enableDisableDetection"] boolValue];

        _proxyHost = dict[@"proxyHost"] ?: @"";
        _proxyPort = [dict[@"proxyPort"] integerValue];
        _proxyUsername = dict[@"proxyUsername"] ?: @"";
        _proxyPassword = dict[@"proxyPassword"] ?: @"";
    }
    return self;
}

- (NSDictionary *)toDictionary {
    return @{
        @"id": self.identifier ?: @"",
        @"name": self.name ?: @"",
        @"persistentDeviceID": self.persistentDeviceID ?: @"",
        @"enableSpoof": @(self.enableSpoof),
        @"enableLocationMode": @(self.enableLocationMode),
        @"enableProxy": @(self.enableProxy),
        @"spoofLocation": @(self.spoofLocation),
        @"latitude": @(self.coordinate.latitude),
        @"longitude": @(self.coordinate.longitude),
        @"altitude": @(self.altitude),
        @"horizontalAccuracy": @(self.horizontalAccuracy),
        @"speed": @(self.speed), @"course": @(self.course),
        @"locationName": self.locationName ?: @"",
        @"locationCountryCode": self.locationCountryCode ?: @"",
        @"enableSpoofDeviceModel": @(self.enableSpoofDeviceModel),
        @"deviceIdentifier": self.deviceIdentifier ?: @"",
        @"deviceDisplayName": self.deviceDisplayName ?: @"",
        @"deviceHardwareModel": self.deviceHardwareModel ?: @"",
        @"deviceStorageGB": @(self.deviceStorageGB),
        @"chipName": self.chipName ?: @"",
        @"enableSpoofDeviceName": @(self.enableSpoofDeviceName),
        @"deviceName": self.deviceName ?: @"",
        @"enableSpoofSoftwareVersion": @(self.enableSpoofSoftwareVersion),
        @"iosVersion": self.iosVersion ?: @"",
        @"enableSpoofKernelVersion": @(self.enableSpoofKernelVersion),
        @"kernelVersion": self.kernelVersion ?: @"",
        @"enableSpoofMemory": @(self.enableSpoofMemory), @"ramGB": @(self.ramGB),
        @"enableSpoofProcessor": @(self.enableSpoofProcessor), @"cpuCores": @(self.cpuCores),
        @"enableSpoofCarrier": @(self.enableSpoofCarrier),
        @"carrierName": self.carrierName ?: @"", @"carrierMCC": self.carrierMCC ?: @"",
        @"carrierMNC": self.carrierMNC ?: @"", @"carrierCountryCode": self.carrierCountryCode ?: @"",
        @"carrierFlag": self.carrierFlag ?: @"",
        @"enableSpoofCellularType": @(self.enableSpoofCellularType),
        @"cellularType": self.cellularType ?: @"",
        @"enableSpoofCellular": @(self.enableSpoofCellular),
        @"cellularAddress": self.cellularAddress ?: @"",
        @"enableSpoofWiFi": @(self.enableSpoofWiFi),
        @"wifiSSID": self.wifiSSID ?: @"", @"wifiBSSID": self.wifiBSSID ?: @"",
        @"wifiAddress": self.wifiAddress ?: @"",
        @"enableSpoofBatteryLevel": @(self.enableSpoofBatteryLevel), @"batteryLevel": @(self.batteryLevel),
        @"enableSpoofBatteryState": @(self.enableSpoofBatteryState), @"batteryState": @(self.batteryState),
        @"enableSpoofBrightness": @(self.enableSpoofBrightness), @"brightnessLevel": @(self.brightnessLevel),
        @"enableSpoofLowPowerMode": @(self.enableSpoofLowPowerMode), @"lowPowerModeEnabled": @(self.lowPowerModeEnabled),
        @"enableSpoofOrientation": @(self.enableSpoofOrientation), @"orientation": @(self.orientation),
        @"enableSpoofProximity": @(self.enableSpoofProximity), @"proximityState": @(self.proximityState),
        @"enableSpoofGyroscope": @(self.enableSpoofGyroscope),
        @"enableSpoofLocale": @(self.enableSpoofLocale), @"localeID": self.localeID ?: @"",
        @"enableSpoofTimeZone": @(self.enableSpoofTimeZone), @"timeZoneID": self.timeZoneID ?: @"",
        @"enableSpoofVendorID": @(self.enableSpoofVendorID), @"vendorID": self.vendorID ?: @"",
        @"enableSpoofAdvertisingID": @(self.enableSpoofAdvertisingID), @"advertisingID": self.advertisingID ?: @"",
        @"enableSpoofDeviceCheck": @(self.enableSpoofDeviceCheck),
        @"enableSpoofCloudToken": @(self.enableSpoofCloudToken),
        @"enableSpoofMail": @(self.enableSpoofMail), @"mailAvailable": @(self.mailAvailable),
        @"enableSpoofMessage": @(self.enableSpoofMessage), @"messageAvailable": @(self.messageAvailable),
        @"enableSpoofScreenshot": @(self.enableSpoofScreenshot),
        @"enableDisableDetection": @(self.enableDisableDetection),
        @"proxyHost": self.proxyHost ?: @"", @"proxyPort": @(self.proxyPort),
        @"proxyUsername": self.proxyUsername ?: @"", @"proxyPassword": self.proxyPassword ?: @"",
    };
}

#pragma mark - Factory / randomizers

static uint32_t rnd(uint32_t n) { return n ? arc4random_uniform(n) : 0; }

static NSString *randHex(NSUInteger bytes) {
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < bytes; i++) [s appendFormat:@"%02x", arc4random_uniform(256)];
    return s;
}

static NSString *randIPv4(void) {
    // Pick from a realistic public-ish pool, avoiding the obvious private ranges.
    NSArray *first = @[@74, @76, @99, @108, @172, @173, @184, @204];
    return [NSString stringWithFormat:@"%@.%u.%u.%u",
            first[rnd((uint32_t)first.count)], rnd(254)+1, rnd(254)+1, rnd(254)+1];
}

- (void)applyDeviceModelIdentifier:(NSString *)identifier iosVersion:(NSString *)iosVersion {
    MiOSDeviceModel *m = [MiOSDeviceDatabase deviceForIdentifier:identifier];
    if (!m) return;
    self.enableSpoofDeviceModel = YES;
    self.enableSpoofMemory = YES;
    self.enableSpoofProcessor = YES;
    self.enableSpoofSoftwareVersion = YES;
    self.deviceIdentifier = m.identifier;
    self.deviceDisplayName = m.displayName;
    self.deviceHardwareModel = m.hwModel;
    self.chipName = m.chipName;
    self.ramGB = m.ramGB;
    self.cpuCores = m.cpuCores;
    if (m.storageOptions.count)
        self.deviceStorageGB = m.storageOptions[rnd((uint32_t)m.storageOptions.count)].integerValue;
    NSArray<NSString *> *vers = [MiOSDeviceDatabase supportedIOSVersionsForDevice:m];
    if (iosVersion.length && [vers containsObject:iosVersion]) self.iosVersion = iosVersion;
    else if (vers.count) self.iosVersion = vers[rnd((uint32_t)vers.count)];
    [self randomizeKernelVersion];
}

- (void)randomizeKernelVersion {
    // Darwin kernel string that an iPhone would print.
    NSArray *roots = @[@"Darwin Kernel Version 22.6.0", @"Darwin Kernel Version 23.0.0",
                       @"Darwin Kernel Version 23.5.0", @"Darwin Kernel Version 24.0.0"];
    NSString *root = roots[rnd((uint32_t)roots.count)];
    // Fake build date — a weekday month ago-ish, random time.
    NSArray *months = @[@"Jan", @"Feb", @"Mar", @"Apr", @"May", @"Jun",
                       @"Jul", @"Aug", @"Sep", @"Oct", @"Nov", @"Dec"];
    self.kernelVersion = [NSString stringWithFormat:
        @"%@: %@ %u %u:%02u:%02u PDT %u; root:xnu-%u.%u.%u~%u/RELEASE_ARM64_T%04u",
        root, months[rnd(12)], rnd(28)+1, rnd(24), rnd(60), rnd(60), 2023 + rnd(2),
        10000 + rnd(2000), rnd(300), rnd(10), rnd(20), 8000 + rnd(2000)];
    self.enableSpoofKernelVersion = YES;
}

- (void)randomizeIdentifiers {
    self.enableSpoofVendorID = YES;      self.vendorID = [NSUUID UUID].UUIDString;
    self.enableSpoofAdvertisingID = YES; self.advertisingID = [NSUUID UUID].UUIDString;
    self.enableSpoofDeviceCheck = YES;
    self.enableSpoofCloudToken = YES;
    self.persistentDeviceID = randHex(16);
}

- (void)randomizeCarrier {
    static NSArray *carriers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        carriers = @[
            @[@"Verizon",  @"311", @"480", @"us", @"🇺🇸"], @[@"AT&T", @"310", @"410", @"us", @"🇺🇸"],
            @[@"T-Mobile", @"310", @"260", @"us", @"🇺🇸"], @[@"Vodafone", @"234", @"15",  @"gb", @"🇬🇧"],
            @[@"O2",       @"234", @"10",  @"gb", @"🇬🇧"], @[@"Orange", @"208", @"01", @"fr", @"🇫🇷"],
            @[@"Telekom",  @"262", @"01",  @"de", @"🇩🇪"], @[@"MTS", @"250", @"01", @"ru", @"🇷🇺"],
            @[@"Beeline",  @"250", @"99",  @"ru", @"🇷🇺"], @[@"Rogers", @"302", @"720", @"ca", @"🇨🇦"],
        ];
    });
    NSArray *c = carriers[rnd((uint32_t)carriers.count)];
    self.enableSpoofCarrier = YES;
    self.carrierName = c[0]; self.carrierMCC = c[1]; self.carrierMNC = c[2];
    self.carrierCountryCode = c[3]; self.carrierFlag = c[4];
    self.enableSpoofCellularType = YES;
    NSArray *types = @[@"3G", @"4G", @"LTE", @"5G"];
    self.cellularType = types[rnd((uint32_t)types.count)];
    self.enableSpoofCellular = YES;
    self.cellularAddress = randIPv4();
}

- (void)randomizeWiFi {
    self.enableSpoofWiFi = YES;
    NSArray *bases = @[@"Home", @"WiFi", @"NETGEAR", @"TP-Link", @"Linksys", @"iPhone", @"ASUS", @"Xfinity"];
    self.wifiSSID = [NSString stringWithFormat:@"%@-%04X",
                     bases[rnd((uint32_t)bases.count)], rnd(0xFFFF)];
    NSString *h = randHex(6);
    self.wifiBSSID = [NSString stringWithFormat:@"%@:%@:%@:%@:%@:%@",
        [h substringWithRange:NSMakeRange(0,2)], [h substringWithRange:NSMakeRange(2,2)],
        [h substringWithRange:NSMakeRange(4,2)], [h substringWithRange:NSMakeRange(6,2)],
        [h substringWithRange:NSMakeRange(8,2)], [h substringWithRange:NSMakeRange(10,2)]];
    self.wifiAddress = randIPv4();
}

- (void)randomizeLocale {
    static NSArray *locales = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        locales = @[
            @[@"en_US", @"America/New_York"], @[@"en_US", @"America/Los_Angeles"],
            @[@"en_GB", @"Europe/London"],    @[@"fr_FR", @"Europe/Paris"],
            @[@"de_DE", @"Europe/Berlin"],    @[@"ru_RU", @"Europe/Moscow"],
            @[@"es_ES", @"Europe/Madrid"],    @[@"pt_BR", @"America/Sao_Paulo"],
            @[@"it_IT", @"Europe/Rome"],      @[@"ja_JP", @"Asia/Tokyo"],
        ];
    });
    NSArray *l = locales[rnd((uint32_t)locales.count)];
    self.enableSpoofLocale = YES; self.localeID = l[0];
    self.enableSpoofTimeZone = YES; self.timeZoneID = l[1];
}

- (void)randomizeLocation {
    static NSArray *cities = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cities = @[
            @[@"New York",      @(40.7128),  @(-74.0060),  @"US"],
            @[@"Los Angeles",   @(34.0522),  @(-118.2437), @"US"],
            @[@"London",        @(51.5074),  @(-0.1278),   @"GB"],
            @[@"Paris",         @(48.8566),  @(2.3522),    @"FR"],
            @[@"Berlin",        @(52.5200),  @(13.4050),   @"DE"],
            @[@"Moscow",        @(55.7558),  @(37.6173),   @"RU"],
            @[@"Tokyo",         @(35.6762),  @(139.6503),  @"JP"],
            @[@"Sydney",        @(-33.8688), @(151.2093),  @"AU"],
            @[@"São Paulo",     @(-23.5505), @(-46.6333),  @"BR"],
            @[@"Dubai",         @(25.2048),  @(55.2708),   @"AE"],
            @[@"Toronto",       @(43.6532),  @(-79.3832),  @"CA"],
            @[@"Madrid",        @(40.4168),  @(-3.7038),   @"ES"],
            @[@"Rome",          @(41.9028),  @(12.4964),   @"IT"],
            @[@"Seoul",         @(37.5665),  @(126.9780),  @"KR"],
            @[@"Singapore",     @(1.3521),   @(103.8198),  @"SG"],
            @[@"Istanbul",      @(41.0082),  @(28.9784),   @"TR"],
            @[@"Bangkok",       @(13.7563),  @(100.5018),  @"TH"],
            @[@"Mexico City",   @(19.4326),  @(-99.1332),  @"MX"],
            @[@"Amsterdam",     @(52.3676),  @(4.9041),    @"NL"],
            @[@"Stockholm",     @(59.3293),  @(18.0686),   @"SE"],
        ];
    });
    NSArray *c = cities[rnd((uint32_t)cities.count)];
    double jitterLat = ((double)rnd(2000) - 1000) / 10000.0;
    double jitterLon = ((double)rnd(2000) - 1000) / 10000.0;
    self.spoofLocation = YES;
    self.coordinate = (CLLocationCoordinate2D){
        [c[1] doubleValue] + jitterLat,
        [c[2] doubleValue] + jitterLon
    };
    self.altitude = 10.0 + (double)rnd(200);
    self.horizontalAccuracy = 5.0;
    self.speed = -1;
    self.course = -1;
    self.locationName = c[0];
    self.locationCountryCode = c[3];
}

- (void)randomizeCellular {
    self.enableSpoofCellular = YES; self.cellularAddress = randIPv4();
    self.enableSpoofCellularType = YES;
    NSArray *t = @[@"3G", @"4G", @"LTE", @"5G"]; self.cellularType = t[rnd((uint32_t)t.count)];
}

- (void)randomizeModule:(NSString *)key {
    if ([key isEqualToString:@"device"]) {
        NSArray *all = [MiOSDeviceDatabase allDevices];
        MiOSDeviceModel *m = all[rnd((uint32_t)all.count)];
        [self applyDeviceModelIdentifier:m.identifier iosVersion:nil];
    } else if ([key isEqualToString:@"identifiers"]) [self randomizeIdentifiers];
    else if ([key isEqualToString:@"carrier"]) [self randomizeCarrier];
    else if ([key isEqualToString:@"wifi"]) [self randomizeWiFi];
    else if ([key isEqualToString:@"cellular"]) [self randomizeCellular];
    else if ([key isEqualToString:@"locale"]) [self randomizeLocale];
    else if ([key isEqualToString:@"kernel"]) [self randomizeKernelVersion];
    else if ([key isEqualToString:@"location"]) [self randomizeLocation];
    else if ([key isEqualToString:@"battery"]) {
        self.enableSpoofBatteryLevel = YES;
        self.batteryLevel = 20 + (NSInteger)rnd(80);
        self.enableSpoofBatteryState = YES;
        self.batteryState = 1 + (NSInteger)rnd(3);
    } else if ([key isEqualToString:@"brightness"]) {
        self.enableSpoofBrightness = YES;
        self.brightnessLevel = (double)rnd(100) / 100.0;
    } else if ([key isEqualToString:@"gyroscope"]) {
        self.enableSpoofGyroscope = YES;
    }
}

- (void)randomizeAllModules {
    NSArray *all = [MiOSDeviceDatabase allDevices];
    MiOSDeviceModel *m = all[rnd((uint32_t)all.count)];
    [self applyDeviceModelIdentifier:m.identifier iosVersion:nil];
    [self randomizeIdentifiers];
    [self randomizeCarrier];
    [self randomizeWiFi];
    [self randomizeLocale];
    [self randomizeLocation];
    [self randomizeModule:@"battery"];
    [self randomizeModule:@"brightness"];
    self.enableSpoofGyroscope = YES;
    self.enableSpoofOrientation = NO;         // leave physical orientation alone by default
    self.enableSpoofScreenshot = YES;
    self.enableDisableDetection = YES;
    self.enableSpoofMail = YES;    self.mailAvailable = NO;
    self.enableSpoofMessage = YES; self.messageAvailable = NO;
    self.enableSpoofLowPowerMode = NO;
    self.deviceName = [NSString stringWithFormat:@"iPhone"];
    self.enableSpoofDeviceName = NO;
}

#pragma mark - Token extraction

static NSString *MiOSTokensPathForContainer(MiOSContainer *c) {
    NSString *root = [c containerRootEnsureCreated:YES];
    if (!root.length) return nil;
    return [root stringByAppendingPathComponent:@"Documents/miOS-tokens.plist"];
}

+ (void)recordIGHeaders:(NSDictionary<NSString *, NSString *> *)headers
          forContainerID:(NSString *)containerID {
    if (!headers.count || !containerID.length) return;
    MiOSContainer *c = [MiOSContainer containerWithID:containerID];
    if (!c) return;
    NSString *path = MiOSTokensPathForContainer(c);
    if (!path.length) return;

    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:path];
    if (existing) [merged addEntriesFromDictionary:existing];

    // Only overwrite with non-empty strings so a request that happens to not carry a header
    // doesn't blank out a value we captured earlier.
    for (NSString *k in headers) {
        NSString *v = headers[k];
        if ([v isKindOfClass:[NSString class]] && v.length) merged[k] = v;
    }
    merged[@"_capturedAt"] = @((NSInteger)[[NSDate date] timeIntervalSince1970]);
    [merged writeToFile:path atomically:YES];
}

- (NSDictionary *)capturedIGHeaders {
    NSString *path = MiOSTokensPathForContainer(self);
    if (!path.length) return nil;
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

- (NSString *)extractIAMToken {
    NSDictionary *h = [self capturedIGHeaders];
    if (!h.count) return nil;
    NSString *auth    = h[@"Authorization"]   ?: @"";
    NSString *userID  = h[@"IG-U-DS-USER-ID"] ?: (h[@"X-IG-DS-USER-ID"] ?: @"");
    NSString *mid     = h[@"X-MID"]           ?: @"";
    NSString *claim   = h[@"X-IG-WWW-Claim"]  ?: @"";
    NSString *ua      = h[@"User-Agent"]      ?: @"";
    NSString *devID   = h[@"X-IG-Device-ID"]  ?: @"";
    NSString *family  = h[@"IG-U-IG-DIRECT-REGION-HINT"] ?: @"";

    // Nothing useful yet.
    if (!auth.length && !userID.length && !mid.length) return nil;

    // Nomix-compatible IAM format:
    //   Authorization=Bearer <token>;IG-U-DS-USER-ID=<id>;IG-INTENDED-USER-ID=<id>;X-MID=<mid>;X-IG-WWW-Claim=<claim>;
    NSString *authValue = auth;
    if (authValue.length && ![authValue.lowercaseString hasPrefix:@"bearer "] &&
        ![authValue.lowercaseString hasPrefix:@"ig_u-ds-user-id"]) {
        // Already an IG-style token payload — leave as is.
    }

    NSMutableString *iam = [NSMutableString string];
    if (authValue.length)  [iam appendFormat:@"Authorization=%@;", authValue];
    if (userID.length)     [iam appendFormat:@"IG-U-DS-USER-ID=%@;", userID];
    if (userID.length)     [iam appendFormat:@"IG-INTENDED-USER-ID=%@;", userID];
    if (mid.length)        [iam appendFormat:@"X-MID=%@;", mid];
    if (claim.length)      [iam appendFormat:@"X-IG-WWW-Claim=%@;", claim];
    if (devID.length)      [iam appendFormat:@"X-IG-Device-ID=%@;", devID];
    if (family.length)     [iam appendFormat:@"IG-U-IG-DIRECT-REGION-HINT=%@;", family];
    if (ua.length)         [iam appendFormat:@"|User-Agent=%@", ua];
    return iam.length ? [iam copy] : nil;
}

+ (MiOSContainer *)newRandomContainerNamed:(NSString *)name {
    MiOSContainer *c = [[MiOSContainer alloc] initWithDictionary:@{}];
    c.identifier = [NSUUID UUID].UUIDString;
    c.name = name.length ? name : @"New Container";
    c.enableSpoof = YES;         // Spoof mode on by default
    [c randomizeAllModules];
    return c;
}

@end
