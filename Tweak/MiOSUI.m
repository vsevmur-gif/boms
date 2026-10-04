#import "MiOSUI.h"
#import "MiOSTheme.h"
#import "MiOSDesign.h"
#import "MiOSContainer.h"
#import "MiOSDeviceDB.h"
#import <MapKit/MapKit.h>
#import <UIKit/UIKit.h>
#import <math.h>

#pragma mark - App identity (single-app build: Instagram)

static NSString *const kMiOSAppBundle = @"com.burbn.instagram";
static NSString *const kMiOSAppName   = @"Instagram";

@interface UIImage (MiOSIconPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

static UIImage *MiOSAppIcon(void) {
    UIImage *img = nil;
    @try {
        if ([UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)])
            img = [UIImage _applicationIconImageForBundleIdentifier:kMiOSAppBundle format:2 scale:[UIScreen mainScreen].scale];
    } @catch (__unused NSException *e) {}
    return img;
}

// Derive the accent from Instagram's icon (→ magenta / orange); fall back to Instagram brand.
static void MiOSApplyAppAccent(void) {
    NSArray<UIColor *> *pal = nil;
    UIImage *icon = MiOSAppIcon();
    if (icon) pal = [MiOSColorExtractor paletteFromImage:icon];
    UIColor *accent, *end;
    if (pal.count >= 2) { accent = pal[0]; end = pal[1]; }
    else if (pal.count == 1) { accent = pal[0]; end = [MiOSColorExtractor accentGradientEndFromColor:pal[0]]; }
    else {
        accent = [UIColor colorWithRed:0.84 green:0.20 blue:0.53 alpha:1.0];   // Instagram magenta
        end    = [UIColor colorWithRed:0.98 green:0.55 blue:0.22 alpha:1.0];   // Instagram orange
    }
    [MiOSTheme setAccent:accent gradientEnd:end];
}

#pragma mark - Helpers

static UIWindow *MiOSKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *s in app.connectedScenes) {
            if (![s isKindOfClass:[UIWindowScene class]]) continue;
            if (s.activationState == UISceneActivationStateUnattached) continue;
            for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
        }
    }
    for (UIWindow *w in app.windows) if (w.isKeyWindow) return w;
    return app.windows.lastObject;
}
static UIViewController *MiOSTopVC(void) {
    UIViewController *vc = MiOSKeyWindow().rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}
static void MiOSRelaunch(NSString *message) {
    UIViewController *top = MiOSTopVC();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restart required"
        message:message ?: @"The container is applied when Instagram launches. The app will close now — reopen it to continue."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Close now" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *x){ exit(0); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Later" style:UIAlertActionStyleCancel handler:nil]];
    [top presentViewController:a animated:YES completion:nil];
}
static UIImpactFeedbackGenerator *MiOSHaptic(void) {
    static UIImpactFeedbackGenerator *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight]; [g prepare]; });
    return g;
}

// Hue helpers for the contrasting location tile (ported from the app's Home VC).
static UIColor *MiOSShiftedHue(UIColor *color, CGFloat shift, CGFloat saturation, CGFloat brightness) {
    CGFloat h, s, b, a;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return color;
    h = fmod(h + shift, 1.0);
    return [UIColor colorWithHue:h saturation:saturation brightness:brightness alpha:1.0];
}
static UIColor *MiOSPartnerHue(UIColor *accent) {
    CGFloat h, s, b, a;
    if (![accent getHue:&h saturation:&s brightness:&b alpha:&a]) return accent;
    BOOL warm = (h < 0.2 || h > 0.85);
    return [UIColor colorWithHue:(warm ? 0.64 : 0.06) saturation:0.60 brightness:0.80 alpha:1.0];
}

#pragma mark - Carrier / country / locale data (Blaze-style)

// name, ISO, flag emoji
static NSArray<NSArray<NSString *> *> *MiOSCountries(void) {
    static NSArray *c; static dispatch_once_t o;
    dispatch_once(&o, ^{
        c = @[
            @[@"United States", @"us", @"🇺🇸"], @[@"United Kingdom", @"gb", @"🇬🇧"],
            @[@"Canada", @"ca", @"🇨🇦"], @[@"France", @"fr", @"🇫🇷"], @[@"Germany", @"de", @"🇩🇪"],
            @[@"Italy", @"it", @"🇮🇹"], @[@"Spain", @"es", @"🇪🇸"], @[@"Russia", @"ru", @"🇷🇺"],
            @[@"Brazil", @"br", @"🇧🇷"], @[@"Japan", @"jp", @"🇯🇵"], @[@"Australia", @"au", @"🇦🇺"],
            @[@"Netherlands", @"nl", @"🇳🇱"], @[@"India", @"in", @"🇮🇳"], @[@"Turkey", @"tr", @"🇹🇷"],
            @[@"Mexico", @"mx", @"🇲🇽"], @[@"UAE", @"ae", @"🇦🇪"], @[@"Sweden", @"se", @"🇸🇪"],
            @[@"Poland", @"pl", @"🇵🇱"],
        ];
    });
    return c;
}
static NSArray<NSString *> *MiOSCountryByISO(NSString *iso) {
    for (NSArray<NSString *> *c in MiOSCountries()) if ([c[1] isEqualToString:iso]) return c;
    return nil;
}
// per-ISO carriers: name, MCC, MNC
static NSArray<NSArray<NSString *> *> *MiOSCarriersForISO(NSString *iso) {
    static NSDictionary *db; static dispatch_once_t o;
    dispatch_once(&o, ^{
        db = @{
            @"us": @[@[@"Verizon", @"311", @"480"], @[@"AT&T", @"310", @"410"], @[@"T-Mobile", @"310", @"260"]],
            @"gb": @[@[@"Vodafone", @"234", @"15"], @[@"O2", @"234", @"10"], @[@"EE", @"234", @"30"], @[@"Three", @"234", @"20"]],
            @"ca": @[@[@"Rogers", @"302", @"720"], @[@"Bell", @"302", @"610"], @[@"Telus", @"302", @"220"]],
            @"fr": @[@[@"Orange", @"208", @"01"], @[@"SFR", @"208", @"10"], @[@"Bouygues", @"208", @"20"], @[@"Free", @"208", @"15"]],
            @"de": @[@[@"Telekom", @"262", @"01"], @[@"Vodafone", @"262", @"02"], @[@"O2", @"262", @"03"]],
            @"it": @[@[@"TIM", @"222", @"01"], @[@"Vodafone", @"222", @"10"], @[@"WindTre", @"222", @"88"]],
            @"es": @[@[@"Movistar", @"214", @"07"], @[@"Vodafone", @"214", @"01"], @[@"Orange", @"214", @"03"]],
            @"ru": @[@[@"MTS", @"250", @"01"], @[@"Beeline", @"250", @"99"], @[@"MegaFon", @"250", @"02"], @[@"Tele2", @"250", @"20"]],
            @"br": @[@[@"Vivo", @"724", @"06"], @[@"Claro", @"724", @"05"], @[@"TIM", @"724", @"04"]],
            @"jp": @[@[@"NTT Docomo", @"440", @"10"], @[@"au", @"440", @"50"], @[@"SoftBank", @"440", @"20"]],
            @"au": @[@[@"Telstra", @"505", @"01"], @[@"Optus", @"505", @"02"], @[@"Vodafone", @"505", @"03"]],
            @"nl": @[@[@"KPN", @"204", @"08"], @[@"Vodafone", @"204", @"04"], @[@"T-Mobile", @"204", @"16"]],
            @"in": @[@[@"Jio", @"405", @"857"], @[@"Airtel", @"404", @"10"], @[@"Vi", @"404", @"11"]],
            @"tr": @[@[@"Turkcell", @"286", @"01"], @[@"Vodafone", @"286", @"02"], @[@"Türk Telekom", @"286", @"03"]],
            @"mx": @[@[@"Telcel", @"334", @"020"], @[@"Movistar", @"334", @"03"], @[@"AT&T", @"334", @"050"]],
            @"ae": @[@[@"Etisalat", @"424", @"02"], @[@"du", @"424", @"03"]],
            @"se": @[@[@"Telia", @"240", @"01"], @[@"Tele2", @"240", @"07"], @[@"Telenor", @"240", @"08"]],
            @"pl": @[@[@"Orange", @"260", @"03"], @[@"Play", @"260", @"06"], @[@"Plus", @"260", @"01"]],
        };
    });
    return db[iso] ?: @[];
}
static NSArray<NSString *> *MiOSCellularTypes(void) {
    return @[@"3G", @"4G", @"LTE", @"5G", @"5G-NSA", @"5G-SA"];
}
// localeID, timezoneID, label
static NSArray<NSArray<NSString *> *> *MiOSLocales(void) {
    static NSArray *l; static dispatch_once_t o;
    dispatch_once(&o, ^{
        l = @[
            @[@"en_US", @"America/New_York", @"English (US) · New York"],
            @[@"en_US", @"America/Los_Angeles", @"English (US) · Los Angeles"],
            @[@"en_GB", @"Europe/London", @"English (UK) · London"],
            @[@"fr_FR", @"Europe/Paris", @"Français · Paris"],
            @[@"de_DE", @"Europe/Berlin", @"Deutsch · Berlin"],
            @[@"it_IT", @"Europe/Rome", @"Italiano · Rome"],
            @[@"es_ES", @"Europe/Madrid", @"Español · Madrid"],
            @[@"ru_RU", @"Europe/Moscow", @"Русский · Moscow"],
            @[@"pt_BR", @"America/Sao_Paulo", @"Português · São Paulo"],
            @[@"ja_JP", @"Asia/Tokyo", @"日本語 · Tokyo"],
            @[@"nl_NL", @"Europe/Amsterdam", @"Nederlands · Amsterdam"],
            @[@"tr_TR", @"Europe/Istanbul", @"Türkçe · Istanbul"],
        ];
    });
    return l;
}

#pragma mark - Protection model (Tracker health check)

@interface MiOSSpoofItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *icon;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) BOOL accessed;   // the app can read this data point
@property (nonatomic, assign) BOOL spoofed;    // the container masks it
@end
@implementation MiOSSpoofItem @end

static MiOSSpoofItem *MiOSItem(NSString *t, NSString *ic, BOOL accessed, BOOL spoofed, NSString *detail) {
    MiOSSpoofItem *i = [MiOSSpoofItem new];
    i.title = t; i.icon = ic; i.accessed = accessed; i.spoofed = spoofed; i.detail = detail;
    return i;
}
static NSArray<MiOSSpoofItem *> *MiOSProtectionItems(MiOSContainer *c) {
    if (!c) return @[];
    return @[
        MiOSItem(@"Vendor ID", @"person.text.rectangle", YES, c.enableSpoofVendorID, c.vendorID),
        MiOSItem(@"Advertising ID", @"a.square", YES, c.enableSpoofAdvertisingID, c.advertisingID),
        MiOSItem(@"iCloud Token", @"icloud", NO, c.enableSpoofCloudToken, nil),
        MiOSItem(@"Device Name", @"textformat", YES, c.enableSpoofDeviceName, c.deviceName),
        MiOSItem(@"Device Model", @"iphone", YES, c.enableSpoofDeviceModel, c.deviceDisplayName),
        MiOSItem(@"Device Checker", @"checkmark.shield", NO, c.enableSpoofDeviceCheck, nil),
        MiOSItem(@"iOS Version", @"gear", YES, c.enableSpoofSoftwareVersion, c.iosVersion),
        MiOSItem(@"Kernel Version", @"terminal", YES, c.enableSpoofKernelVersion, c.kernelVersion),
        MiOSItem(@"Processor", @"cpu", YES, c.enableSpoofProcessor, c.chipName),
        MiOSItem(@"Memory", @"memorychip", YES, c.enableSpoofMemory, c.ramGB > 0 ? [NSString stringWithFormat:@"%ld GB", (long)c.ramGB] : nil),
        MiOSItem(@"Carrier", @"antenna.radiowaves.left.and.right", YES, c.enableSpoofCarrier, c.carrierName),
        MiOSItem(@"Cellular Type", @"dot.radiowaves.right", YES, c.enableSpoofCellularType, c.cellularType),
        MiOSItem(@"Cellular IP", @"network", YES, c.enableSpoofCellular, c.cellularAddress),
        MiOSItem(@"Wi-Fi", @"wifi", YES, c.enableSpoofWiFi, c.wifiSSID),
        MiOSItem(@"Locale", @"globe", YES, c.enableSpoofLocale, c.localeID),
        MiOSItem(@"Time Zone", @"clock", YES, c.enableSpoofTimeZone, c.timeZoneID),
        MiOSItem(@"Battery", @"battery.100", YES, c.enableSpoofBatteryLevel, nil),
        MiOSItem(@"Brightness", @"sun.max", YES, c.enableSpoofBrightness, nil),
        MiOSItem(@"Low Power", @"bolt.slash", YES, c.enableSpoofLowPowerMode, nil),
        MiOSItem(@"Gyroscope", @"gyroscope", YES, c.enableSpoofGyroscope, nil),
        MiOSItem(@"Location", @"location.fill", YES, c.spoofLocation, c.locationName),
    ];
}
static NSInteger MiOSProtectionPercent(MiOSContainer *c) {
    NSArray<MiOSSpoofItem *> *items = MiOSProtectionItems(c);
    if (!items.count) return 0;
    NSInteger on = 0;
    for (MiOSSpoofItem *i in items) if (i.spoofed) on++;
    return (NSInteger)lround((double)on / (double)items.count * 100.0);
}

#pragma mark - Default container

static NSString *const kMiOSDefaultID = @"default";

static BOOL MiOSIsDefault(MiOSContainer *c) { return [c.identifier isEqualToString:kMiOSDefaultID]; }

// The Default container is always present, represents the real device (no spoofing),
// and cannot be renamed or deleted — only its cache can be cleared. Mirrors Blaze.
static MiOSContainer *MiOSEnsureDefault(void) {
    for (MiOSContainer *c in [MiOSContainer loadAll]) if (MiOSIsDefault(c)) return c;
    MiOSContainer *d = [[MiOSContainer alloc] initWithDictionary:@{}];
    d.identifier = kMiOSDefaultID;
    d.name = @"Default";
    d.enableSpoof = NO;
    [d save];
    return d;
}

// Default first, then the rest in load order.
static NSArray<MiOSContainer *> *MiOSSortedContainers(void) {
    MiOSEnsureDefault();
    NSMutableArray *out = [NSMutableArray array];
    MiOSContainer *def = nil;
    for (MiOSContainer *c in [MiOSContainer loadAll]) {
        if (MiOSIsDefault(c)) def = c; else [out addObject:c];
    }
    if (def) [out insertObject:def atIndex:0];
    return out;
}

// Wipe everything inside a container's on-disk data folder (cache, keychain mirror, snapshots).
static void MiOSClearCache(MiOSContainer *m) {
    NSString *root = [m containerRootEnsureCreated:YES];
    if (!root.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    // 1. Wipe the whole container sandbox: Documents, Library (prefs = NSUserDefaults store,
    //    Caches, Cookies, WebKit), and AppGroups (saved logins / "remembered accounts").
    for (NSString *item in [fm contentsOfDirectoryAtPath:root error:nil])
        [fm removeItemAtPath:[root stringByAppendingPathComponent:item] error:nil];
    // 2. Wipe this container's keychain namespace (auth tokens / saved credentials).
    miosWipeContainerKeychain(m.identifier);
    // 3. Legacy cleanup: older builds shared one app-group dir across all containers, which
    //    leaked the "remembered profile" everywhere. Remove that orphaned shared directory.
    [fm removeItemAtPath:[[MiOSRealHome() stringByAppendingPathComponent:@"Documents"]
                           stringByAppendingPathComponent:@"FakeGroupContainers"] error:nil];
}

// Forward declarations — defined with the container row/list helpers further down,
// but used earlier by the device-spoof card.
static UIImage *MiOSDeviceThumb(MiOSContainer *m, UIColor *accent, CGSize size);
static UIView *MiOSIOSBadge(NSString *iosVersion, CGFloat side, UIColor *accent);

#pragma mark - MiOSTapView (block-based tap target)

@interface MiOSTapView : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end
@implementation MiOSTapView
- (instancetype)initWithFrame:(CGRect)f {
    if (self = [super initWithFrame:f]) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_tapped)]];
    }
    return self;
}
- (void)_tapped {
    [MiOSHaptic() impactOccurred];
    [UIView animateWithDuration:0.08 animations:^{ self.transform = CGAffineTransformMakeScale(0.97, 0.97); }
                     completion:^(BOOL f){
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0
                         animations:^{ self.transform = CGAffineTransformIdentity; } completion:nil];
    }];
    if (_onTap) _onTap();
}
@end

#pragma mark - MiOSPillField (editable value pill)

