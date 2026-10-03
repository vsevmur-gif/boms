#import <Foundation/Foundation.h>

// A single known iPhone model + its realistic hardware fingerprint values.
@interface MiOSDeviceModel : NSObject
@property (nonatomic, copy) NSString *identifier;      // e.g. iPhone15,2  (hw.machine / ProductType)
@property (nonatomic, copy) NSString *displayName;     // e.g. "iPhone 14 Pro"
@property (nonatomic, copy) NSString *hwModel;         // e.g. D73AP       (hw.model / HardwarePlatform)
@property (nonatomic, copy) NSString *minIOS;
@property (nonatomic, copy) NSString *maxIOS;
@property (nonatomic, copy) NSString *sfSymbol;
@property (nonatomic, copy) NSString *chipName;
@property (nonatomic, assign) NSInteger ramGB;
@property (nonatomic, assign) NSInteger cpuCores;
@property (nonatomic, strong) NSArray<NSNumber *> *storageOptions;
@end

@interface MiOSDeviceDatabase : NSObject
+ (NSArray<MiOSDeviceModel *> *)allDevices;
+ (MiOSDeviceModel *)deviceForIdentifier:(NSString *)identifier;
+ (NSArray<NSString *> *)supportedIOSVersionsForDevice:(MiOSDeviceModel *)device;
+ (NSArray<NSString *> *)allIOSVersions;
@end
