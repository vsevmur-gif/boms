#import "MiOSDeviceDB.h"

@implementation MiOSDeviceModel
@end

@implementation MiOSDeviceDatabase

static MiOSDeviceModel *makeDevice(NSString *ident, NSString *name, NSString *hw,
                                    NSString *minV, NSString *maxV, NSString *sym,
                                    NSString *chip, NSInteger ram, NSInteger cores,
                                    NSArray<NSNumber *> *storage) {
    MiOSDeviceModel *d = [[MiOSDeviceModel alloc] init];
    d.identifier = ident;
    d.displayName = name;
    d.hwModel = hw;
    d.minIOS = minV;
    d.maxIOS = maxV;
    d.sfSymbol = sym;
    d.chipName = chip;
    d.ramGB = ram;
    d.cpuCores = cores;
    d.storageOptions = storage;
    return d;
}

+ (NSArray<MiOSDeviceModel *> *)allDevices {
    static NSArray *devices;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        devices = @[
            makeDevice(@"iPhone9,1",  @"iPhone 7",          @"D10AP",  @"10.0", @"15.8", @"iphone",
                       @"A10 Fusion", 2, 4, @[@32, @128, @256]),
            makeDevice(@"iPhone9,2",  @"iPhone 7 Plus",     @"D11AP",  @"10.0", @"15.8", @"iphone",
                       @"A10 Fusion", 3, 4, @[@32, @128, @256]),
            makeDevice(@"iPhone10,1", @"iPhone 8",          @"D20AP",  @"11.0", @"16.7", @"iphone",
                       @"A11 Bionic", 2, 6, @[@64, @256]),
            makeDevice(@"iPhone10,2", @"iPhone 8 Plus",     @"D21AP",  @"11.0", @"16.7", @"iphone",
                       @"A11 Bionic", 3, 6, @[@64, @256]),
            makeDevice(@"iPhone10,3", @"iPhone X",          @"D22AP",  @"11.0", @"16.7", @"iphone",
                       @"A11 Bionic", 3, 6, @[@64, @256]),
            makeDevice(@"iPhone11,8", @"iPhone XR",         @"N841AP", @"12.0", @"17.7", @"iphone",
                       @"A12 Bionic", 3, 6, @[@64, @128, @256]),
            makeDevice(@"iPhone11,2", @"iPhone XS",         @"D321AP", @"12.0", @"17.7", @"iphone",
                       @"A12 Bionic", 4, 6, @[@64, @256, @512]),
            makeDevice(@"iPhone11,6", @"iPhone XS Max",     @"D331AP", @"12.0", @"17.7", @"iphone",
                       @"A12 Bionic", 4, 6, @[@64, @256, @512]),
            makeDevice(@"iPhone12,1", @"iPhone 11",         @"N104AP", @"13.0", @"18.5", @"iphone",
                       @"A13 Bionic", 4, 6, @[@64, @128, @256]),
            makeDevice(@"iPhone12,3", @"iPhone 11 Pro",     @"D421AP", @"13.0", @"18.5", @"iphone",
                       @"A13 Bionic", 4, 6, @[@64, @256, @512]),
            makeDevice(@"iPhone12,5", @"iPhone 11 Pro Max", @"D431AP", @"13.0", @"18.5", @"iphone",
                       @"A13 Bionic", 4, 6, @[@64, @256, @512]),
            makeDevice(@"iPhone13,1", @"iPhone 12 mini",    @"D52gAP", @"14.1", @"18.5", @"iphone",
                       @"A14 Bionic", 4, 6, @[@64, @128, @256]),
            makeDevice(@"iPhone13,2", @"iPhone 12",         @"D53gAP", @"14.1", @"18.5", @"iphone",
                       @"A14 Bionic", 4, 6, @[@64, @128, @256]),
            makeDevice(@"iPhone13,3", @"iPhone 12 Pro",     @"D53pAP", @"14.1", @"18.5", @"iphone",
                       @"A14 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone13,4", @"iPhone 12 Pro Max", @"D54pAP", @"14.1", @"18.5", @"iphone",
                       @"A14 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone14,4", @"iPhone 13 mini",    @"D16AP",  @"15.0", @"18.5", @"iphone",
                       @"A15 Bionic", 4, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone14,5", @"iPhone 13",         @"D17AP",  @"15.0", @"18.5", @"iphone",
                       @"A15 Bionic", 4, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone14,2", @"iPhone 13 Pro",     @"D63AP",  @"15.0", @"18.5", @"iphone",
                       @"A15 Bionic", 6, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone14,3", @"iPhone 13 Pro Max", @"D64AP",  @"15.0", @"18.5", @"iphone",
                       @"A15 Bionic", 6, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone14,7", @"iPhone 14",         @"D27AP",  @"16.0", @"18.5", @"iphone",
                       @"A15 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone14,8", @"iPhone 14 Plus",    @"D28AP",  @"16.0", @"18.5", @"iphone",
                       @"A15 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone15,2", @"iPhone 14 Pro",     @"D73AP",  @"16.0", @"18.5", @"iphone",
                       @"A16 Bionic", 6, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone15,3", @"iPhone 14 Pro Max", @"D74AP",  @"16.0", @"18.5", @"iphone",
                       @"A16 Bionic", 6, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone15,4", @"iPhone 15",         @"D37AP",  @"17.0", @"18.5", @"iphone",
                       @"A16 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone15,5", @"iPhone 15 Plus",    @"D38AP",  @"17.0", @"18.5", @"iphone",
                       @"A16 Bionic", 6, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone16,1", @"iPhone 15 Pro",     @"D83AP",  @"17.0", @"18.5", @"iphone",
                       @"A17 Pro", 8, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone16,2", @"iPhone 15 Pro Max", @"D84AP",  @"17.0", @"18.5", @"iphone",
                       @"A17 Pro", 8, 6, @[@256, @512, @1024]),
            makeDevice(@"iPhone17,3", @"iPhone 16",         @"D47AP",  @"18.0", @"18.5", @"iphone",
                       @"A18", 8, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone17,4", @"iPhone 16 Plus",    @"D48AP",  @"18.0", @"18.5", @"iphone",
                       @"A18", 8, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone17,1", @"iPhone 16 Pro",     @"D93AP",  @"18.0", @"18.5", @"iphone",
                       @"A18 Pro", 8, 6, @[@128, @256, @512, @1024]),
            makeDevice(@"iPhone17,2", @"iPhone 16 Pro Max", @"D94AP",  @"18.0", @"18.5", @"iphone",
                       @"A18 Pro", 8, 6, @[@256, @512, @1024]),
            makeDevice(@"iPhone18,1", @"iPhone 16e",        @"D57AP",  @"18.3", @"18.5", @"iphone",
                       @"A16", 8, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone18,3", @"iPhone 17 Air",     @"D87AP",  @"18.4", @"18.5", @"iphone",
                       @"A19", 8, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone18,4", @"iPhone 17",         @"D88AP",  @"18.4", @"18.5", @"iphone",
                       @"A19", 8, 6, @[@128, @256, @512]),
            makeDevice(@"iPhone18,5", @"iPhone 17 Pro",     @"D99AP",  @"18.4", @"18.5", @"iphone",
                       @"A19 Pro", 12, 6, @[@256, @512, @1024]),
            makeDevice(@"iPhone18,6", @"iPhone 17 Pro Max", @"D100AP", @"18.4", @"18.5", @"iphone",
                       @"A19 Pro", 12, 6, @[@256, @512, @1024]),
        ];
    });
    return devices;
}