@interface MiOSPillField : UIView
@property (nonatomic, strong, readonly) UITextField *textField;
@property (nonatomic, copy) void (^onChange)(NSString *);
- (instancetype)initWithIcon:(NSString *)icon value:(NSString *)value placeholder:(NSString *)ph;
@end
@implementation MiOSPillField {
    UITextField *_field;
}
- (instancetype)initWithIcon:(NSString *)icon value:(NSString *)value placeholder:(NSString *)ph {
    if (self = [super initWithFrame:CGRectZero]) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        self.layer.cornerRadius = 11; self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0; self.layer.borderColor = [MiOSTheme hairline].CGColor;
        UIImageView *ic = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:icon size:14 color:[MiOSTheme secondaryText]]];
        ic.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:ic];
        _field = [[UITextField alloc] init];
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        _field.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _field.textColor = [MiOSTheme primaryText];
        _field.text = value;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:ph ?: @""
            attributes:@{NSForegroundColorAttributeName: [MiOSTheme tertiaryText]}];
        [_field addTarget:self action:@selector(_changed) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_field];
        [NSLayoutConstraint activateConstraints:@[
            [ic.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [ic.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_field.leadingAnchor constraintEqualToAnchor:ic.trailingAnchor constant:10],
            [_field.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_field.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}
- (UITextField *)textField { return _field; }
- (void)_changed { if (_onChange) _onChange(_field.text ?: @""); }
@end

// Blaze-style random personal device name.
static NSString *MiOSRandomDeviceName(void) {
    NSArray *names = @[@"Alex", @"Sam", @"Jordan", @"Taylor", @"Chris", @"Jamie", @"Morgan", @"Riley",
                       @"Casey", @"Drew", @"Jon", @"Mike", @"Anna", @"Kate", @"Emma", @"Liam", @"Noah",
                       @"Olivia", @"Sophia", @"Lucas", @"Max", @"Leo", @"Mia", @"Zoe"];
    uint32_t r = arc4random_uniform(10);
    NSString *n = names[arc4random_uniform((uint32_t)names.count)];
    if (r < 2) return @"iPhone";
    if (r < 8) return [NSString stringWithFormat:@"%@'s iPhone", n];
    return [NSString stringWithFormat:@"iPhone de %@", n];
}

// Random carrier within an ISO country (or a random country when none chosen).
static void MiOSRandomizeCarrierInCountry(MiOSContainer *m) {
    NSString *iso = m.carrierCountryCode.length ? m.carrierCountryCode : nil;
    if (!iso) {
        NSArray<NSString *> *c = MiOSCountries()[arc4random_uniform((uint32_t)MiOSCountries().count)];
        iso = c[1]; m.carrierCountryCode = c[1]; m.carrierFlag = c[2];
    } else {
        NSArray<NSString *> *c = MiOSCountryByISO(iso);
        if (c) m.carrierFlag = c[2];
    }
    NSArray<NSArray<NSString *> *> *carriers = MiOSCarriersForISO(iso);
    if (carriers.count) {
        NSArray<NSString *> *pick = carriers[arc4random_uniform((uint32_t)carriers.count)];
        m.carrierName = pick[0]; m.carrierMCC = pick[1]; m.carrierMNC = pick[2];
    }
    m.enableSpoofCarrier = YES;
}

#pragma mark - Picker (generic single-choice, nav-bar hosted)

@interface MiOSPickerVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, copy) NSString *selected;
@property (nonatomic, copy) void (^onPick)(NSString *);
@property (nonatomic, strong) UITableView *tableView;
@end
@implementation MiOSPickerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MiOSTheme primaryBackground];
    MiOSNebulaBackgroundView *bg = [[MiOSNebulaBackgroundView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [bg updateAccent:[MiOSTheme accentColor]];
    [self.view addSubview:bg];

    // Custom header with a back control + title (the hosting nav bar is hidden).
    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    UIButton *back = [UIButton buttonWithType:UIButtonTypeSystem];
    [back setImage:[MiOSTheme symbol:@"chevron.left" size:18 color:[MiOSTheme accentColor]] forState:UIControlStateNormal];
    back.translatesAutoresizingMaskIntoConstraints = NO;
    [back addTarget:self action:@selector(_back) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:back];
    UILabel *titleLbl = [UILabel new];
    titleLbl.text = self.title;
    titleLbl.font = [MiOSTheme headlineFont];
    titleLbl.textColor = [MiOSTheme primaryText];
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:titleLbl];

    self.tableView = [[UITableView alloc] init];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.separatorColor = [MiOSTheme separator];
    self.tableView.rowHeight = 50;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:40],
        [back.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:12],
        [back.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [titleLbl.leadingAnchor constraintEqualToAnchor:back.trailingAnchor constant:8],
        [titleLbl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
- (void)_back { [self.navigationController popViewControllerAnimated:YES]; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.options.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"c"];
        c.backgroundColor = [UIColor clearColor];
        c.textLabel.textColor = [MiOSTheme primaryText];
        c.textLabel.font = [MiOSTheme bodyFont];
        c.tintColor = [MiOSTheme accentColor];
        UIView *sel = [UIView new]; sel.backgroundColor = [MiOSTheme tileBackground];
        c.selectedBackgroundView = sel;
    }
    NSString *opt = self.options[ip.row];
    c.textLabel.text = opt;
    c.accessoryType = [opt isEqualToString:self.selected] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [MiOSHaptic() impactOccurred];
    if (self.onPick) self.onPick(self.options[ip.row]);
    [self.navigationController popViewControllerAnimated:YES];
}
@end

#pragma mark - Base scroll page

// Opaque, nebula-backed modal container used for editors (Fingerprint, Location,
// Tracker). Gives them our app's look with a grabber + an X close, instead of the
// system page-sheet's transparency and a "Done" button.
@interface MiOSEditorVC : UIViewController
- (instancetype)initWithPage:(UIViewController *)page title:(NSString *)title;
@end

@interface MiOSPage : UIViewController
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, weak) UINavigationController *host;
- (void)reload;
- (void)clearStack;
- (void)miosPresentEditor:(MiOSPage *)page title:(NSString *)title;
- (void)miosDismissSelf;
@end
@implementation MiOSPage
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    _scroll = [[UIScrollView alloc] init];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _scroll.contentInset = UIEdgeInsetsMake(8, 0, [MiOSFloatingTabBar contentHeight] + 24, 0);
    [self.view addSubview:_scroll];

    _stack = [[UIStackView alloc] init];
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 20;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:16],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-16],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-32],
    ]];
    [self reload];
}
- (void)clearStack { for (UIView *v in _stack.arrangedSubviews.copy) { [_stack removeArrangedSubview:v]; [v removeFromSuperview]; } }
- (void)reload { }
- (void)miosDismissSelf { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)miosPresentEditor:(MiOSPage *)page title:(NSString *)title {
    MiOSEditorVC *vc = [[MiOSEditorVC alloc] initWithPage:page title:title];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = vc.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.preferredCornerRadius = 28;
    }
    [self presentViewController:vc animated:YES completion:nil];
}
@end

@implementation MiOSEditorVC {
    UIViewController *_page;
    NSString *_titleText;
}
- (instancetype)initWithPage:(UIViewController *)page title:(NSString *)title {
    if (self = [super init]) { _page = page; _titleText = [title copy]; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MiOSTheme primaryBackground];
    MiOSNebulaBackgroundView *bg = [[MiOSNebulaBackgroundView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [bg updateAccent:[MiOSTheme accentColor]];
    [self.view addSubview:bg];

    UIView *header = [UIView new];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    UILabel *title = [UILabel new];
    title.text = _titleText;
    title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    title.textColor = [MiOSTheme primaryText];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[MiOSTheme symbol:@"xmark.circle.fill" size:26 color:[UIColor colorWithWhite:1 alpha:0.5]] forState:UIControlStateNormal];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(_close) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:close];

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:_page];
    nav.navigationBar.hidden = YES;
    nav.view.backgroundColor = [UIColor clearColor];
    if ([_page isKindOfClass:[MiOSPage class]]) ((MiOSPage *)_page).host = nav;
    [self addChildViewController:nav];
    nav.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:nav.view];
    [nav didMoveToParentViewController:self];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:g.topAnchor constant:6],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:44],
        [title.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:18],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],
        [close.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [nav.view.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:2],
        [nav.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [nav.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [nav.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}
- (void)_close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

#pragma mark - Spoof (fingerprint) editor

@interface MiOSSpoofPage : MiOSPage
@property (nonatomic, strong) MiOSContainer *container;   // working draft — persisted only on Save
@property (nonatomic, assign) BOOL isNew;
@property (nonatomic, copy) void (^onDone)(void);
- (void)save;
- (MiOSToggleCell *)toggle:(NSString *)title sub:(NSString *)sub icon:(NSString *)icon on:(BOOL)on change:(void(^)(BOOL))change;
- (MiOSNavigationCell *)nav:(NSString *)title sub:(NSString *)sub icon:(NSString *)icon value:(NSString *)value tap:(void(^)(void))tap;
- (void)_pickModel;
- (void)_pickIOS;
- (void)_pickCountry;
- (void)_pickCarrier;
- (void)_pickCellularType;
- (void)_pickLocale;
- (void)_pickTimeZone;
- (void)_pickStorage;
- (void)_pickBatteryLevel;
- (void)_pickBatteryState;
- (void)_pickBrightness;
- (void)_randomizeModuleSheet;
- (void)_saveContainer;
- (UIView *)deviceCard:(MiOSContainer *)m;
- (UIView *)pillRow:(NSString *)icon value:(NSString *)value mono:(BOOL)mono tap:(void(^)(void))tap;
- (UIView *)shuffleButton:(void(^)(void))action;
- (UIView *)choosePill:(NSString *)icon value:(NSString *)value tap:(void(^)(void))tap;
- (UIView *)rowWithPill:(UIView *)pill shuffle:(void(^)(void))shuffle;
@end
@implementation MiOSSpoofPage
- (void)save { }   // draft edits stay in memory; persisted only by Save Container
- (MiOSToggleCell *)toggle:(NSString *)title sub:(NSString *)sub icon:(NSString *)icon on:(BOOL)on change:(void(^)(BOOL))change {
    MiOSToggleCell *c = [[MiOSToggleCell alloc] initWithTitle:title subtitle:sub icon:icon color:[MiOSTheme accentColor] key:title];
    c.isOn = on; c.onChange = change;
    return c;
}
- (MiOSNavigationCell *)nav:(NSString *)title sub:(NSString *)sub icon:(NSString *)icon value:(NSString *)value tap:(void(^)(void))tap {
    MiOSNavigationCell *c = [[MiOSNavigationCell alloc] initWithTitle:title subtitle:sub icon:icon color:[MiOSTheme accentColor]];
    c.valueText = value; c.tapAction = tap;
    return c;
}
- (void)reload {
    [self clearStack];
    MiOSContainer *m = self.container;
    if (!m) return;
    __weak typeof(self) ws = self;

    UILabel *step = [UILabel new];
    step.attributedText = [[NSAttributedString alloc] initWithString:@"CONFIGURE · SPOOFING" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: [MiOSTheme accentColor], NSKernAttributeName: @2.0 }];
    [self.stack addArrangedSubview:step];

    // DEVICE SPOOFING
    MiOSSectionCardView *dev = [[MiOSSectionCardView alloc] initWithTitle:@"Device spoofing"];
    [dev addCellView:[self toggle:@"Enable Device Spoof" sub:@"Spoof device model and iOS version" icon:@"iphone" on:m.enableSpoofDeviceModel change:^(BOOL on){
        ws.container.enableSpoofDeviceModel = on;
        ws.container.enableSpoofSoftwareVersion = on;
        ws.container.enableSpoofMemory = on;
        ws.container.enableSpoofProcessor = on;
        if (on && ws.container.deviceIdentifier.length == 0) {
            NSArray *all = [MiOSDeviceDatabase allDevices];
            if (all.count) { MiOSDeviceModel *d = all[arc4random_uniform((uint32_t)all.count)]; [ws.container applyDeviceModelIdentifier:d.identifier iosVersion:nil]; }
        }
        [ws reload]; }]];
    [self.stack addArrangedSubview:dev];
    if (m.enableSpoofDeviceModel) [self.stack addArrangedSubview:[self deviceCard:m]];

    MiOSSectionCardView *dn = [[MiOSSectionCardView alloc] initWithTitle:nil];
    [dn addCellView:[self toggle:@"Custom Device Name" sub:@"Override the reported device name" icon:@"character.cursor.ibeam" on:m.enableSpoofDeviceName change:^(BOOL on){
        ws.container.enableSpoofDeviceName = on;
        if (on && ws.container.deviceName.length == 0) ws.container.deviceName = MiOSRandomDeviceName();
        [ws reload]; }]];
    if (m.enableSpoofDeviceName) {
        MiOSPillField *nameF = [[MiOSPillField alloc] initWithIcon:@"textformat" value:m.deviceName placeholder:@"iPhone"];
        nameF.onChange = ^(NSString *v){ ws.container.deviceName = v; };
        [dn addCellView:[self rowWithPill:nameF shuffle:^{ ws.container.deviceName = MiOSRandomDeviceName(); ws.container.enableSpoofDeviceName = YES; [ws reload]; }]];
    }
    [self.stack addArrangedSubview:dn];

    // IDENTIFIERS
    MiOSSectionCardView *ids = [[MiOSSectionCardView alloc] initWithTitle:@"Identifiers"];
    [ids addCellView:[self toggle:@"Vendor ID (IDFV)" sub:@"Per-vendor identifier" icon:@"person.text.rectangle" on:m.enableSpoofVendorID change:^(BOOL on){
        ws.container.enableSpoofVendorID = on;
        if (on && ws.container.vendorID.length == 0) ws.container.vendorID = [NSUUID UUID].UUIDString;
        [ws reload]; }]];
    if (m.enableSpoofVendorID) {
        [ids addCellView:[self rowWithPill:[self choosePill:@"number" value:(m.vendorID.length ? m.vendorID : @"—") tap:nil]
                                   shuffle:^{ ws.container.vendorID = [NSUUID UUID].UUIDString; [ws reload]; }]];
    }
    [ids addSeparator];
    [ids addCellView:[self toggle:@"Advertising ID (IDFA)" sub:@"Ad tracking identifier" icon:@"a.square" on:m.enableSpoofAdvertisingID change:^(BOOL on){
        ws.container.enableSpoofAdvertisingID = on;
        if (on && ws.container.advertisingID.length == 0) ws.container.advertisingID = [NSUUID UUID].UUIDString;
        [ws reload]; }]];
    if (m.enableSpoofAdvertisingID) {
        [ids addCellView:[self rowWithPill:[self choosePill:@"number" value:(m.advertisingID.length ? m.advertisingID : @"—") tap:nil]
                                   shuffle:^{ ws.container.advertisingID = [NSUUID UUID].UUIDString; [ws reload]; }]];
    }
    [ids addSeparator];
    [ids addCellView:[self toggle:@"Device Checker" sub:@"DCDevice → unsupported (no hardware token)" icon:@"checkmark.shield" on:m.enableSpoofDeviceCheck change:^(BOOL on){ ws.container.enableSpoofDeviceCheck = on; }]];
    [ids addSeparator];
    [ids addCellView:[self toggle:@"Hide iCloud token" sub:@"ubiquityIdentityToken → nil" icon:@"icloud.slash" on:m.enableSpoofCloudToken change:^(BOOL on){ ws.container.enableSpoofCloudToken = on; }]];
    [self.stack addArrangedSubview:ids];

    // NETWORK & SENSORS
    MiOSSectionCardView *net = [[MiOSSectionCardView alloc] initWithTitle:@"Network & sensors"];
    [net addCellView:[self toggle:@"Carrier Spoof" sub:@"Fake carrier name, MCC/MNC & country" icon:@"antenna.radiowaves.left.and.right" on:m.enableSpoofCarrier change:^(BOOL on){
        ws.container.enableSpoofCarrier = on;
        if (on && ws.container.carrierName.length == 0) MiOSRandomizeCarrierInCountry(ws.container);
        [ws reload]; }]];
    if (m.enableSpoofCarrier) {
        NSArray<NSString *> *country = m.carrierCountryCode.length ? MiOSCountryByISO(m.carrierCountryCode) : nil;
        [net addCellView:[self rowWithPill:[self choosePill:@"flag.fill" value:(country ? [NSString stringWithFormat:@"%@ %@", country[2], country[0]] : @"Choose country") tap:^{ [ws _pickCountry]; }] shuffle:nil]];
        [net addCellView:[self rowWithPill:[self choosePill:@"simcard" value:(m.carrierName.length ? [NSString stringWithFormat:@"%@ %@", m.carrierFlag ?: @"", m.carrierName] : @"Choose carrier") tap:^{ [ws _pickCarrier]; }]
                                   shuffle:^{ MiOSRandomizeCarrierInCountry(ws.container); [ws reload]; }]];
        [net addCellView:[self rowWithPill:[self choosePill:@"dot.radiowaves.right" value:(m.cellularType.length ? m.cellularType : @"Choose type") tap:^{ [ws _pickCellularType]; }] shuffle:nil]];
        MiOSPillField *cip = [[MiOSPillField alloc] initWithIcon:@"network" value:m.cellularAddress placeholder:@"Cellular IP"];
        cip.textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        cip.onChange = ^(NSString *v){ ws.container.cellularAddress = v; ws.container.enableSpoofCellular = v.length > 0; };
        [net addCellView:[self rowWithPill:cip shuffle:^{ [ws.container randomizeCellular]; [ws reload]; }]];
    }
    [net addSeparator];
    [net addCellView:[self toggle:@"Wi-Fi Spoof" sub:@"Fake SSID & BSSID for this container" icon:@"wifi" on:m.enableSpoofWiFi change:^(BOOL on){
        ws.container.enableSpoofWiFi = on;
        if (on && ws.container.wifiSSID.length == 0) [ws.container randomizeWiFi];
        [ws reload]; }]];
    if (m.enableSpoofWiFi) {
        MiOSPillField *ssid = [[MiOSPillField alloc] initWithIcon:@"wifi" value:m.wifiSSID placeholder:@"SSID"];
        ssid.onChange = ^(NSString *v){ ws.container.wifiSSID = v; };
        [net addCellView:[self rowWithPill:ssid shuffle:^{ [ws.container randomizeWiFi]; [ws reload]; }]];
        MiOSPillField *bssid = [[MiOSPillField alloc] initWithIcon:@"dot.radiowaves.left.and.right" value:m.wifiBSSID placeholder:@"BSSID"];
        bssid.onChange = ^(NSString *v){ ws.container.wifiBSSID = v; };
        [net addCellView:[self rowWithPill:bssid shuffle:nil]];
        MiOSPillField *wip = [[MiOSPillField alloc] initWithIcon:@"globe" value:m.wifiAddress placeholder:@"Wi-Fi IP"];
        wip.textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
        wip.onChange = ^(NSString *v){ ws.container.wifiAddress = v; };
        [net addCellView:[self rowWithPill:wip shuffle:nil]];
    }
    [net addSeparator];
    [net addCellView:[self toggle:@"Battery Spoof" sub:@"Report a fixed battery level & state" icon:@"battery.100" on:m.enableSpoofBatteryLevel change:^(BOOL on){
        ws.container.enableSpoofBatteryLevel = on; ws.container.enableSpoofBatteryState = on; [ws reload]; }]];
    if (m.enableSpoofBatteryLevel) {
        [net addCellView:[self rowWithPill:[self choosePill:@"battery.75" value:[NSString stringWithFormat:@"%ld%%", (long)m.batteryLevel] tap:^{ [ws _pickBatteryLevel]; }] shuffle:nil]];
        [net addCellView:[self rowWithPill:[self choosePill:@"bolt.badge.a" value:@[@"Unknown", @"Unplugged", @"Charging", @"Full"][MAX(0, MIN(3, m.batteryState))] tap:^{ [ws _pickBatteryState]; }] shuffle:nil]];
    }
    [net addSeparator];
    [net addCellView:[self toggle:@"Brightness Spoof" sub:@"Report a fixed screen brightness" icon:@"sun.max" on:m.enableSpoofBrightness change:^(BOOL on){ ws.container.enableSpoofBrightness = on; [ws reload]; }]];
    if (m.enableSpoofBrightness)
        [net addCellView:[self rowWithPill:[self choosePill:@"sun.max.fill" value:[NSString stringWithFormat:@"%.0f%%", m.brightnessLevel * 100] tap:^{ [ws _pickBrightness]; }] shuffle:nil]];
    [net addSeparator];
    [net addCellView:[self toggle:@"Time Zone Spoof" sub:@"Override reported system time zone" icon:@"globe" on:m.enableSpoofTimeZone change:^(BOOL on){
        ws.container.enableSpoofTimeZone = on; ws.container.enableSpoofLocale = on;
        if (on && ws.container.timeZoneID.length == 0) [ws.container randomizeLocale];
        [ws reload]; }]];
    if (m.enableSpoofTimeZone) {
        [net addCellView:[self rowWithPill:[self choosePill:@"clock" value:(m.timeZoneID.length ? m.timeZoneID : @"Choose time zone") tap:^{ [ws _pickTimeZone]; }]
                                   shuffle:^{
            NSArray<NSArray<NSString *> *> *ls = MiOSLocales();
            NSArray<NSString *> *l = ls[arc4random_uniform((uint32_t)ls.count)];
            ws.container.timeZoneID = l[1]; ws.container.enableSpoofTimeZone = YES; [ws reload]; }]];
        [net addCellView:[self rowWithPill:[self choosePill:@"character.bubble" value:(m.localeID.length ? m.localeID : @"Choose locale") tap:^{ [ws _pickLocale]; }]
                                   shuffle:^{ [ws.container randomizeLocale]; [ws reload]; }]];
    }
    [net addSeparator];
    [net addCellView:[self toggle:@"Low Power Mode" sub:(m.lowPowerModeEnabled ? @"Reported as enabled" : @"Reported as disabled") icon:@"bolt.slash" on:m.enableSpoofLowPowerMode change:^(BOOL on){ ws.container.enableSpoofLowPowerMode = on; ws.container.lowPowerModeEnabled = on; [ws reload]; }]];
    [net addSeparator];
    [net addCellView:[self toggle:@"Gyroscope" sub:@"Random x / y / z each read" icon:@"gyroscope" on:m.enableSpoofGyroscope change:^(BOOL on){ ws.container.enableSpoofGyroscope = on; }]];
    [self.stack addArrangedSubview:net];

    // SYSTEM & ANTI-DETECTION
    MiOSSectionCardView *sys = [[MiOSSectionCardView alloc] initWithTitle:@"System & anti-detection"];
    [sys addCellView:[self nav:@"Kernel version" sub:(m.enableSpoofKernelVersion ? @"Spoofed — tap to re-roll" : @"Real") icon:@"terminal" value:nil tap:^{ [ws.container randomizeKernelVersion]; [ws reload]; }]];
    [sys addSeparator];
    [sys addCellView:[self toggle:@"Screenshot detection" sub:@"Hide 'screenshot taken' events" icon:@"camera.metering.unknown" on:m.enableSpoofScreenshot change:^(BOOL on){ ws.container.enableSpoofScreenshot = on; }]];
    [sys addSeparator];
    [sys addCellView:[self toggle:@"Mail / Messages availability" sub:@"canSendMail / canSendText → false" icon:@"envelope.badge.shield.half.filled" on:(m.enableSpoofMail && m.enableSpoofMessage) change:^(BOOL on){
        ws.container.enableSpoofMail = on; ws.container.mailAvailable = NO;
        ws.container.enableSpoofMessage = on; ws.container.messageAvailable = NO; }]];
    [sys addSeparator];
    [sys addCellView:[self toggle:@"Disable detection" sub:@"Hide jailbreak probes (Bugsnag etc.)" icon:@"eye.slash" on:m.enableDisableDetection change:^(BOOL on){ ws.container.enableDisableDetection = on; }]];
    [self.stack addArrangedSubview:sys];

    MiOSButtonCell *randAll = [[MiOSButtonCell alloc] initWithTitle:@"Randomize full fingerprint" color:[MiOSTheme accentGradientEnd]];
    randAll.tapAction = ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Randomize full fingerprint?"
            message:@"Replaces every spoofed value for this container with a fresh random one." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Randomize" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){ [m randomizeAllModules]; [ws reload]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ws presentViewController:a animated:YES completion:nil];
    };
    [self.stack addArrangedSubview:randAll];

    MiOSButtonCell *randOne = [[MiOSButtonCell alloc] initWithTitle:@"Randomize a single module…" color:[MiOSTheme accentColor]];
    randOne.tapAction = ^{ [ws _randomizeModuleSheet]; };
    [self.stack addArrangedSubview:randOne];

    // Save Container — nothing is persisted until this is tapped.
    MiOSPrimaryButton *saveBtn = [[MiOSPrimaryButton alloc] initWithTitle:@"Save Container" watermark:@"checkmark"];
    [saveBtn addTarget:self action:@selector(_saveContainer) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:saveBtn];
}

- (void)_saveContainer {
    [self.container save];
    if (self.onDone) self.onDone();
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (UIView *)shuffleButton:(void(^)(void))action {
    MiOSTapView *b = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    b.onTap = action;
    b.backgroundColor = [[MiOSTheme accentColor] colorWithAlphaComponent:0.16];
    b.layer.cornerRadius = 12; b.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *ic = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"shuffle" size:18 color:[MiOSTheme accentColor]]];
    ic.translatesAutoresizingMaskIntoConstraints = NO; [b addSubview:ic];
    [NSLayoutConstraint activateConstraints:@[
        [b.widthAnchor constraintEqualToConstant:46],
        [b.heightAnchor constraintEqualToConstant:46],
        [ic.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
        [ic.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
    ]];
    return b;
}

- (UIView *)choosePill:(NSString *)icon value:(NSString *)value tap:(void(^)(void))tap {
    MiOSTapView *p = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    p.onTap = tap;
    p.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    p.layer.cornerRadius = 11; p.layer.cornerCurve = kCACornerCurveContinuous;
    p.layer.borderWidth = 1.0; p.layer.borderColor = [MiOSTheme hairline].CGColor;
    UIImageView *ic = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:icon size:14 color:[MiOSTheme secondaryText]]];
    ic.translatesAutoresizingMaskIntoConstraints = NO; [p addSubview:ic];
    UILabel *l = [UILabel new];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = value; l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; l.textColor = [MiOSTheme primaryText];
    l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.6; l.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [p addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [ic.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:12],
        [ic.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
        [l.leadingAnchor constraintEqualToAnchor:ic.trailingAnchor constant:10],
        [l.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
    ]];
    if (tap) {
        UIImageView *chev = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"chevron.up.chevron.down" size:11 color:[MiOSTheme tertiaryText]]];
        chev.translatesAutoresizingMaskIntoConstraints = NO; [p addSubview:chev];
        [NSLayoutConstraint activateConstraints:@[
            [chev.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-12],
            [chev.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
            [l.trailingAnchor constraintLessThanOrEqualToAnchor:chev.leadingAnchor constant:-6],
        ]];
    } else {
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:p.trailingAnchor constant:-12].active = YES;
    }
    return p;
}

