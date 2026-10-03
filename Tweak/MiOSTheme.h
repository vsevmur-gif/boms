#import <UIKit/UIKit.h>

// miOS design system — ported 1:1 from the standalone miOS app so the in-Instagram
// overlay reads exactly like the jailbreak build (nebula background, glass cards,
// accent→violet gradients, pixel mascot, floating tab bar).

// Posted whenever the accent palette changes (e.g. a different container becomes active).
extern NSString *const MiOSThemeDidChangeNotification;

@interface MiOSTheme : NSObject

#pragma mark Dynamic accent

+ (void)setAccent:(UIColor *)accent gradientEnd:(UIColor *)gradientEnd;
+ (void)resetDynamicAccent;
+ (BOOL)hasDynamicAccent;
+ (BOOL)isLightColor:(UIColor *)color;
+ (UIColor *)textColorOnAccent;

#pragma mark Colors

+ (UIColor *)primaryBackground;
+ (UIColor *)secondaryBackground;
+ (UIColor *)cardBackground;
+ (UIColor *)glassBackground;
+ (UIColor *)tileBackground;
+ (UIColor *)hairline;
+ (UIColor *)accentColor;
+ (UIColor *)accentGradientEnd;
+ (UIColor *)primaryText;
+ (UIColor *)secondaryText;
+ (UIColor *)tertiaryText;
+ (UIColor *)separator;
+ (UIColor *)destructive;
+ (UIColor *)success;
+ (UIColor *)warning;

#pragma mark Fonts

+ (UIFont *)titleFont;
+ (UIFont *)headlineFont;
+ (UIFont *)bodyFont;
+ (UIFont *)captionFont;
+ (UIFont *)monoFont;
+ (UIFont *)roundedFont:(CGFloat)size weight:(UIFontWeight)weight;

#pragma mark Dimensions

+ (CGFloat)cornerRadius;
+ (CGFloat)cardCornerRadius;
+ (CGFloat)cardPadding;

#pragma mark Styling

+ (CAGradientLayer *)accentGradientForBounds:(CGRect)bounds;
+ (void)applyGlassEffectToView:(UIView *)view;
+ (void)applyAccentGlassEffectToView:(UIView *)view;
+ (void)applyGlowToView:(UIView *)view color:(UIColor *)color radius:(CGFloat)radius;
+ (UIColor *)accentTintedCardBackground;
+ (UIColor *)accentBorderColor;

#pragma mark Symbols

+ (UIImage *)symbol:(NSString *)name size:(CGFloat)size;
+ (UIImage *)symbol:(NSString *)name size:(CGFloat)size color:(UIColor *)color;

@end