+ (MiOSDeviceModel *)deviceForIdentifier:(NSString *)identifier {
    for (MiOSDeviceModel *d in [self allDevices]) {
        if ([d.identifier isEqualToString:identifier]) return d;
    }
    return nil;
}

+ (NSArray<NSString *> *)allIOSVersions {
    static NSArray *versions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        versions = @[
            @"14.0", @"14.0.1", @"14.1", @"14.2", @"14.2.1", @"14.3", @"14.4", @"14.4.1", @"14.4.2", @"14.5", @"14.5.1", @"14.6", @"14.7", @"14.7.1", @"14.8", @"14.8.1",
            @"15.0", @"15.0.1", @"15.0.2", @"15.1", @"15.1.1", @"15.2", @"15.2.1", @"15.3", @"15.3.1", @"15.4", @"15.4.1", @"15.5", @"15.6", @"15.6.1", @"15.7", @"15.7.1", @"15.7.2", @"15.7.3", @"15.7.4", @"15.7.5", @"15.7.6", @"15.7.7", @"15.7.8", @"15.7.9", @"15.8", @"15.8.1", @"15.8.2", @"15.8.3",
            @"16.0", @"16.0.1", @"16.0.2", @"16.0.3", @"16.1", @"16.1.1", @"16.1.2", @"16.2", @"16.3", @"16.3.1", @"16.4", @"16.4.1", @"16.5", @"16.5.1", @"16.5.2", @"16.6", @"16.6.1", @"16.7", @"16.7.1", @"16.7.2", @"16.7.3", @"16.7.4", @"16.7.5", @"16.7.6", @"16.7.7", @"16.7.8",
            @"17.0", @"17.0.1", @"17.0.2", @"17.0.3", @"17.1", @"17.1.1", @"17.1.2", @"17.2", @"17.2.1", @"17.3", @"17.3.1", @"17.4", @"17.4.1", @"17.5", @"17.5.1", @"17.6", @"17.6.1", @"17.7", @"17.7.1", @"17.7.2",
            @"18.0", @"18.0.1", @"18.1", @"18.1.1", @"18.1.2", @"18.2", @"18.2.1", @"18.3", @"18.3.1", @"18.3.2", @"18.4", @"18.4.1", @"18.5",
        ];
    });
    return versions;
}

static NSInteger compareVersions(NSString *a, NSString *b) {
    NSArray *aParts = [a componentsSeparatedByString:@"."];
    NSArray *bParts = [b componentsSeparatedByString:@"."];
    NSUInteger maxLen = MAX(aParts.count, bParts.count);
    for (NSUInteger i = 0; i < maxLen; i++) {
        NSInteger aVal = i < aParts.count ? [aParts[i] integerValue] : 0;
        NSInteger bVal = i < bParts.count ? [bParts[i] integerValue] : 0;
        if (aVal < bVal) return -1;
        if (aVal > bVal) return 1;
    }
    return 0;
}

+ (NSArray<NSString *> *)supportedIOSVersionsForDevice:(MiOSDeviceModel *)device {
    if (!device) return @[];
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *ver in [self allIOSVersions]) {
        if (compareVersions(ver, device.minIOS) >= 0 && compareVersions(ver, device.maxIOS) <= 0) {
            [result addObject:ver];
        }
    }
    return result;
}

@end