- (UIView *)rowWithPill:(UIView *)pill shuffle:(void(^)(void))shuffle {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:pill];
    NSMutableArray *cs = [@[
        [row.heightAnchor constraintEqualToConstant:54],
        [pill.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [pill.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [pill.heightAnchor constraintEqualToConstant:42],
    ] mutableCopy];
    if (shuffle) {
        UIView *sb = [self shuffleButton:shuffle];
        [row addSubview:sb];
        [cs addObjectsFromArray:@[
            [sb.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
            [sb.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [pill.trailingAnchor constraintEqualToAnchor:sb.leadingAnchor constant:-10],
        ]];
    } else {
        [cs addObject:[pill.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14]];
    }
    [NSLayoutConstraint activateConstraints:cs];
    return row;
}
- (void)_randomizeModuleSheet {
    MiOSContainer *m = self.container; __weak typeof(self) ws = self;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Randomize module" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *mm in @[@"device", @"identifiers", @"carrier", @"wifi", @"cellular", @"locale", @"location", @"kernel", @"battery", @"brightness", @"gyroscope"]) {
        [a addAction:[UIAlertAction actionWithTitle:mm style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [m randomizeModule:mm]; [ws save]; [ws reload]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = ws.view;
    a.popoverPresentationController.sourceRect = CGRectMake(ws.view.bounds.size.width / 2, ws.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:a animated:YES completion:nil];
}
- (void)_pickModel {
    MiOSContainer *m = self.container; __weak typeof(self) ws = self;
    NSMutableArray *names = [NSMutableArray array];
    for (MiOSDeviceModel *d in [MiOSDeviceDatabase allDevices]) [names addObject:d.displayName];
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Choose an iPhone"; p.options = names; p.selected = m.deviceDisplayName;
    p.onPick = ^(NSString *v) {
        for (MiOSDeviceModel *d in [MiOSDeviceDatabase allDevices])
            if ([d.displayName isEqualToString:v]) { [ws.container applyDeviceModelIdentifier:d.identifier iosVersion:nil]; ws.container.enableSpoofDeviceModel = YES; break; }
        [ws save]; [ws reload];
    };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickIOS {
    MiOSContainer *m = self.container; __weak typeof(self) ws = self;
    MiOSDeviceModel *d = [MiOSDeviceDatabase deviceForIdentifier:m.deviceIdentifier];
    NSArray *vers = d ? [MiOSDeviceDatabase supportedIOSVersionsForDevice:d] : [MiOSDeviceDatabase allIOSVersions];
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Choose iOS version"; p.options = vers; p.selected = m.iosVersion;
    p.onPick = ^(NSString *v) { ws.container.iosVersion = v; ws.container.enableSpoofSoftwareVersion = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickCountry {
    __weak typeof(self) ws = self;
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray<NSString *> *c in MiOSCountries()) [opts addObject:[NSString stringWithFormat:@"%@  %@", c[2], c[0]]];
    NSArray<NSString *> *cur = self.container.carrierCountryCode.length ? MiOSCountryByISO(self.container.carrierCountryCode) : nil;
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Preferred country"; p.options = opts;
    p.selected = cur ? [NSString stringWithFormat:@"%@  %@", cur[2], cur[0]] : nil;
    p.onPick = ^(NSString *v) {
        for (NSArray<NSString *> *c in MiOSCountries()) {
            if ([[NSString stringWithFormat:@"%@  %@", c[2], c[0]] isEqualToString:v]) {
                ws.container.carrierCountryCode = c[1];
                ws.container.carrierFlag = c[2];
                NSArray<NSArray<NSString *> *> *carriers = MiOSCarriersForISO(c[1]);
                if (carriers.count) {
                    NSArray<NSString *> *first = carriers.firstObject;
                    ws.container.carrierName = first[0]; ws.container.carrierMCC = first[1]; ws.container.carrierMNC = first[2];
                }
                ws.container.enableSpoofCarrier = YES;
                break;
            }
        }
        [ws save]; [ws reload];
    };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickCarrier {
    __weak typeof(self) ws = self;
    NSString *iso = self.container.carrierCountryCode.length ? self.container.carrierCountryCode : @"us";
    NSArray<NSArray<NSString *> *> *carriers = MiOSCarriersForISO(iso);
    if (!carriers.count) { [self _pickCountry]; return; }
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray<NSString *> *c in carriers) [opts addObject:c[0]];
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Choose carrier"; p.options = opts; p.selected = self.container.carrierName;
    p.onPick = ^(NSString *v) {
        for (NSArray<NSString *> *c in carriers) {
            if ([c[0] isEqualToString:v]) {
                ws.container.carrierName = c[0]; ws.container.carrierMCC = c[1]; ws.container.carrierMNC = c[2];
                NSArray<NSString *> *ct = MiOSCountryByISO(iso);
                if (ct) ws.container.carrierFlag = ct[2];
                ws.container.carrierCountryCode = iso;
                ws.container.enableSpoofCarrier = YES;
                break;
            }
        }
        [ws save]; [ws reload];
    };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickCellularType {
    __weak typeof(self) ws = self;
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Cellular type"; p.options = MiOSCellularTypes(); p.selected = self.container.cellularType;
    p.onPick = ^(NSString *v) { ws.container.cellularType = v; ws.container.enableSpoofCellularType = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickLocale {
    __weak typeof(self) ws = self;
    NSMutableArray *opts = [NSMutableArray array];
    for (NSArray<NSString *> *l in MiOSLocales()) [opts addObject:l[2]];
    NSString *sel = nil;
    for (NSArray<NSString *> *l in MiOSLocales()) if ([l[0] isEqualToString:self.container.localeID]) { sel = l[2]; break; }
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Locale"; p.options = opts; p.selected = sel;
    p.onPick = ^(NSString *v) {
        for (NSArray<NSString *> *l in MiOSLocales())
            if ([l[2] isEqualToString:v]) {
                ws.container.localeID = l[0]; ws.container.timeZoneID = l[1];
                ws.container.enableSpoofLocale = YES; ws.container.enableSpoofTimeZone = YES; break;
            }
        [ws save]; [ws reload];
    };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickTimeZone {
    __weak typeof(self) ws = self;
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (NSArray<NSString *> *l in MiOSLocales()) [set addObject:l[1]];
    for (NSString *z in @[@"America/Chicago", @"America/Denver", @"Asia/Dubai", @"Asia/Shanghai",
                          @"Asia/Kolkata", @"Australia/Sydney", @"Europe/Istanbul", @"Pacific/Auckland"]) [set addObject:z];
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Time zone"; p.options = set.array; p.selected = self.container.timeZoneID;
    p.onPick = ^(NSString *v) { ws.container.timeZoneID = v; ws.container.enableSpoofTimeZone = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickStorage {
    MiOSContainer *m = self.container; __weak typeof(self) ws = self;
    MiOSDeviceModel *d = [MiOSDeviceDatabase deviceForIdentifier:m.deviceIdentifier];
    NSMutableArray *opts = [NSMutableArray array];
    if (d.storageOptions.count) for (NSNumber *gb in d.storageOptions) [opts addObject:[NSString stringWithFormat:@"%@ GB", gb]];
    else for (NSNumber *gb in @[@64, @128, @256, @512, @1024]) [opts addObject:[NSString stringWithFormat:@"%@ GB", gb]];
    MiOSPickerVC *p = [MiOSPickerVC new];
    p.title = @"Choose storage"; p.options = opts;
    p.selected = m.deviceStorageGB > 0 ? [NSString stringWithFormat:@"%ld GB", (long)m.deviceStorageGB] : nil;
    p.onPick = ^(NSString *v) { ws.container.deviceStorageGB = v.integerValue; [ws save]; [ws reload]; };
    [self.host pushViewController:p animated:YES];
}
- (void)_pickBatteryLevel {
    __weak typeof(self) ws = self;
    NSMutableArray *opts = [NSMutableArray array];
    for (NSInteger p = 0; p <= 100; p += 5) [opts addObject:[NSString stringWithFormat:@"%ld%%", (long)p]];
    MiOSPickerVC *pk = [MiOSPickerVC new];
    pk.title = @"Choose battery level"; pk.options = opts; pk.selected = [NSString stringWithFormat:@"%ld%%", (long)self.container.batteryLevel];
    pk.onPick = ^(NSString *v) { ws.container.batteryLevel = v.integerValue; ws.container.enableSpoofBatteryLevel = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:pk animated:YES];
}
- (void)_pickBatteryState {
    __weak typeof(self) ws = self;
    NSArray *names = @[@"Unknown", @"Unplugged", @"Charging", @"Full"];
    MiOSPickerVC *pk = [MiOSPickerVC new];
    pk.title = @"Battery state"; pk.options = names;
    pk.selected = (self.container.batteryState >= 0 && self.container.batteryState < 4) ? names[self.container.batteryState] : nil;
    pk.onPick = ^(NSString *v) { ws.container.batteryState = [names indexOfObject:v]; ws.container.enableSpoofBatteryState = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:pk animated:YES];
}
- (void)_pickBrightness {
    __weak typeof(self) ws = self;
    NSMutableArray *opts = [NSMutableArray array];
    for (NSInteger p = 0; p <= 100; p += 5) [opts addObject:[NSString stringWithFormat:@"%ld%%", (long)p]];
    MiOSPickerVC *pk = [MiOSPickerVC new];
    pk.title = @"Choose brightness"; pk.options = opts; pk.selected = [NSString stringWithFormat:@"%ld%%", (long)lround(self.container.brightnessLevel * 100)];
    pk.onPick = ^(NSString *v) { ws.container.brightnessLevel = v.integerValue / 100.0; ws.container.enableSpoofBrightness = YES; [ws save]; [ws reload]; };
    [self.host pushViewController:pk animated:YES];
}

- (UIView *)pillRow:(NSString *)icon value:(NSString *)value mono:(BOOL)mono tap:(void(^)(void))tap {
    MiOSTapView *p = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    p.onTap = tap;
    p.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    p.layer.cornerRadius = 10; p.layer.cornerCurve = kCACornerCurveContinuous;
    p.layer.borderWidth = 1.0; p.layer.borderColor = [MiOSTheme hairline].CGColor;
    UIImageView *ic = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:icon size:12 color:[MiOSTheme secondaryText]]];
    ic.translatesAutoresizingMaskIntoConstraints = NO; [p addSubview:ic];
    UILabel *lbl = [UILabel new];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = value; lbl.textColor = [MiOSTheme primaryText];
    lbl.font = mono ? [MiOSTheme monoFont] : [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    lbl.adjustsFontSizeToFitWidth = YES; lbl.minimumScaleFactor = 0.7;
    [p addSubview:lbl];
    [NSLayoutConstraint activateConstraints:@[
        [ic.leadingAnchor constraintEqualToAnchor:p.leadingAnchor constant:10],
        [ic.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
        [lbl.leadingAnchor constraintEqualToAnchor:ic.trailingAnchor constant:8],
        [lbl.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
    ]];
    if (tap) {
        UIImageView *chev = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"chevron.up.chevron.down" size:10 color:[MiOSTheme tertiaryText]]];
        chev.translatesAutoresizingMaskIntoConstraints = NO; [p addSubview:chev];
        [NSLayoutConstraint activateConstraints:@[
            [chev.trailingAnchor constraintEqualToAnchor:p.trailingAnchor constant:-10],
            [chev.centerYAnchor constraintEqualToAnchor:p.centerYAnchor],
            [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:chev.leadingAnchor constant:-6],
        ]];
    } else {
        [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:p.trailingAnchor constant:-10].active = YES;
    }
    return p;
}

- (UIView *)bottomPick:(NSString *)top sub:(NSString *)sub badge:(UIView *)badge tap:(void(^)(void))tap {
    MiOSTapView *b = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    b.onTap = tap;
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    b.layer.cornerRadius = 12; b.layer.cornerCurve = kCACornerCurveContinuous;
    b.layer.borderWidth = 1.0; b.layer.borderColor = [MiOSTheme hairline].CGColor;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [b addSubview:badge];
    UILabel *t = [UILabel new]; t.translatesAutoresizingMaskIntoConstraints = NO;
    t.text = top; t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold]; t.textColor = [MiOSTheme primaryText];
    [b addSubview:t];
    UILabel *s = [UILabel new]; s.translatesAutoresizingMaskIntoConstraints = NO;
    s.text = sub; s.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium]; s.textColor = [MiOSTheme secondaryText];
    [b addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [b.heightAnchor constraintEqualToConstant:58],
        [badge.leadingAnchor constraintEqualToAnchor:b.leadingAnchor constant:10],
        [badge.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [t.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:10],
        [t.topAnchor constraintEqualToAnchor:b.topAnchor constant:13],
        [t.trailingAnchor constraintLessThanOrEqualToAnchor:b.trailingAnchor constant:-8],
        [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
        [s.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:2],
        [s.trailingAnchor constraintLessThanOrEqualToAnchor:b.trailingAnchor constant:-8],
    ]];
    return b;
}

- (UIView *)deviceCard:(MiOSContainer *)m {
    __weak typeof(self) ws = self;
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [MiOSTheme accentTintedCardBackground];
    card.layer.cornerRadius = 20; card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 1.0; card.layer.borderColor = [MiOSTheme accentBorderColor].CGColor;

    UIImageView *device = [[UIImageView alloc] initWithImage:MiOSDeviceThumb(m, [MiOSTheme accentColor], CGSizeMake(96, 120))];
    device.translatesAutoresizingMaskIntoConstraints = NO;
    device.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:device];

    UIStackView *pills = [[UIStackView alloc] init];
    pills.translatesAutoresizingMaskIntoConstraints = NO;
    pills.axis = UILayoutConstraintAxisVertical; pills.spacing = 8; pills.distribution = UIStackViewDistributionFillEqually;
    [pills addArrangedSubview:[self pillRow:@"iphone" value:(m.deviceDisplayName.length ? m.deviceDisplayName : @"Choose model") mono:NO tap:^{ [ws _pickModel]; }]];
    [pills addArrangedSubview:[self pillRow:@"number" value:(m.deviceIdentifier.length ? m.deviceIdentifier : @"—") mono:YES tap:nil]];
    [pills addArrangedSubview:[self pillRow:@"cpu" value:(m.chipName.length ? m.chipName : @"—") mono:NO tap:nil]];
    [pills addArrangedSubview:[self pillRow:@"memorychip" value:(m.ramGB > 0 ? [NSString stringWithFormat:@"%ld GB RAM · %ld cores", (long)m.ramGB, (long)m.cpuCores] : @"—") mono:NO tap:nil]];
    [card addSubview:pills];

    UIView *iosBtn = [self bottomPick:(m.iosVersion.length ? [NSString stringWithFormat:@"iOS %@", m.iosVersion] : @"iOS")
                                  sub:@"Choose Version"
                                badge:MiOSIOSBadge(m.iosVersion, 34, [MiOSTheme accentColor])
                                  tap:^{ [ws _pickIOS]; }];
    UIImageView *stoBadge = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"internaldrive" size:22 color:[MiOSTheme accentColor]]];
    UIView *stoBtn = [self bottomPick:(m.deviceStorageGB > 0 ? [NSString stringWithFormat:@"%ld GB", (long)m.deviceStorageGB] : @"Storage")
                                  sub:@"Choose Storage" badge:stoBadge tap:^{ [ws _pickStorage]; }];
    iosBtn.translatesAutoresizingMaskIntoConstraints = NO;
    stoBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:iosBtn]; [card addSubview:stoBtn];

    [NSLayoutConstraint activateConstraints:@[
        [device.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [device.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [device.widthAnchor constraintEqualToConstant:96],
        [device.heightAnchor constraintEqualToConstant:120],
        [pills.topAnchor constraintEqualToAnchor:device.topAnchor],
        [pills.bottomAnchor constraintEqualToAnchor:device.bottomAnchor],
        [pills.leadingAnchor constraintEqualToAnchor:device.trailingAnchor constant:12],
        [pills.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [iosBtn.topAnchor constraintEqualToAnchor:device.bottomAnchor constant:12],
        [iosBtn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iosBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [stoBtn.topAnchor constraintEqualToAnchor:iosBtn.topAnchor],
        [stoBtn.leadingAnchor constraintEqualToAnchor:iosBtn.trailingAnchor constant:12],
        [stoBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [stoBtn.widthAnchor constraintEqualToAnchor:iosBtn.widthAnchor],
    ]];
    return card;
}
@end

// Open the Configure (Spoof) editor on a draft — nothing persists until Save Container.
static void MiOSOpenSpoof(MiOSPage *host, MiOSContainer *c, BOOL isNew, void(^onDone)(void)) {
    MiOSSpoofPage *p = [MiOSSpoofPage new];
    p.container = isNew ? c : [[MiOSContainer alloc] initWithDictionary:[c toDictionary]];
    p.isNew = isNew;
    p.onDone = onDone;
    [host miosPresentEditor:p title:(isNew ? @"New Container" : @"Configure")];
}

#pragma mark - Location editor (MKMapView picker + snapshots)

@interface MiOSLocationPage : MiOSPage <MKMapViewDelegate>
@property (nonatomic, strong) MiOSContainer *container;
@property (nonatomic, strong) MKMapView *mapView;
@property (nonatomic, strong) MKPointAnnotation *pin;
@property (nonatomic, strong) UISegmentedControl *mapStyleSeg;
@property (nonatomic, strong) MiOSToggleCell *enableCell;
@property (nonatomic, strong) MiOSFieldCell *latCell;
@property (nonatomic, strong) MiOSFieldCell *lonCell;
@property (nonatomic, strong) MiOSNavigationCell *placeCell;
- (void)_loadFromContainer;
- (void)_fieldChanged;
- (void)_styleChanged;
- (void)_longPressed:(UILongPressGestureRecognizer *)g;
- (void)_setPinAt:(CLLocationCoordinate2D)c save:(BOOL)save;
- (void)_reverseGeocode:(CLLocationCoordinate2D)c;
- (void)_writeSnapshotAt:(CLLocationCoordinate2D)c;
@end
@implementation MiOSLocationPage
- (void)reload {
    [self clearStack];
    MiOSContainer *m = self.container; if (!m) return;
    __weak typeof(self) ws = self;

    UIView *mapCard = [[UIView alloc] init];
    mapCard.translatesAutoresizingMaskIntoConstraints = NO;
    mapCard.backgroundColor = [MiOSTheme tileBackground];
    mapCard.layer.cornerRadius = 20; mapCard.layer.cornerCurve = kCACornerCurveContinuous;
    mapCard.layer.borderWidth = 1.0; mapCard.layer.borderColor = [MiOSTheme hairline].CGColor;
    mapCard.clipsToBounds = YES;

    _mapView = [MKMapView new];
    _mapView.delegate = self;
    _mapView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mapView addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_longPressed:)]];
    [mapCard addSubview:_mapView];

    _mapStyleSeg = [[UISegmentedControl alloc] initWithItems:@[@"Standard", @"Satellite", @"Hybrid"]];
    _mapStyleSeg.selectedSegmentIndex = 0;
    _mapStyleSeg.selectedSegmentTintColor = [MiOSTheme accentColor];
    _mapStyleSeg.translatesAutoresizingMaskIntoConstraints = NO;
    [_mapStyleSeg addTarget:self action:@selector(_styleChanged) forControlEvents:UIControlEventValueChanged];
    [mapCard addSubview:_mapStyleSeg];

    [NSLayoutConstraint activateConstraints:@[
        [mapCard.heightAnchor constraintEqualToConstant:360],
        [_mapView.topAnchor constraintEqualToAnchor:mapCard.topAnchor],
        [_mapView.leadingAnchor constraintEqualToAnchor:mapCard.leadingAnchor],
        [_mapView.trailingAnchor constraintEqualToAnchor:mapCard.trailingAnchor],
        [_mapView.heightAnchor constraintEqualToConstant:300],
        [_mapStyleSeg.topAnchor constraintEqualToAnchor:_mapView.bottomAnchor constant:10],
        [_mapStyleSeg.leadingAnchor constraintEqualToAnchor:mapCard.leadingAnchor constant:12],
        [_mapStyleSeg.trailingAnchor constraintEqualToAnchor:mapCard.trailingAnchor constant:-12],
    ]];
    [self.stack addArrangedSubview:mapCard];

    MiOSSectionCardView *card = [[MiOSSectionCardView alloc] initWithTitle:@"Spoof location"];
    _enableCell = [[MiOSToggleCell alloc] initWithTitle:@"Spoof location" subtitle:@"Long-press the map to drop a pin" icon:@"location.fill" color:[MiOSTheme accentColor] key:@"loc"];
    _enableCell.isOn = m.spoofLocation;
    _enableCell.onChange = ^(BOOL on){ ws.container.spoofLocation = on; [ws.container save]; };
    [card addCellView:_enableCell];
    [card addSeparator];
    _latCell = [[MiOSFieldCell alloc] initWithTitle:@"Latitude" icon:@"arrow.up.and.down" value:(m.coordinate.latitude ? [NSString stringWithFormat:@"%.6f", m.coordinate.latitude] : @"") placeholder:@"0.000000"];
    _latCell.textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _latCell.onChange = ^(NSString *v){ [ws _fieldChanged]; };
    [card addCellView:_latCell];
    [card addSeparator];
    _lonCell = [[MiOSFieldCell alloc] initWithTitle:@"Longitude" icon:@"arrow.left.and.right" value:(m.coordinate.longitude ? [NSString stringWithFormat:@"%.6f", m.coordinate.longitude] : @"") placeholder:@"0.000000"];
    _lonCell.textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    _lonCell.onChange = ^(NSString *v){ [ws _fieldChanged]; };
    [card addCellView:_lonCell];
    [card addSeparator];
    _placeCell = [[MiOSNavigationCell alloc] initWithTitle:@"Place" subtitle:(m.locationName.length ? m.locationName : @"—") icon:@"mappin.and.ellipse" color:[MiOSTheme accentColor]];
    [card addCellView:_placeCell];
    [self.stack addArrangedSubview:card];

    [self _loadFromContainer];
}
- (void)_loadFromContainer {
    CLLocationCoordinate2D c = self.container.coordinate;
    if (c.latitude || c.longitude) {
        [self _setPinAt:c save:NO];
        [self.mapView setRegion:MKCoordinateRegionMakeWithDistance(c, 1500, 1500) animated:NO];
    }
}
- (void)_fieldChanged {
    double lat = self.latCell.textField.text.doubleValue, lon = self.lonCell.textField.text.doubleValue;
    [self _setPinAt:CLLocationCoordinate2DMake(lat, lon) save:YES];
}
- (void)_styleChanged {
    switch (self.mapStyleSeg.selectedSegmentIndex) {
        case 0: self.mapView.mapType = MKMapTypeStandard; break;
        case 1: self.mapView.mapType = MKMapTypeSatellite; break;
        default: self.mapView.mapType = MKMapTypeHybrid; break;
    }
}
- (void)_longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:self.mapView];
    CLLocationCoordinate2D c = [self.mapView convertPoint:p toCoordinateFromView:self.mapView];
    [self _setPinAt:c save:YES];
    self.latCell.textField.text = [NSString stringWithFormat:@"%.6f", c.latitude];
    self.lonCell.textField.text = [NSString stringWithFormat:@"%.6f", c.longitude];
    [MiOSHaptic() impactOccurred];
}
- (void)_setPinAt:(CLLocationCoordinate2D)c save:(BOOL)save {
    if (!self.pin) { self.pin = [MKPointAnnotation new]; [self.mapView addAnnotation:self.pin]; }
    self.pin.coordinate = c;
    if (save) {
        self.container.coordinate = c;
        self.container.spoofLocation = YES;
        self.enableCell.isOn = YES;
        [self.container save];
        [self _reverseGeocode:c];
        [self _writeSnapshotAt:c];
    }
}
- (void)_reverseGeocode:(CLLocationCoordinate2D)c {
    CLGeocoder *g = [CLGeocoder new];
    [g reverseGeocodeLocation:[[CLLocation alloc] initWithLatitude:c.latitude longitude:c.longitude]
            completionHandler:^(NSArray<CLPlacemark *> *marks, NSError *err){
        CLPlacemark *m = marks.firstObject;
        NSString *name = m.name ? [NSString stringWithFormat:@"%@, %@", m.name, m.country ?: @""] : @"";
        self.container.locationName = name;
        self.container.locationCountryCode = m.ISOcountryCode ?: @"";
        [self.placeCell setSubtitle:name.length ? name : @"—"];
        [self.container save];
    }];
}
- (void)_writeSnapshotAt:(CLLocationCoordinate2D)c {
    NSString *root = [self.container containerRootEnsureCreated:YES];
    if (!root.length) return;
    for (NSNumber *style in @[@(MKMapTypeStandard), @(MKMapTypeSatellite), @(MKMapTypeHybrid)]) {
        MKMapSnapshotOptions *opts = [MKMapSnapshotOptions new];
        opts.region = MKCoordinateRegionMakeWithDistance(c, 1500, 1500);
        opts.size = CGSizeMake(600, 400);
        opts.mapType = (MKMapType)style.integerValue;
        MKMapSnapshotter *snap = [[MKMapSnapshotter alloc] initWithOptions:opts];
        [snap startWithCompletionHandler:^(MKMapSnapshot *s, NSError *e){
            if (!s) return;
            NSString *name = @"";
            switch (style.integerValue) {
                case MKMapTypeStandard: name = @"standard-snapshot.png"; break;
                case MKMapTypeSatellite: name = @"satellite-snapshot.png"; break;
                default: name = @"hybrid-snapshot.png"; break;
            }
            [UIImagePNGRepresentation(s.image) writeToFile:[root stringByAppendingPathComponent:name] atomically:YES];
            if (style.integerValue == MKMapTypeStandard)
                [UIImagePNGRepresentation(s.image) writeToFile:[root stringByAppendingPathComponent:@"location-snapshot.png"] atomically:YES];
        }];
    }
}
@end

#pragma mark - Proxies tab

@interface MiOSProxyPage : MiOSPage
@property (nonatomic, strong) MiOSContainer *container;
@end
@implementation MiOSProxyPage
- (void)reload {
    [self clearStack];
    MiOSContainer *m = self.container; if (!m) return;
    __weak typeof(self) ws = self;

    MiOSSectionCardView *mode = [[MiOSSectionCardView alloc] initWithTitle:@"Proxy mode (BETA)"];
    MiOSToggleCell *route = [[MiOSToggleCell alloc] initWithTitle:@"Route Instagram through proxy"
        subtitle:@"NSURLSessionConfiguration gets HTTPS/HTTP proxy" icon:@"shippingbox.and.arrow.backward"
           color:[MiOSTheme accentGradientEnd] key:@"proxy"];
    route.isOn = m.enableProxy;
    route.onChange = ^(BOOL on){ ws.container.enableProxy = on; [ws.container save]; };
    [mode addCellView:route];
    [self.stack addArrangedSubview:mode];

    MiOSSectionCardView *conn = [[MiOSSectionCardView alloc] initWithTitle:@"Connection"];
    MiOSFieldCell *host = [[MiOSFieldCell alloc] initWithTitle:@"Host" icon:@"server.rack" value:m.proxyHost placeholder:@"proxy.example.com"];
    host.onChange = ^(NSString *v){ ws.container.proxyHost = v; [ws.container save]; };
    [conn addCellView:host]; [conn addSeparator];
    MiOSFieldCell *port = [[MiOSFieldCell alloc] initWithTitle:@"Port" icon:@"number" value:(m.proxyPort > 0 ? [NSString stringWithFormat:@"%ld", (long)m.proxyPort] : @"") placeholder:@"8080"];
    port.textField.keyboardType = UIKeyboardTypeNumberPad;
    port.onChange = ^(NSString *v){ ws.container.proxyPort = v.integerValue; [ws.container save]; };
    [conn addCellView:port]; [conn addSeparator];
    MiOSFieldCell *user = [[MiOSFieldCell alloc] initWithTitle:@"Username" icon:@"person" value:m.proxyUsername placeholder:@"optional"];
    user.onChange = ^(NSString *v){ ws.container.proxyUsername = v; [ws.container save]; };
    [conn addCellView:user]; [conn addSeparator];
    MiOSFieldCell *pass = [[MiOSFieldCell alloc] initWithTitle:@"Password" icon:@"key" value:m.proxyPassword placeholder:@"optional"];
    pass.textField.secureTextEntry = YES;
    pass.onChange = ^(NSString *v){ ws.container.proxyPassword = v; [ws.container save]; };
    [conn addCellView:pass];
    [self.stack addArrangedSubview:conn];
}
@end

#pragma mark - Settings tab

@interface MiOSSettingsPage : MiOSPage
@end
@implementation MiOSSettingsPage
- (void)reload {
    [self clearStack];
    __weak typeof(self) ws = self;
    MiOSSectionCardView *about = [[MiOSSectionCardView alloc] initWithTitle:@"About"];
    MiOSNavigationCell *ver = [[MiOSNavigationCell alloc] initWithTitle:@"miOS version" subtitle:nil icon:@"info.circle" color:[MiOSTheme accentColor]];
    ver.valueText = @"2.0.0"; [about addCellView:ver]; [about addSeparator];
    MiOSNavigationCell *app = [[MiOSNavigationCell alloc] initWithTitle:@"Target app" subtitle:nil icon:@"camera.circle" color:[MiOSTheme accentColor]];
    app.valueText = kMiOSAppName; [about addCellView:app];
    [self.stack addArrangedSubview:about];

    MiOSButtonCell *reset = [[MiOSButtonCell alloc] initWithTitle:@"Reset miOS" color:[MiOSTheme destructive]];
    reset.tapAction = ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Reset miOS?"
            message:@"This erases every container, every spoof setting, and every snapshot. This action cannot be undone."
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Erase everything" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *x){ [MiOSContainer resetAll]; MiOSRelaunch(@"miOS has been reset. Restart Instagram to continue."); }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ws presentViewController:a animated:YES completion:nil];
    };
    [self.stack addArrangedSubview:reset];
}
@end

#pragma mark - Cloud tab (backup / restore)

static NSString *MiOSBackupPath(void) {
    return [MiOSBaseDir() stringByAppendingPathComponent:@"cloud-backup.plist"];
}
@interface MiOSCloudPage : MiOSPage
@end
@implementation MiOSCloudPage
- (void)reload {
    [self clearStack];
    __weak typeof(self) ws = self;
    NSArray<MiOSContainer *> *all = MiOSSortedContainers();
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:MiOSBackupPath() error:nil];
    NSDate *when = attrs.fileModificationDate;

    MiOSSectionCardView *status = [[MiOSSectionCardView alloc] initWithTitle:@"Cloud backup"];
    MiOSNavigationCell *count = [[MiOSNavigationCell alloc] initWithTitle:@"Containers" subtitle:@"Stored on this device" icon:@"square.stack.3d.up.fill" color:[MiOSTheme accentColor]];
    count.valueText = [NSString stringWithFormat:@"%lu", (unsigned long)all.count];
    [status addCellView:count]; [status addSeparator];
    MiOSNavigationCell *last = [[MiOSNavigationCell alloc] initWithTitle:@"Last backup" subtitle:nil icon:@"clock.arrow.circlepath" color:[MiOSTheme accentColor]];
    if (when) {
        NSDateFormatter *df = [NSDateFormatter new]; df.dateStyle = NSDateFormatterMediumStyle; df.timeStyle = NSDateFormatterShortStyle;
        last.valueText = [df stringFromDate:when];
    } else last.valueText = @"Never";
    [status addCellView:last];
    [self.stack addArrangedSubview:status];

    MiOSButtonCell *backup = [[MiOSButtonCell alloc] initWithTitle:@"Create backup" color:[MiOSTheme accentColor]];
    backup.tapAction = ^{
        NSMutableArray *dicts = [NSMutableArray array];
        for (MiOSContainer *c in [MiOSContainer loadAll]) [dicts addObject:[c toDictionary]];
        [dicts writeToFile:MiOSBackupPath() atomically:YES];
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
        [ws reload];
    };
    [self.stack addArrangedSubview:backup];

    MiOSButtonCell *restore = [[MiOSButtonCell alloc] initWithTitle:@"Restore latest backup" color:[MiOSTheme accentGradientEnd]];
    restore.tapAction = ^{
        NSArray *dicts = [NSArray arrayWithContentsOfFile:MiOSBackupPath()];
        if (!dicts.count) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"No backup found" message:@"Create a backup first." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [ws presentViewController:a animated:YES completion:nil];
            return;
        }
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restore backup?"
            message:@"This replaces your current containers with the ones in the latest backup." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            NSMutableArray<MiOSContainer *> *restored = [NSMutableArray array];
            for (NSDictionary *d in dicts) [restored addObject:[[MiOSContainer alloc] initWithDictionary:d]];
            [MiOSContainer saveAll:restored];
            MiOSRelaunch(@"Containers restored. Restart Instagram to apply.");
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ws presentViewController:a animated:YES completion:nil];
    };
    [self.stack addArrangedSubview:restore];

    UILabel *note = [UILabel new];
    note.text = @"Backups are stored inside Instagram's own sandbox. Copy them out with Filza / an IPA tool to move them between devices.";
    note.font = [MiOSTheme captionFont];
    note.textColor = [MiOSTheme tertiaryText];
    note.numberOfLines = 0;
    [self.stack addArrangedSubview:note];
}
@end

#pragma mark - Percent ring

@interface MiOSRingView : UIView
- (instancetype)initWithPercent:(NSInteger)pct accent:(UIColor *)accent diameter:(CGFloat)d;
@end
@implementation MiOSRingView {
    CAShapeLayer *_track;
    CAShapeLayer *_progress;
    UILabel *_label;
    NSInteger _pct;
    UIColor *_accent;
}
- (instancetype)initWithPercent:(NSInteger)pct accent:(UIColor *)accent diameter:(CGFloat)d {
    if (self = [super initWithFrame:CGRectMake(0, 0, d, d)]) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _pct = MAX(0, MIN(100, pct));
        _accent = accent;
        _track = [CAShapeLayer layer];
        _track.fillColor = [UIColor clearColor].CGColor;
        _track.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
        _track.lineWidth = 3.5; _track.lineCap = kCALineCapRound;
        [self.layer addSublayer:_track];
        _progress = [CAShapeLayer layer];
        _progress.fillColor = [UIColor clearColor].CGColor;
        _progress.strokeColor = accent.CGColor;
        _progress.lineWidth = 3.5; _progress.lineCap = kCALineCapRound;
        _progress.strokeEnd = _pct / 100.0;
        [self.layer addSublayer:_progress];
        _label = [[UILabel alloc] init];
        _label.font = [UIFont systemFontOfSize:d > 60 ? 18 : 12 weight:UIFontWeightBold];
        _label.textColor = [MiOSTheme primaryText];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.text = [NSString stringWithFormat:@"%ld%%", (long)_pct];
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [self.widthAnchor constraintEqualToConstant:d],
            [self.heightAnchor constraintEqualToConstant:d],
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _label.frame = self.bounds;
    CGFloat inset = _track.lineWidth / 2 + 1;
    UIBezierPath *p = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds))
                                                     radius:(self.bounds.size.width / 2 - inset)
                                                 startAngle:-M_PI_2 endAngle:(-M_PI_2 + 2 * M_PI) clockwise:YES];
    _track.frame = self.bounds; _track.path = p.CGPath;
    _progress.frame = self.bounds; _progress.path = p.CGPath;
}
@end

