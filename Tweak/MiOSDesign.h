#import <UIKit/UIKit.h>

// Reusable building blocks ported 1:1 from the standalone miOS app's design system
// (Views/ + Utils/), so the injected overlay matches the jailbreak build pixel-for-pixel:
// nebula background, pixel mascot, accent→violet hero, glass section cards, icon-chip
// rows, gradient primary button, and the raised floating tab bar.

#pragma mark - Gradient view

@interface MiOSGradientView : UIView
- (void)setColors:(NSArray<UIColor *> *)colors start:(CGPoint)start end:(CGPoint)end;
@end

#pragma mark - Nebula background

@interface MiOSNebulaBackgroundView : UIView
- (void)updateAccent:(UIColor *)accent;
@end

#pragma mark - Pixel mascot

@interface MiOSMascotRenderer : NSObject
+ (UIImage *)mascotWithSize:(CGSize)size accent:(UIColor *)accent;
@end

#pragma mark - Device image renderer (draws an iPhone from a model name)

typedef NS_ENUM(NSInteger, MiOSDeviceFormFactor) {
    MiOSDeviceFormFactorHomeButton,
    MiOSDeviceFormFactorNotch,
    MiOSDeviceFormFactorDynamicIsland,
};

@interface MiOSDeviceImageRenderer : NSObject
+ (UIImage *)renderDeviceForName:(NSString *)displayName size:(CGSize)size accentColor:(UIColor *)accent;
@end

#pragma mark - Color extractor (dominant palette from an app icon)

@interface MiOSColorExtractor : NSObject
+ (NSArray<UIColor *> *)paletteFromImage:(UIImage *)image;   // [primary, secondary?]
+ (UIColor *)accentGradientEndFromColor:(UIColor *)color;
@end

#pragma mark - Hero banner

@interface MiOSHeroBannerView : UIView
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, copy) NSString *subtitleText;     // e.g. active container name
@property (nonatomic, copy) void (^onToggle)(BOOL);
- (void)setEnabled:(BOOL)enabled animated:(BOOL)animated;
- (void)setStatusText:(NSString *)status;
@end

#pragma mark - Primary button (gradient + sheen + watermark)

@interface MiOSPrimaryButton : UIControl
@property (nonatomic, copy) NSString *title;
- (instancetype)initWithTitle:(NSString *)title watermark:(NSString *)symbolName;
- (void)refreshTheme;
@end

#pragma mark - Section card (uppercase header + rounded glass tile with stacked rows)

@interface MiOSSectionCardView : UIView
@property (nonatomic, strong, readonly) UIStackView *contentStack;
- (instancetype)initWithTitle:(NSString *)title;
- (void)addCellView:(UIView *)cell;
- (void)addSeparator;
@end

#pragma mark - Toggle row

@class MiOSToggleCell;
@protocol MiOSToggleCellDelegate <NSObject>
- (void)toggleCell:(MiOSToggleCell *)cell didChangeValue:(BOOL)value forKey:(NSString *)key;
@end

@interface MiOSToggleCell : UIView
@property (nonatomic, copy) NSString *key;
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, weak) id<MiOSToggleCellDelegate> delegate;
@property (nonatomic, copy) void (^onChange)(BOOL);
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                         icon:(NSString *)icon color:(UIColor *)color key:(NSString *)key;
- (void)setSubtitle:(NSString *)subtitle;
@end

#pragma mark - Navigation row (icon chip + title/subtitle + value + chevron)

@interface MiOSNavigationCell : UIView
@property (nonatomic, copy) NSString *valueText;      // right-aligned detail
@property (nonatomic, copy) NSString *badgeText;      // pill badge (optional)
@property (nonatomic, copy) void (^tapAction)(void);
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                         icon:(NSString *)icon color:(UIColor *)color;
- (void)setSubtitle:(NSString *)subtitle;
@end

#pragma mark - Text-field row (styled search / value field)

@interface MiOSFieldCell : UIView
@property (nonatomic, strong, readonly) UITextField *textField;
@property (nonatomic, copy) void (^onChange)(NSString *);
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon
                        value:(NSString *)value placeholder:(NSString *)placeholder;
@end

// Standalone pill search field (used atop the containers screen).
@interface MiOSSearchField : UIView
@property (nonatomic, strong, readonly) UITextField *textField;
@property (nonatomic, copy) void (^onChange)(NSString *);
- (instancetype)initWithPlaceholder:(NSString *)placeholder;
@end

#pragma mark - Button row (tinted, centered)

@interface MiOSButtonCell : UIView
@property (nonatomic, copy) void (^tapAction)(void);
- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color;
@end

#pragma mark - Floating tab bar

@interface MiOSFloatingTabBar : UIView
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) void (^onSelect)(NSInteger index);
+ (CGFloat)contentHeight;
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles icons:(NSArray<NSString *> *)icons;
@end