#pragma mark - Device / iOS thumbnails

static UIImage *MiOSDeviceThumb(MiOSContainer *m, UIColor *accent, CGSize size) {
    NSString *name = (m.enableSpoofDeviceModel && m.deviceDisplayName.length) ? m.deviceDisplayName : @"iPhone 15 Pro";
    return [MiOSDeviceImageRenderer renderDeviceForName:name size:size accentColor:accent];
}
static UIView *MiOSIOSBadge(NSString *iosVersion, CGFloat side, UIColor *accent) {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.14 alpha:1.0];
    v.layer.cornerRadius = side * 0.26; v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.borderWidth = 1.0; v.layer.borderColor = [accent colorWithAlphaComponent:0.35].CGColor;
    UILabel *top = [UILabel new];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    top.text = @"iOS"; top.font = [UIFont systemFontOfSize:side * 0.2 weight:UIFontWeightSemibold];
    top.textColor = [MiOSTheme secondaryText]; top.textAlignment = NSTextAlignmentCenter;
    [v addSubview:top];
    UILabel *num = [UILabel new];
    num.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *major = iosVersion.length ? [iosVersion componentsSeparatedByString:@"."].firstObject : @"—";
    num.text = major; num.font = [UIFont systemFontOfSize:side * 0.42 weight:UIFontWeightBold];
    num.textColor = [MiOSTheme primaryText]; num.textAlignment = NSTextAlignmentCenter;
    [v addSubview:num];
    [NSLayoutConstraint activateConstraints:@[
        [v.widthAnchor constraintEqualToConstant:side],
        [v.heightAnchor constraintEqualToConstant:side],
        [top.topAnchor constraintEqualToAnchor:v.topAnchor constant:side * 0.14],
        [top.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
        [num.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:-1],
        [num.centerXAnchor constraintEqualToAnchor:v.centerXAnchor],
    ]];
    return v;
}

#pragma mark - Container row + list (device · iOS · protection %)

static UIView *MiOSContainerRow(MiOSContainer *m, BOOL active, void (^onTap)(void)) {
    UIColor *accent = [MiOSTheme accentColor];
    MiOSTapView *row = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    row.onTap = onTap;
    CGFloat r, g, b, a; [accent getRed:&r green:&g blue:&b alpha:&a];
    row.backgroundColor = [UIColor colorWithRed:0.11 + r * 0.05 green:0.11 + g * 0.05 blue:0.15 + b * 0.05 alpha:0.92];
    row.layer.cornerRadius = 18; row.layer.cornerCurve = kCACornerCurveContinuous;
    row.layer.borderWidth = active ? 1.5 : 1.0;
    row.layer.borderColor = active ? [accent colorWithAlphaComponent:0.95].CGColor : [MiOSTheme hairline].CGColor;
    if (active) {
        // Bright accent outline + the same accent glow radiating from the tile.
        row.layer.shadowColor = accent.CGColor;
        row.layer.shadowOffset = CGSizeZero;
        row.layer.shadowRadius = 18;
        row.layer.shadowOpacity = 0.6;
        row.layer.masksToBounds = NO;
    }

    UIImageView *device = [[UIImageView alloc] initWithImage:MiOSDeviceThumb(m, accent, CGSizeMake(52, 48))];
    device.translatesAutoresizingMaskIntoConstraints = NO;
    device.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:device];

    UIView *ios = MiOSIOSBadge(m.iosVersion, 40, accent);
    [row addSubview:ios];

    UILabel *name = [UILabel new];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = m.name.length ? m.name : @"Container";
    name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    name.textColor = [MiOSTheme primaryText];
    [row addSubview:name];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    BOOL hasModel = (m.enableSpoofDeviceModel && m.deviceDisplayName.length);
    sub.text = hasModel ? (m.iosVersion.length ? [NSString stringWithFormat:@"%@ · iOS %@", m.deviceDisplayName, m.iosVersion] : m.deviceDisplayName)
                        : (active ? @"Active · real device" : @"Real device");
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sub.textColor = active ? accent : [MiOSTheme secondaryText];
    sub.numberOfLines = 1;
    [row addSubview:sub];

    MiOSRingView *ring = [[MiOSRingView alloc] initWithPercent:MiOSProtectionPercent(m) accent:accent diameter:46];
    [row addSubview:ring];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:72],
        [device.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [device.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [device.widthAnchor constraintEqualToConstant:52],
        [device.heightAnchor constraintEqualToConstant:48],
        [ios.leadingAnchor constraintEqualToAnchor:device.trailingAnchor constant:4],
        [ios.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [name.leadingAnchor constraintEqualToAnchor:ios.trailingAnchor constant:12],
        [name.topAnchor constraintEqualToAnchor:row.topAnchor constant:16],
        [name.trailingAnchor constraintLessThanOrEqualToAnchor:ring.leadingAnchor constant:-10],
        [sub.leadingAnchor constraintEqualToAnchor:name.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:2],
        [sub.trailingAnchor constraintLessThanOrEqualToAnchor:ring.leadingAnchor constant:-10],
        [ring.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [ring.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

// Vertical list of container rows (kept name MiOSContainerGrid for call sites).
static UIView *MiOSContainerGrid(NSArray<MiOSContainer *> *containers, NSString *activeID, void (^onTap)(MiOSContainer *)) {
    UIStackView *col = [[UIStackView alloc] init];
    col.translatesAutoresizingMaskIntoConstraints = NO;
    col.axis = UILayoutConstraintAxisVertical;
    col.spacing = 10;
    for (MiOSContainer *m in containers) {
        BOOL active = [activeID isEqualToString:m.identifier];
        [col addArrangedSubview:MiOSContainerRow(m, active, ^{ if (onTap) onTap(m); })];
    }
    return col;
}

// Shared container action sheet (activate / edit / rename / clear cache / delete).
static void MiOSPresentContainerActions(UIViewController *host, MiOSContainer *m, void (^openEditor)(MiOSContainer *), void (^changed)(void)) {
    BOOL isDefault = MiOSIsDefault(m);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:(isDefault ? @"Default" : m.name)
        message:(isDefault ? @"The default container is the real device and can't be renamed or deleted."
                           : @"Activate this container? Instagram will restart to apply it.")
        preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Activate & restart" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x){ [m save]; [MiOSContainer setActiveContainerID:m.identifier]; [m containerRootEnsureCreated:YES]; exit(0); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Edit fingerprint" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *x){ if (openEditor) openEditor(m); }]];
    if (!isDefault) {
        [a addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *x){
                UIAlertController *r = [UIAlertController alertControllerWithTitle:@"Rename Container"
                    message:@"Enter the name you want to change your container to." preferredStyle:UIAlertControllerStyleAlert];
                [r addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text = m.name; }];
                [r addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *y){ NSString *n = r.textFields.firstObject.text; if (!n.length) return; m.name = n; [m save]; if (changed) changed(); }]];
                [r addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [host presentViewController:r animated:YES completion:nil];
            }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Clear cache" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *x){
            UIAlertController *c = [UIAlertController alertControllerWithTitle:@"Clear cache?"
                message:@"This erases everything stored inside this container (data, keychain, snapshots). Spoof settings are kept." preferredStyle:UIAlertControllerStyleAlert];
            [c addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *y){
                MiOSClearCache(m);
                BOOL wasActive = [[MiOSContainer activeContainerID] isEqualToString:m.identifier];
                if (changed) changed();
                if (wasActive) MiOSRelaunch(@"Cache cleared. Restart Instagram to start the container fresh.");
            }]];
            [c addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [host presentViewController:c animated:YES completion:nil];
        }]];
    if (!isDefault) {
        [a addAction:[UIAlertAction actionWithTitle:@"Delete Container" style:UIAlertActionStyleDestructive
            handler:^(UIAlertAction *x){
                BOOL wasActive = [[MiOSContainer activeContainerID] isEqualToString:m.identifier];
                [MiOSContainer removeContainerWithID:m.identifier];
                if (changed) changed();
                if (wasActive) MiOSRelaunch(@"The active container was deleted. Restart Instagram to continue without it.");
            }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = host.view;
    a.popoverPresentationController.sourceRect = CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height / 2, 1, 1);
    [host presentViewController:a animated:YES completion:nil];
}

#pragma mark - Containers tab (grid)

@interface MiOSContainersPage : MiOSPage
- (void)_newContainer;
- (void)_editContainer:(MiOSContainer *)c;
@end
@implementation MiOSContainersPage
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }
- (void)reload {
    [self clearStack];
    __weak typeof(self) ws = self;
    NSArray<MiOSContainer *> *all = MiOSSortedContainers();
    NSString *active = [MiOSContainer activeContainerID];

    UILabel *title = [UILabel new];
    title.text = @"Containers";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = [MiOSTheme primaryText];
    [self.stack addArrangedSubview:title];

    MiOSPrimaryButton *add = [[MiOSPrimaryButton alloc] initWithTitle:@"New container" watermark:@"plus"];
    [add addTarget:self action:@selector(_newContainer) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:add];

    if (all.count) {
        [self.stack addArrangedSubview:MiOSContainerGrid(all, active, ^(MiOSContainer *m){
            MiOSPresentContainerActions(ws, m, ^(MiOSContainer *c){ [ws _editContainer:c]; }, ^{ [ws reload]; });
        })];
    } else {
        UILabel *empty = [UILabel new];
        empty.text = @"No containers yet. Create one to start isolating sessions.";
        empty.font = [MiOSTheme bodyFont]; empty.textColor = [MiOSTheme secondaryText];
        empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter;
        [self.stack addArrangedSubview:empty];
    }
}
- (void)_newContainer {
    NSArray *all = MiOSSortedContainers();
    MiOSContainer *c = [MiOSContainer newRandomContainerNamed:[NSString stringWithFormat:@"Container %lu", (unsigned long)all.count]];
    __weak typeof(self) ws = self;
    MiOSOpenSpoof(self, c, YES, ^{ [ws reload]; });   // created only on Save
}
- (void)_editContainer:(MiOSContainer *)c {
    __weak typeof(self) ws = self;
    MiOSOpenSpoof(self, c, NO, ^{ [ws reload]; });
}
@end

#pragma mark - Home tab (dashboard)

@interface MiOSTrackerPage : MiOSPage
@property (nonatomic, strong) MiOSContainer *container;
@end

@interface MiOSHomePage : MiOSPage
- (MiOSContainer *)active;
- (void)openTracker;
- (UIView *)buildHeader:(UIColor *)accent;
- (UIView *)halo:(UIView *)content accent:(UIColor *)accent inHero:(UIView *)hero;
- (UIView *)buildHero:(MiOSContainer *)c accent:(UIColor *)accent;
- (UIView *)statusPill:(MiOSContainer *)c;
- (UIImageView *)watermark:(NSString *)symbol on:(UIView *)tile pointSize:(CGFloat)size color:(UIColor *)color rotation:(CGFloat)rotation;
- (MiOSGradientView *)gradientTile:(NSArray<UIColor *> *)colors radius:(CGFloat)radius;
- (UIView *)buildTiles:(MiOSContainer *)c accent:(UIColor *)accent;
- (UIView *)locationTile:(MiOSContainer *)c accent:(UIColor *)accent;
- (UIView *)privacyTile:(MiOSContainer *)c accent:(UIColor *)accent;
- (UIView *)buildNewContainerCard:(UIColor *)accent;
- (UIView *)buildTrackerCard:(MiOSContainer *)c;
- (void)openSpoof:(MiOSContainer *)c;
- (void)openLocation:(MiOSContainer *)c;
- (void)newContainer;
@end
@implementation MiOSHomePage

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reload]; }

- (MiOSContainer *)active {
    MiOSContainer *a = [MiOSContainer activeContainer];
    return a ?: MiOSEnsureDefault();
}

- (void)reload {
    [self clearStack];
    MiOSContainer *active = [self active];
    UIColor *accent = [MiOSTheme accentColor];

    [self.stack addArrangedSubview:[self buildHeader:accent]];
    if (active) {
        [self.stack addArrangedSubview:[self buildHero:active accent:accent]];
        [self.stack addArrangedSubview:[self buildTiles:active accent:accent]];

        [self.stack addArrangedSubview:[self buildTrackerCard:active]];
    }
    [self.stack addArrangedSubview:[self buildNewContainerCard:accent]];

    NSArray<MiOSContainer *> *all = MiOSSortedContainers();
    if (all.count) {
        UILabel *header = [UILabel new];
        header.text = @"Containers";
        header.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
        header.textColor = [MiOSTheme primaryText];
        [self.stack addArrangedSubview:header];
        [self.stack setCustomSpacing:12 afterView:header];
        __weak typeof(self) ws = self;
        [self.stack addArrangedSubview:MiOSContainerGrid(all, [MiOSContainer activeContainerID], ^(MiOSContainer *m){
            MiOSPresentContainerActions(ws, m, ^(MiOSContainer *c){ [ws openSpoof:c]; }, ^{ [ws reload]; });
        })];
    }
}

#pragma mark Header

- (UIView *)buildHeader:(UIColor *)accent {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *logo = [UILabel new];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.attributedText = [[NSAttributedString alloc] initWithString:@"miOS" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy],
        NSForegroundColorAttributeName: [MiOSTheme primaryText],
        NSKernAttributeName: @1.5 }];
    [row addSubview:logo];

    UILabel *descriptor = [UILabel new];
    descriptor.translatesAutoresizingMaskIntoConstraints = NO;
    descriptor.attributedText = [[NSAttributedString alloc] initWithString:@"CONTAINERS" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [MiOSTheme secondaryText],
        NSKernAttributeName: @5.0 }];
    [row addSubview:descriptor];

    UILabel *tagline = [UILabel new];
    tagline.translatesAutoresizingMaskIntoConstraints = NO;
    tagline.attributedText = [[NSAttributedString alloc] initWithString:@"ONE APP · MANY IDENTITIES" attributes:@{
        NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightBold],
        NSForegroundColorAttributeName: accent,
        NSKernAttributeName: @1.5 }];
    [row addSubview:tagline];

    UIImageView *mascot = [[UIImageView alloc] initWithImage:[MiOSMascotRenderer mascotWithSize:CGSizeMake(72, 72) accent:accent]];
    mascot.translatesAutoresizingMaskIntoConstraints = NO;
    mascot.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:mascot];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:78],
        [logo.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:2],
        [logo.topAnchor constraintEqualToAnchor:row.topAnchor constant:2],
        [descriptor.leadingAnchor constraintEqualToAnchor:logo.leadingAnchor constant:1],
        [descriptor.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:1],
        [tagline.leadingAnchor constraintEqualToAnchor:logo.leadingAnchor constant:1],
        [tagline.topAnchor constraintEqualToAnchor:descriptor.bottomAnchor constant:7],
        [mascot.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:4],
        [mascot.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [mascot.widthAnchor constraintEqualToConstant:72],
        [mascot.heightAnchor constraintEqualToConstant:72],
    ]];
    return row;
}

#pragma mark Hero (device halo)

- (UIView *)halo:(UIView *)content accent:(UIColor *)accent inHero:(UIView *)hero {
    MiOSGradientView *glow = [[MiOSGradientView alloc] init];
    glow.translatesAutoresizingMaskIntoConstraints = NO;
    glow.userInteractionEnabled = NO;
    CAGradientLayer *gl = (CAGradientLayer *)glow.layer;
    gl.type = kCAGradientLayerRadial;
    [glow setColors:@[[accent colorWithAlphaComponent:0.38], [accent colorWithAlphaComponent:0.12], [accent colorWithAlphaComponent:0.0]]
              start:CGPointMake(0.5, 0.5) end:CGPointMake(1.0, 1.0)];
    gl.locations = @[@0.0, @0.45, @1.0];
    [hero addSubview:glow];

    UIView *orbit = [[UIView alloc] init];
    orbit.translatesAutoresizingMaskIntoConstraints = NO;
    orbit.userInteractionEnabled = NO;
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 204, 204)].CGPath;
    ring.fillColor = [UIColor clearColor].CGColor;
    ring.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    ring.lineWidth = 1.0;
    ring.lineDashPattern = @[@2, @6];
    [orbit.layer addSublayer:ring];
    [hero addSubview:orbit];

    MiOSTapView *haloV = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    haloV.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
    haloV.layer.cornerRadius = 82;
    haloV.layer.borderWidth = 1.5;
    haloV.layer.borderColor = [accent colorWithAlphaComponent:0.55].CGColor;
    haloV.layer.shadowColor = accent.CGColor;
    haloV.layer.shadowOffset = CGSizeZero;
    haloV.layer.shadowRadius = 18;
    haloV.layer.shadowOpacity = 0.45;
    __weak typeof(self) ws = self;
    haloV.onTap = ^{ MiOSContainer *a = [ws active]; if (a) [ws openSpoof:a]; };
    [hero addSubview:haloV];

    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.userInteractionEnabled = NO;
    [haloV addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [haloV.topAnchor constraintEqualToAnchor:hero.topAnchor constant:24],
        [haloV.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [haloV.widthAnchor constraintEqualToConstant:164],
        [haloV.heightAnchor constraintEqualToConstant:164],
        [orbit.centerXAnchor constraintEqualToAnchor:haloV.centerXAnchor],
        [orbit.centerYAnchor constraintEqualToAnchor:haloV.centerYAnchor],
        [orbit.widthAnchor constraintEqualToConstant:204],
        [orbit.heightAnchor constraintEqualToConstant:204],
        [glow.centerXAnchor constraintEqualToAnchor:haloV.centerXAnchor],
        [glow.centerYAnchor constraintEqualToAnchor:haloV.centerYAnchor],
        [glow.widthAnchor constraintEqualToConstant:320],
        [glow.heightAnchor constraintEqualToConstant:320],
        [content.centerXAnchor constraintEqualToAnchor:haloV.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:haloV.centerYAnchor],
    ]];
    return haloV;
}

- (UIView *)buildHero:(MiOSContainer *)c accent:(UIColor *)accent {
    UIView *hero = [[UIView alloc] init];
    hero.translatesAutoresizingMaskIntoConstraints = NO;

    BOOL hasModel = (c.enableSpoofDeviceModel && c.deviceDisplayName.length > 0);
    NSString *deviceName = hasModel ? c.deviceDisplayName : @"iPhone 15 Pro";
    UIImageView *device = [[UIImageView alloc] init];
    device.contentMode = UIViewContentModeScaleAspectFit;
    device.image = [MiOSDeviceImageRenderer renderDeviceForName:deviceName size:CGSizeMake(140, 132) accentColor:accent];
    UIView *halo = [self halo:device accent:accent inHero:hero];

    UILabel *name = [UILabel new];
    name.translatesAutoresizingMaskIntoConstraints = NO;
    name.text = c.name.length ? c.name : @"Container";
    name.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    name.textColor = [MiOSTheme primaryText];
    name.textAlignment = NSTextAlignmentCenter;
    name.adjustsFontSizeToFitWidth = YES; name.minimumScaleFactor = 0.6;
    [hero addSubview:name];

    NSString *subtitle;
    if (hasModel) {
        subtitle = c.iosVersion.length ? [NSString stringWithFormat:@"%@  ·  iOS %@", c.deviceDisplayName, c.iosVersion] : c.deviceDisplayName;
    } else subtitle = @"Real device";
    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = subtitle;
    sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    sub.textColor = [MiOSTheme secondaryText];
    sub.textAlignment = NSTextAlignmentCenter;
    [hero addSubview:sub];

    UIView *pill = [self statusPill:c];
    [hero addSubview:pill];

    [NSLayoutConstraint activateConstraints:@[
        [name.topAnchor constraintEqualToAnchor:halo.bottomAnchor constant:26],
        [name.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:16],
        [name.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-16],
        [sub.topAnchor constraintEqualToAnchor:name.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:hero.leadingAnchor constant:16],
        [sub.trailingAnchor constraintEqualToAnchor:hero.trailingAnchor constant:-16],
        [pill.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:14],
        [pill.centerXAnchor constraintEqualToAnchor:hero.centerXAnchor],
        [pill.bottomAnchor constraintEqualToAnchor:hero.bottomAnchor],
    ]];
    return hero;
}

- (UIView *)statusPill:(MiOSContainer *)c {
    BOOL enabled = c.enableSpoof;
    UIColor *stateColor = enabled ? [MiOSTheme success] : [MiOSTheme tertiaryText];
    MiOSTapView *pill = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    pill.layer.cornerRadius = 16;
    pill.layer.borderWidth = 1.0;
    pill.layer.borderColor = [stateColor colorWithAlphaComponent:0.35].CGColor;
    __weak typeof(self) ws = self;
    pill.onTap = ^{ c.enableSpoof = !c.enableSpoof; [c save]; [ws reload]; };

    UIView *dot = [[UIView alloc] init];
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    dot.backgroundColor = stateColor; dot.layer.cornerRadius = 4;
    dot.layer.shadowColor = stateColor.CGColor; dot.layer.shadowOffset = CGSizeZero;
    dot.layer.shadowRadius = 4; dot.layer.shadowOpacity = enabled ? 0.9 : 0.0;
    [pill addSubview:dot];

    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = enabled ? @"Active" : @"Paused";
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textColor = [MiOSTheme primaryText];
    [pill addSubview:label];

    UIImageView *power = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"power" size:11 color:[MiOSTheme secondaryText]]];
    power.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:power];

    [NSLayoutConstraint activateConstraints:@[
        [pill.heightAnchor constraintEqualToConstant:32],
        [dot.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:14],
        [dot.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [dot.widthAnchor constraintEqualToConstant:8],
        [dot.heightAnchor constraintEqualToConstant:8],
        [label.leadingAnchor constraintEqualToAnchor:dot.trailingAnchor constant:8],
        [label.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [power.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
        [power.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [power.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-14],
    ]];
    return pill;
}

#pragma mark Tiles

- (UIImageView *)watermark:(NSString *)symbol on:(UIView *)tile pointSize:(CGFloat)size color:(UIColor *)color rotation:(CGFloat)rotation {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightBold];
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:cfg]];
    mark.translatesAutoresizingMaskIntoConstraints = NO;
    mark.userInteractionEnabled = NO;
    mark.tintColor = color;
    mark.transform = CGAffineTransformMakeRotation(rotation);
    [tile insertSubview:mark atIndex:0];
    return mark;
}

- (MiOSGradientView *)gradientTile:(NSArray<UIColor *> *)colors radius:(CGFloat)radius {
    MiOSGradientView *tile = [[MiOSGradientView alloc] init];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    [tile setColors:colors start:CGPointMake(0, 0) end:CGPointMake(1, 1)];
    tile.layer.cornerRadius = radius; tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.layer.borderWidth = 1.0; tile.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    tile.clipsToBounds = YES;
    return tile;
}

- (UIView *)buildTiles:(MiOSContainer *)c accent:(UIColor *)accent {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *location = [self locationTile:c accent:accent];
    UIView *privacy = [self privacyTile:c accent:accent];
    [row addSubview:location];
    [row addSubview:privacy];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:184],
        [location.topAnchor constraintEqualToAnchor:row.topAnchor],
        [location.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [location.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
        [location.trailingAnchor constraintEqualToAnchor:privacy.leadingAnchor constant:-12],
        [location.widthAnchor constraintEqualToAnchor:privacy.widthAnchor],
        [privacy.topAnchor constraintEqualToAnchor:row.topAnchor],
        [privacy.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [privacy.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];
    return row;
}

- (UIView *)locationTile:(MiOSContainer *)c accent:(UIColor *)accent {
    UIColor *partner = MiOSPartnerHue(accent);
    MiOSTapView *tile = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    tile.onTap = ^{ MiOSContainer *a = [ws active]; if (a) [ws openLocation:a]; };
    MiOSGradientView *bg = [self gradientTile:@[MiOSShiftedHue(partner, 0.0, 0.50, 0.82), MiOSShiftedHue(partner, 0.04, 0.70, 0.46)] radius:26];
    bg.userInteractionEnabled = NO;
    [tile addSubview:bg];
    [NSLayoutConstraint activateConstraints:@[
        [bg.topAnchor constraintEqualToAnchor:tile.topAnchor],
        [bg.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor],
        [bg.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor],
        [bg.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor],
    ]];

    UIImageView *skyline = [self watermark:@"building.2.fill" on:bg pointSize:96 color:[UIColor colorWithWhite:1 alpha:0.14] rotation:0];
    UIImageView *pinMark = [self watermark:@"mappin.and.ellipse" on:bg pointSize:34 color:[UIColor colorWithWhite:1 alpha:0.22] rotation:0];

    UIView *iconCircle = [[UIView alloc] init];
    iconCircle.translatesAutoresizingMaskIntoConstraints = NO;
    iconCircle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.20];
    iconCircle.layer.cornerRadius = 20;
    [bg addSubview:iconCircle];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"location.fill" size:16 color:[UIColor whiteColor]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [iconCircle addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.numberOfLines = 2;
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    [bg addSubview:title];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    [bg addSubview:sub];

    if (c.spoofLocation) {
        title.text = c.locationName.length ? c.locationName : @"Custom location";
        sub.text = [NSString stringWithFormat:@"%.4f, %.4f", c.coordinate.latitude, c.coordinate.longitude];
    } else { title.text = @"Real location"; sub.text = @"Tap to spoof GPS"; }

    [NSLayoutConstraint activateConstraints:@[
        [skyline.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:14],
        [skyline.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:12],
        [pinMark.centerXAnchor constraintEqualToAnchor:skyline.centerXAnchor constant:-10],
        [pinMark.bottomAnchor constraintEqualToAnchor:skyline.topAnchor constant:4],
        [iconCircle.topAnchor constraintEqualToAnchor:bg.topAnchor constant:16],
        [iconCircle.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16],
        [iconCircle.widthAnchor constraintEqualToConstant:40],
        [iconCircle.heightAnchor constraintEqualToConstant:40],
        [icon.centerXAnchor constraintEqualToAnchor:iconCircle.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:iconCircle.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16],
        [title.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-16],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.trailingAnchor constraintEqualToAnchor:title.trailingAnchor],
        [sub.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor constant:-16],
    ]];
    return tile;
}

- (UIView *)privacyTile:(MiOSContainer *)c accent:(UIColor *)accent {
    MiOSTapView *tile = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    tile.onTap = ^{ MiOSContainer *a = [ws active]; if (a) [ws openSpoof:a]; };
    tile.backgroundColor = [MiOSTheme tileBackground];
    tile.layer.cornerRadius = 22; tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.layer.borderWidth = 1.0; tile.layer.borderColor = [MiOSTheme hairline].CGColor;
    tile.clipsToBounds = YES;

    [self watermark:@"cpu" on:tile pointSize:78 color:[accent colorWithAlphaComponent:0.10] rotation:0.2];

    NSArray<NSNumber *> *flags = @[@(c.enableSpoofDeviceCheck), @(c.enableSpoofVendorID), @(c.enableSpoofAdvertisingID),
                                   @(c.enableSpoofCloudToken), @(c.enableSpoofDeviceModel), @(c.spoofLocation)];
    NSInteger onCount = 0; for (NSNumber *f in flags) onCount += f.boolValue ? 1 : 0;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Spoofing";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [MiOSTheme secondaryText];
    [tile addSubview:title];

    UILabel *score = [UILabel new];
    score.translatesAutoresizingMaskIntoConstraints = NO;
    score.text = [NSString stringWithFormat:@"%ld/%lu", (long)onCount, (unsigned long)flags.count];
    score.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    score.textColor = accent;
    [tile addSubview:score];

    // Big protection percentage in the middle (tile now runs full height).
    UILabel *big = [UILabel new];
    big.translatesAutoresizingMaskIntoConstraints = NO;
    big.text = [NSString stringWithFormat:@"%ld%%", (long)MiOSProtectionPercent(c)];
    big.font = [UIFont systemFontOfSize:40 weight:UIFontWeightBold];
    big.textColor = [MiOSTheme primaryText];
    [tile addSubview:big];
    UILabel *bigCap = [UILabel new];
    bigCap.translatesAutoresizingMaskIntoConstraints = NO;
    bigCap.text = @"protected";
    bigCap.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    bigCap.textColor = [MiOSTheme secondaryText];
    [tile addSubview:bigCap];

    UIStackView *bars = [[UIStackView alloc] init];
    bars.translatesAutoresizingMaskIntoConstraints = NO;
    bars.axis = UILayoutConstraintAxisHorizontal;
    bars.distribution = UIStackViewDistributionFillEqually;
    bars.alignment = UIStackViewAlignmentBottom;
    bars.spacing = 5;
    for (NSNumber *flag in flags) {
        BOOL on = flag.boolValue;
        UIView *bar = [[UIView alloc] init];
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        bar.backgroundColor = on ? accent : [UIColor colorWithWhite:1.0 alpha:0.10];
        bar.layer.cornerRadius = 4;
        [bar.heightAnchor constraintEqualToConstant:on ? 30 : 18].active = YES;
        [bars addArrangedSubview:bar];
    }
    [tile addSubview:bars];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:tile.topAnchor constant:14],
        [title.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [score.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [score.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-14],
        [big.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [big.centerYAnchor constraintEqualToAnchor:tile.centerYAnchor constant:2],
        [bigCap.leadingAnchor constraintEqualToAnchor:big.leadingAnchor constant:2],
        [bigCap.topAnchor constraintEqualToAnchor:big.bottomAnchor constant:-2],
        [bars.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [bars.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-14],
        [bars.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-14],
        [bars.heightAnchor constraintEqualToConstant:30],
    ]];
    return tile;
}

#pragma mark New Container card

- (UIView *)buildNewContainerCard:(UIColor *)accent {
    MiOSTapView *host = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    host.onTap = ^{ [ws newContainer]; };
    host.layer.shadowColor = accent.CGColor;
    host.layer.shadowOffset = CGSizeMake(0, 8);
    host.layer.shadowRadius = 18;
    host.layer.shadowOpacity = 0.35;

    MiOSGradientView *card = [self gradientTile:@[accent, [MiOSTheme accentGradientEnd]] radius:28];
    card.userInteractionEnabled = NO;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    [host addSubview:card];

    MiOSGradientView *sheen = [[MiOSGradientView alloc] init];
    sheen.translatesAutoresizingMaskIntoConstraints = NO;
    sheen.userInteractionEnabled = NO;
    [sheen setColors:@[[UIColor colorWithWhite:1.0 alpha:0.22], [UIColor colorWithWhite:1.0 alpha:0.0]]
               start:CGPointMake(0.5, 0.0) end:CGPointMake(0.5, 0.7)];
    [card addSubview:sheen];

    UIColor *textColor = [MiOSTheme textColorOnAccent];
    [self watermark:@"cube.fill" on:card pointSize:92 color:[textColor colorWithAlphaComponent:0.16] rotation:0.0];

    UIView *cubeBadge = [[UIView alloc] init];
    cubeBadge.translatesAutoresizingMaskIntoConstraints = NO;
    cubeBadge.backgroundColor = [textColor colorWithAlphaComponent:0.16];
    cubeBadge.layer.cornerRadius = 15; cubeBadge.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:cubeBadge];
    UIImageView *cubeIcon = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"cube.fill" size:24 color:textColor]];
    cubeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [cubeBadge addSubview:cubeIcon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"New Container";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = textColor;
    [card addSubview:title];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"Isolate sessions · spoof GPS, device & IDs";
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sub.textColor = [textColor colorWithAlphaComponent:0.85];
    sub.adjustsFontSizeToFitWidth = YES; sub.minimumScaleFactor = 0.8;
    [card addSubview:sub];

    UIView *arrowChip = [[UIView alloc] init];
    arrowChip.translatesAutoresizingMaskIntoConstraints = NO;
    arrowChip.backgroundColor = [textColor colorWithAlphaComponent:0.18];
    arrowChip.layer.cornerRadius = 16;
    [card addSubview:arrowChip];
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"arrow.right" size:15 color:textColor]];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    [arrowChip addSubview:arrow];

    [NSLayoutConstraint activateConstraints:@[
        [host.heightAnchor constraintEqualToConstant:100],
        [card.topAnchor constraintEqualToAnchor:host.topAnchor],
        [card.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [sheen.topAnchor constraintEqualToAnchor:card.topAnchor],
        [sheen.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [sheen.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [sheen.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [cubeBadge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [cubeBadge.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [cubeBadge.widthAnchor constraintEqualToConstant:52],
        [cubeBadge.heightAnchor constraintEqualToConstant:52],
        [cubeIcon.centerXAnchor constraintEqualToAnchor:cubeBadge.centerXAnchor],
        [cubeIcon.centerYAnchor constraintEqualToAnchor:cubeBadge.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:cubeBadge.trailingAnchor constant:14],
        [title.bottomAnchor constraintEqualToAnchor:card.centerYAnchor constant:2],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.trailingAnchor constraintEqualToAnchor:arrowChip.leadingAnchor constant:-8],
        [arrowChip.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [arrowChip.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [arrowChip.widthAnchor constraintEqualToConstant:32],
        [arrowChip.heightAnchor constraintEqualToConstant:32],
        [arrow.centerXAnchor constraintEqualToAnchor:arrowChip.centerXAnchor],
        [arrow.centerYAnchor constraintEqualToAnchor:arrowChip.centerYAnchor],
    ]];
    return host;
}

#pragma mark Tracker card (New-Container style, grey)

- (UIView *)buildTrackerCard:(MiOSContainer *)c {
    NSInteger pct = MiOSProtectionPercent(c);
    UIColor *top = [UIColor colorWithRed:0.34 green:0.35 blue:0.43 alpha:1.0];
    UIColor *bottom = [UIColor colorWithRed:0.17 green:0.18 blue:0.25 alpha:1.0];
    UIColor *textColor = [UIColor whiteColor];

    MiOSTapView *host = [[MiOSTapView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) ws = self;
    host.onTap = ^{ [ws openTracker]; };
    host.layer.shadowColor = [UIColor blackColor].CGColor;
    host.layer.shadowOffset = CGSizeMake(0, 8);
    host.layer.shadowRadius = 18;
    host.layer.shadowOpacity = 0.35;

    MiOSGradientView *card = [self gradientTile:@[top, bottom] radius:28];
    card.userInteractionEnabled = NO;
    card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    [host addSubview:card];

    MiOSGradientView *sheen = [[MiOSGradientView alloc] init];
    sheen.translatesAutoresizingMaskIntoConstraints = NO;
    sheen.userInteractionEnabled = NO;
    [sheen setColors:@[[UIColor colorWithWhite:1.0 alpha:0.14], [UIColor colorWithWhite:1.0 alpha:0.0]]
               start:CGPointMake(0.5, 0.0) end:CGPointMake(0.5, 0.7)];
    [card addSubview:sheen];

    [self watermark:@"checkmark.shield.fill" on:card pointSize:92 color:[textColor colorWithAlphaComponent:0.14] rotation:0.0];

    UIView *badge = [[UIView alloc] init];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.backgroundColor = [textColor colorWithAlphaComponent:0.16];
    badge.layer.cornerRadius = 15; badge.layer.cornerCurve = kCACornerCurveContinuous;
    [card addSubview:badge];
    UIImageView *badgeIcon = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:@"checkmark.shield.fill" size:24 color:textColor]];
    badgeIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:badgeIcon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Tracker";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = textColor;
    [card addSubview:title];

    UILabel *sub = [UILabel new];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"Health check · what Instagram tracks";
    sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    sub.textColor = [textColor colorWithAlphaComponent:0.85];
    sub.adjustsFontSizeToFitWidth = YES; sub.minimumScaleFactor = 0.8;
    [card addSubview:sub];

    UIView *pctChip = [[UIView alloc] init];
    pctChip.translatesAutoresizingMaskIntoConstraints = NO;
    pctChip.backgroundColor = [textColor colorWithAlphaComponent:0.18];
    pctChip.layer.cornerRadius = 16;
    [card addSubview:pctChip];
    UILabel *pctLabel = [UILabel new];
    pctLabel.translatesAutoresizingMaskIntoConstraints = NO;
    pctLabel.text = [NSString stringWithFormat:@"%ld%%", (long)pct];
    pctLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    pctLabel.textColor = textColor;
    [pctChip addSubview:pctLabel];

    [NSLayoutConstraint activateConstraints:@[
        [host.heightAnchor constraintEqualToConstant:100],
        [card.topAnchor constraintEqualToAnchor:host.topAnchor],
        [card.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [card.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [sheen.topAnchor constraintEqualToAnchor:card.topAnchor],
        [sheen.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [sheen.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [sheen.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [badge.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [badge.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:52],
        [badge.heightAnchor constraintEqualToConstant:52],
        [badgeIcon.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
        [badgeIcon.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:14],
        [title.bottomAnchor constraintEqualToAnchor:card.centerYAnchor constant:2],
        [sub.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.trailingAnchor constraintEqualToAnchor:pctChip.leadingAnchor constant:-8],
        [pctChip.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [pctChip.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [pctChip.heightAnchor constraintEqualToConstant:32],
        [pctLabel.leadingAnchor constraintEqualToAnchor:pctChip.leadingAnchor constant:12],
        [pctLabel.trailingAnchor constraintEqualToAnchor:pctChip.trailingAnchor constant:-12],
        [pctLabel.centerYAnchor constraintEqualToAnchor:pctChip.centerYAnchor],
    ]];
    return host;
}

#pragma mark Home actions

- (void)openSpoof:(MiOSContainer *)c {
    __weak typeof(self) ws = self;
    MiOSOpenSpoof(self, c, NO, ^{ [ws reload]; });
}
- (void)openLocation:(MiOSContainer *)c {
    MiOSLocationPage *p = [MiOSLocationPage new];
    p.container = c;
    [self miosPresentEditor:p title:@"Location"];
}
- (void)newContainer {
    NSArray *all = MiOSSortedContainers();
    MiOSContainer *c = [MiOSContainer newRandomContainerNamed:[NSString stringWithFormat:@"Container %lu", (unsigned long)all.count]];
    __weak typeof(self) ws = self;
    MiOSOpenSpoof(self, c, YES, ^{ [ws reload]; });   // created only on Save
}
- (void)openTracker {
    MiOSContainer *a = [self active];
    if (!a) return;
    MiOSTrackerPage *p = [MiOSTrackerPage new];
    p.container = a;
    [self miosPresentEditor:p title:@"Tracker"];
}
@end

#pragma mark - Tracker (health check)

@interface MiOSTrackerPage ()
- (UIView *)statCard:(NSString *)title icon:(NSString *)icon color:(UIColor *)color percent:(NSInteger)pct detail:(NSString *)detail;
- (UIView *)headerRow;
- (UIView *)itemRow:(MiOSSpoofItem *)it;
@end
@implementation MiOSTrackerPage

- (void)reload {
    [self clearStack];
    MiOSContainer *c = self.container; if (!c) return;
    NSArray<MiOSSpoofItem *> *items = MiOSProtectionItems(c);
    NSInteger total = (NSInteger)items.count;
    NSInteger spoofed = 0; for (MiOSSpoofItem *i in items) if (i.spoofed) spoofed++;
    NSInteger pct = total ? (NSInteger)lround((double)spoofed / total * 100.0) : 0;
    NSInteger exposed = total - spoofed;

    UILabel *name = [UILabel new];
    name.text = c.name.length ? c.name : @"Container";
    name.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    name.textColor = [MiOSTheme primaryText];
    [self.stack addArrangedSubview:name];

    UIStackView *stats = [[UIStackView alloc] init];
    stats.translatesAutoresizingMaskIntoConstraints = NO;
    stats.axis = UILayoutConstraintAxisHorizontal;
    stats.distribution = UIStackViewDistributionFillEqually;
    stats.spacing = 12;
    [stats addArrangedSubview:[self statCard:@"Protected" icon:@"checkmark.shield.fill" color:[MiOSTheme success]
                                     percent:pct detail:[NSString stringWithFormat:@"%ld spoofed", (long)spoofed]]];
    [stats addArrangedSubview:[self statCard:@"Exposed" icon:@"eye.trianglebadge.exclamationmark.fill" color:[MiOSTheme destructive]
                                     percent:(100 - pct) detail:[NSString stringWithFormat:@"%ld exposed", (long)exposed]]];
    [self.stack addArrangedSubview:stats];

    MiOSSectionCardView *card = [[MiOSSectionCardView alloc] initWithTitle:@"Data"];
    [card addCellView:[self headerRow]];
    for (MiOSSpoofItem *it in items) { [card addSeparator]; [card addCellView:[self itemRow:it]]; }
    [self.stack addArrangedSubview:card];
}

- (UIView *)statCard:(NSString *)title icon:(NSString *)icon color:(UIColor *)color percent:(NSInteger)pct detail:(NSString *)detail {
    UIView *tile = [[UIView alloc] init];
    tile.translatesAutoresizingMaskIntoConstraints = NO;
    tile.backgroundColor = [MiOSTheme tileBackground];
    tile.layer.cornerRadius = 20; tile.layer.cornerCurve = kCACornerCurveContinuous;
    tile.layer.borderWidth = 1.0; tile.layer.borderColor = [MiOSTheme hairline].CGColor;

    UIImageView *ic = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:icon size:16 color:color]];
    ic.translatesAutoresizingMaskIntoConstraints = NO;
    [tile addSubview:ic];
    UILabel *t = [UILabel new];
    t.translatesAutoresizingMaskIntoConstraints = NO;
    t.text = title; t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    t.textColor = [MiOSTheme secondaryText];
    [tile addSubview:t];
    UILabel *big = [UILabel new];
    big.translatesAutoresizingMaskIntoConstraints = NO;
    big.text = [NSString stringWithFormat:@"%ld%%", (long)pct];
    big.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    big.textColor = color;
    [tile addSubview:big];
    UILabel *det = [UILabel new];
    det.translatesAutoresizingMaskIntoConstraints = NO;
    det.text = detail; det.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    det.textColor = [MiOSTheme secondaryText];
    [tile addSubview:det];

    UIView *track = [[UIView alloc] init];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    track.layer.cornerRadius = 2.5;
    [tile addSubview:track];
    UIView *fill = [[UIView alloc] init];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = color; fill.layer.cornerRadius = 2.5;
    [track addSubview:fill];

    [NSLayoutConstraint activateConstraints:@[
        [tile.heightAnchor constraintEqualToConstant:118],
        [ic.topAnchor constraintEqualToAnchor:tile.topAnchor constant:14],
        [ic.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [t.centerYAnchor constraintEqualToAnchor:ic.centerYAnchor],
        [t.leadingAnchor constraintEqualToAnchor:ic.trailingAnchor constant:6],
        [big.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [big.topAnchor constraintEqualToAnchor:ic.bottomAnchor constant:6],
        [det.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [det.topAnchor constraintEqualToAnchor:big.bottomAnchor constant:0],
        [track.leadingAnchor constraintEqualToAnchor:tile.leadingAnchor constant:14],
        [track.trailingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:-14],
        [track.bottomAnchor constraintEqualToAnchor:tile.bottomAnchor constant:-14],
        [track.heightAnchor constraintEqualToConstant:5],
        [fill.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:track.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],
        [fill.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:MAX(0, MIN(100, pct)) / 100.0],
    ]];
    return tile;
}

- (UIView *)columnGlyph:(NSString *)symbol color:(UIColor *)color on:(UIView *)row center:(CGFloat)offset {
    UIImageView *g = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:symbol size:17 color:color]];
    g.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:g];
    [NSLayoutConstraint activateConstraints:@[
        [g.centerXAnchor constraintEqualToAnchor:row.trailingAnchor constant:offset],
        [g.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return g;
}

- (UIView *)headerRow {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *data = [UILabel new];
    data.translatesAutoresizingMaskIntoConstraints = NO;
    data.text = @"DATA"; data.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    data.textColor = [MiOSTheme tertiaryText];
    [row addSubview:data];
    UILabel *access = [UILabel new];
    access.translatesAutoresizingMaskIntoConstraints = NO;
    access.text = @"ACCESS"; access.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    access.textColor = [MiOSTheme tertiaryText]; access.textAlignment = NSTextAlignmentCenter;
    [row addSubview:access];
    UILabel *spoof = [UILabel new];
    spoof.translatesAutoresizingMaskIntoConstraints = NO;
    spoof.text = @"SPOOFED"; spoof.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    spoof.textColor = [MiOSTheme tertiaryText]; spoof.textAlignment = NSTextAlignmentCenter;
    [row addSubview:spoof];
    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:30],
        [data.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [data.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [access.centerXAnchor constraintEqualToAnchor:row.trailingAnchor constant:-78],
        [access.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [spoof.centerXAnchor constraintEqualToAnchor:row.trailingAnchor constant:-26],
        [spoof.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}

- (UIView *)itemRow:(MiOSSpoofItem *)it {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [[MiOSTheme accentColor] colorWithAlphaComponent:0.14];
    chip.layer.cornerRadius = 7;
    [row addSubview:chip];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[MiOSTheme symbol:it.icon size:13 color:[MiOSTheme accentColor]]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [chip addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = it.title; title.font = [MiOSTheme bodyFont]; title.textColor = [MiOSTheme primaryText];
    [row addSubview:title];

    [self columnGlyph:(it.accessed ? @"checkmark.circle.fill" : @"minus.circle")
                color:(it.accessed ? [MiOSTheme success] : [MiOSTheme tertiaryText]) on:row center:-78];
    [self columnGlyph:(it.spoofed ? @"checkmark.circle.fill" : @"xmark.circle.fill")
                color:(it.spoofed ? [MiOSTheme success] : [MiOSTheme destructive]) on:row center:-26];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintEqualToConstant:48],
        [chip.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [chip.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [chip.widthAnchor constraintEqualToConstant:26],
        [chip.heightAnchor constraintEqualToConstant:26],
        [icon.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:10],
        [title.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    return row;
}
@end

#pragma mark - PanModal presentation (grabber sheet)

@interface MiOSPanModalPresentationController : UIPresentationController
@property (nonatomic, strong) UIView *dimView;
@end
@implementation MiOSPanModalPresentationController
- (CGRect)frameOfPresentedViewInContainerView {
    CGRect b = self.containerView.bounds;
    CGFloat h = b.size.height * 0.94;
    return CGRectMake(0, b.size.height - h, b.size.width, h);
}
- (void)presentationTransitionWillBegin {
    self.dimView = [[UIView alloc] initWithFrame:self.containerView.bounds];
    self.dimView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    self.dimView.alpha = 0;
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.containerView addSubview:self.dimView];
    [self.dimView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_dismiss)]];
    [self.presentedViewController.transitionCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        self.dimView.alpha = 1;
    } completion:nil];
    self.presentedView.layer.cornerRadius = 28;
    self.presentedView.layer.cornerCurve = kCACornerCurveContinuous;
    self.presentedView.layer.masksToBounds = YES;
}
- (void)_dismiss { [self.presentingViewController dismissViewControllerAnimated:YES completion:nil]; }
- (void)dismissalTransitionWillBegin {
    [self.presentedViewController.transitionCoordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> ctx) {
        self.dimView.alpha = 0;
    } completion:nil];
}
@end
@interface MiOSPanModalDelegate : NSObject <UIViewControllerTransitioningDelegate>
@end
@implementation MiOSPanModalDelegate
+ (instancetype)shared { static MiOSPanModalDelegate *d; static dispatch_once_t o; dispatch_once(&o, ^{ d = [self new]; }); return d; }
- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                      presentingViewController:(UIViewController *)presenting
                                                          sourceViewController:(UIViewController *)source {
    return [[MiOSPanModalPresentationController alloc] initWithPresentedViewController:presented presentingViewController:presenting];
}
@end

#pragma mark - Main host

@interface MiOSMainVC : UIViewController
@property (nonatomic, strong) MiOSNebulaBackgroundView *nebula;
@property (nonatomic, strong) UIView *pageContainer;
@property (nonatomic, strong) MiOSFloatingTabBar *tabBar;
@property (nonatomic, strong) UINavigationController *currentNav;
@property (nonatomic, assign) NSInteger index;
@end
@implementation MiOSMainVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [MiOSTheme primaryBackground];

    MiOSEnsureDefault();

    _nebula = [[MiOSNebulaBackgroundView alloc] initWithFrame:self.view.bounds];
    _nebula.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_nebula updateAccent:[MiOSTheme accentColor]];
    [self.view addSubview:_nebula];

    UIView *grabber = [UIView new];
    grabber.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.3];
    grabber.layer.cornerRadius = 2.5;
    grabber.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:grabber];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[MiOSTheme symbol:@"xmark.circle.fill" size:26 color:[UIColor colorWithWhite:1 alpha:0.5]] forState:UIControlStateNormal];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(_close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    _pageContainer = [UIView new];
    _pageContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_pageContainer];

    __weak typeof(self) ws = self;
    _tabBar = [[MiOSFloatingTabBar alloc]
        initWithTitles:@[@"Home", @"Containers", @"Cloud", @"Proxies", @"Settings"]
                 icons:@[@"house.fill", @"square.stack.3d.up.fill", @"cloud.fill",
                         @"antenna.radiowaves.left.and.right", @"gearshape.fill"]];
    _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    _tabBar.onSelect = ^(NSInteger i){ [ws _selectIndex:i]; };
    [self.view addSubview:_tabBar];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [grabber.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [grabber.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [grabber.widthAnchor constraintEqualToConstant:40],
        [grabber.heightAnchor constraintEqualToConstant:5],
        [close.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:6],
        [close.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-14],
        [_pageContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:38],
        [_pageContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_pageContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_pageContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_tabBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tabBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tabBar.bottomAnchor constraintEqualToAnchor:g.bottomAnchor],
        [_tabBar.heightAnchor constraintEqualToConstant:[MiOSFloatingTabBar contentHeight]],
    ]];

    _tabBar.selectedIndex = 0;
    [self _selectIndex:0];
}

- (MiOSContainer *)activeOrFirst {
    MiOSContainer *a = [MiOSContainer activeContainer];
    return a ?: MiOSEnsureDefault();
}

- (UIViewController *)_pageForIndex:(NSInteger)i {
    switch (i) {
        case 0: return [MiOSHomePage new];
        case 1: return [MiOSContainersPage new];
        case 2: return [MiOSCloudPage new];
        case 3: { MiOSProxyPage *p = [MiOSProxyPage new]; p.container = [self activeOrFirst]; return p; }
        default: return [MiOSSettingsPage new];
    }
}

- (void)_selectIndex:(NSInteger)i {
    self.index = i;
    if (self.currentNav) {
        [self.currentNav willMoveToParentViewController:nil];
        [self.currentNav.view removeFromSuperview];
        [self.currentNav removeFromParentViewController];
    }
    UIViewController *page = [self _pageForIndex:i];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.navigationBar.hidden = YES;
    nav.view.backgroundColor = [UIColor clearColor];
    if ([page isKindOfClass:[MiOSPage class]]) ((MiOSPage *)page).host = nav;

    [self addChildViewController:nav];
    nav.view.frame = self.pageContainer.bounds;
    nav.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.pageContainer addSubview:nav.view];
    [nav didMoveToParentViewController:self];
    self.currentNav = nav;
}

- (void)_close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.presentingViewController == nil)
        [[NSNotificationCenter defaultCenter] postNotificationName:@"MiOSManagerDismissed" object:nil];
}
@end

#pragma mark - Floating button + top-level overlay window

@interface MiOSFloatingButton : UIButton @end
@implementation MiOSFloatingButton
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.superview) return;
    CGRect b = self.superview.bounds;
    if (b.size.width < 2) return;
    CGFloat x = MIN(MAX(self.center.x, 30), b.size.width - 30);
    CGFloat y = MIN(MAX(self.center.y, 80), b.size.height - 80);
    self.center = CGPointMake(x, y);
}
@end

@interface MiOSOverlayWindow : UIWindow
@property (nonatomic, assign) BOOL interactive;
@property (nonatomic, weak) UIView *passThroughButton;
@end
@implementation MiOSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.interactive) return hit;
    for (UIView *v = hit; v != nil; v = v.superview)
        if (v == self.passThroughButton) return hit;
    return nil;
}
@end

@interface MiOSUI ()
+ (void)ensureOverlay;
+ (void)addButton;
+ (void)managerDidDismiss;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (UIWindowScene *)activeWindowScene;
+ (UIWindow *)currentKeyWindow;
@end

@implementation MiOSUI

static MiOSOverlayWindow *gOverlay = nil;
static MiOSFloatingButton *gButton = nil;
static UIWindow *gPrevKey = nil;
static BOOL gInstalled = NO;

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;
    MiOSApplyAppAccent();
    NSArray<NSNotificationName> *names = @[
        UIApplicationDidBecomeActiveNotification,
        UIApplicationDidFinishLaunchingNotification,
        UIWindowDidBecomeKeyNotification,
        @"UISceneDidActivateNotification",
    ];
    for (NSNotificationName n in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil
            queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ [self ensureOverlay]; }];
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:@"MiOSManagerDismissed" object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *_){ [self managerDidDismiss]; }];
    for (NSNumber *delay in @[@0.3, @1.0, @2.5, @5.0, @10.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self ensureOverlay]; });
    }
}

+ (UIWindowScene *)activeWindowScene {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindowScene *fallback = nil;
    for (UIScene *s in app.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

+ (UIWindow *)currentKeyWindow {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows)
            if (w.isKeyWindow && w != gOverlay) return w;
    }
    return nil;
}

+ (void)ensureOverlay {
    UIWindowScene *scene = [self activeWindowScene];
    if (!scene) return;
    if (gOverlay) {
        if (gOverlay.windowScene != scene) gOverlay.windowScene = scene;
        gOverlay.hidden = NO;
        gOverlay.windowLevel = UIWindowLevelAlert + 1;
        if (!gButton.superview) [self addButton];
        else [gOverlay.rootViewController.view bringSubviewToFront:gButton];
        return;
    }
    CGRect bounds = scene.coordinateSpace.bounds;
    if (bounds.size.width < 2) bounds = UIScreen.mainScreen.bounds;
    MiOSOverlayWindow *w = [[MiOSOverlayWindow alloc] initWithWindowScene:scene];
    w.frame = bounds;
    w.windowLevel = UIWindowLevelAlert + 1;
    w.backgroundColor = [UIColor clearColor];
    w.opaque = NO;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor clearColor];
    w.rootViewController = root;
    w.hidden = NO;
    gOverlay = w;
    [self addButton];
}

+ (void)addButton {
    UIView *host = gOverlay.rootViewController.view;
    if (!host) return;
    CGRect hb = host.bounds;
    if (hb.size.width < 2) hb = UIScreen.mainScreen.bounds;
    [gButton removeFromSuperview];

    MiOSFloatingButton *b = [MiOSFloatingButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, 58, 58);
    b.center = CGPointMake(hb.size.width - 42, hb.size.height * 0.4);

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = b.bounds;
    grad.colors = @[(id)[MiOSTheme accentColor].CGColor, (id)[MiOSTheme accentGradientEnd].CGColor];
    grad.startPoint = CGPointMake(0, 0); grad.endPoint = CGPointMake(1, 1);
    grad.cornerRadius = 29;
    [b.layer addSublayer:grad];

    UIImageView *mascot = [[UIImageView alloc] initWithImage:[MiOSMascotRenderer mascotWithSize:CGSizeMake(38, 38) accent:[UIColor whiteColor]]];
    mascot.frame = CGRectMake((b.bounds.size.width - 38) / 2, (b.bounds.size.height - 38) / 2, 38, 38);
    mascot.contentMode = UIViewContentModeScaleAspectFit;
    mascot.userInteractionEnabled = NO;
    [b addSubview:mascot];

    b.layer.cornerRadius = 29;
    b.layer.shadowColor = [MiOSTheme accentColor].CGColor;
    b.layer.shadowOpacity = 0.55; b.layer.shadowRadius = 12; b.layer.shadowOffset = CGSizeMake(0, 4);
    [b addTarget:self action:@selector(present) forControlEvents:UIControlEventTouchUpInside];
    [b addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];

    [host addSubview:b];
    gButton = b;
    gOverlay.passThroughButton = b;
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *b = pan.view;
    CGPoint tr = [pan translationInView:b.superview];
    b.center = CGPointMake(b.center.x + tr.x, b.center.y + tr.y);
    [pan setTranslation:CGPointZero inView:b.superview];
}

+ (void)present {
    [self ensureOverlay];
    MiOSApplyAppAccent();
    UIViewController *root = gOverlay.rootViewController;
    if (!root || root.presentedViewController) return;
    gPrevKey = [self currentKeyWindow];
    gOverlay.interactive = YES;
    [gOverlay makeKeyAndVisible];
    MiOSMainVC *main = [MiOSMainVC new];
    main.transitioningDelegate = [MiOSPanModalDelegate shared];
    main.modalPresentationStyle = UIModalPresentationCustom;
    [root presentViewController:main animated:YES completion:nil];
}

+ (void)managerDidDismiss {
    gOverlay.interactive = NO;
    if (gPrevKey) { [gPrevKey makeKeyWindow]; gPrevKey = nil; }
}

@end
