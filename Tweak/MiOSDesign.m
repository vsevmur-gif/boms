#import "MiOSDesign.h"
#import "MiOSTheme.h"
#import <math.h>

#pragma mark - MiOSGradientView

@implementation MiOSGradientView
+ (Class)layerClass { return [CAGradientLayer class]; }
- (CAGradientLayer *)gradientLayer { return (CAGradientLayer *)self.layer; }
- (void)setColors:(NSArray<UIColor *> *)colors start:(CGPoint)start end:(CGPoint)end {
    NSMutableArray *cg = [NSMutableArray arrayWithCapacity:colors.count];
    for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
    self.gradientLayer.colors = cg;
    self.gradientLayer.startPoint = start;
    self.gradientLayer.endPoint = end;
}
@end

#pragma mark - MiOSNebulaBackgroundView

@implementation MiOSNebulaBackgroundView {
    UIColor *_accent;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.opaque = YES;
        self.contentMode = UIViewContentModeRedraw;
        self.userInteractionEnabled = NO;
        _accent = [UIColor colorWithRed:0.0 green:0.82 blue:0.95 alpha:1.0];
    }
    return self;
}
- (void)updateAccent:(UIColor *)accent { if (!accent) return; _accent = accent; [self setNeedsDisplay]; }

static uint32_t miosRand(uint32_t *state) {
    *state = (*state * 1664525u) + 1013904223u;
    return *state;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;

    CGFloat ar, ag, ab, aa;
    if (![_accent getRed:&ar green:&ag blue:&ab alpha:&aa]) { ar = 0.0; ag = 0.82; ab = 0.95; }

    // 1. Base vertical gradient — deep indigo at the top easing to near-black.
    CGFloat baseComps[] = {
        0.07 + ar * 0.05, 0.07 + ag * 0.04, 0.16 + ab * 0.06, 1.0,
        0.04,             0.04,             0.09,             1.0,
        0.02,             0.02,             0.04,             1.0,
    };
    CGFloat baseLocs[] = {0.0, 0.5, 1.0};
    CGGradientRef base = CGGradientCreateWithColorComponents(space, baseComps, baseLocs, 3);
    CGContextDrawLinearGradient(ctx, base, CGPointMake(0, 0), CGPointMake(0, h), 0);
    CGGradientRelease(base);

    // 2. Neon accent bloom in the top-right.
    CGFloat bloomComps[] = { ar, ag, ab, 0.55, ar, ag, ab, 0.0 };
    CGFloat bloomLocs[] = {0.0, 1.0};
    CGGradientRef bloom = CGGradientCreateWithColorComponents(space, bloomComps, bloomLocs, 2);
    CGPoint bloomCenter = CGPointMake(w * 0.82, h * 0.10);
    CGContextDrawRadialGradient(ctx, bloom, bloomCenter, 0, bloomCenter, w * 0.72,
                                kCGGradientDrawsBeforeStartLocation);
    CGGradientRelease(bloom);

    // 3. Cooler secondary bloom low-left.
    CGFloat c2r = MIN(1.0, ab + 0.1), c2g = 0.4, c2b = MIN(1.0, ar + 0.5);
    CGFloat bloom2Comps[] = { c2r, c2g, c2b, 0.22, c2r, c2g, c2b, 0.0 };
    CGGradientRef bloom2 = CGGradientCreateWithColorComponents(space, bloom2Comps, bloomLocs, 2);
    CGPoint b2 = CGPointMake(w * 0.12, h * 0.62);
    CGContextDrawRadialGradient(ctx, bloom2, b2, 0, b2, w * 0.6, kCGGradientDrawsBeforeStartLocation);
    CGGradientRelease(bloom2);

    // 4. Faint scattered pixel specks — the "digital dust".
    uint32_t state = 0xA5F00D;
    NSInteger specks = (NSInteger)((w * h) / 5200.0);
    for (NSInteger i = 0; i < specks; i++) {
        CGFloat x = (miosRand(&state) % 1000) / 1000.0 * w;
        CGFloat y = (miosRand(&state) % 1000) / 1000.0 * h;
        uint32_t roll = miosRand(&state) % 100;
        CGFloat side = (roll % 3 == 0) ? 3.0 : 2.0;
        CGFloat alpha = 0.05 + (miosRand(&state) % 14) / 100.0;
        CGFloat prox = 1.0 - (hypot(x - bloomCenter.x, y - bloomCenter.y) / (w));
        if (prox > 0) alpha += prox * 0.12;
        BOOL tinted = (roll % 2 == 0);
        if (tinted) CGContextSetRGBFillColor(ctx, ar, ag, ab, MIN(0.5, alpha));
        else        CGContextSetRGBFillColor(ctx, 1.0, 1.0, 1.0, MIN(0.4, alpha));
        CGContextFillRect(ctx, CGRectMake(x, y, side, side));
    }
    CGColorSpaceRelease(space);
}
@end

#pragma mark - MiOSMascotRenderer

static NSArray<NSString *> *MiOSMascotGrid(void) {
    return @[
        @".A.......A.", @".AA.....AA.", @"..AA...AA..", @"..AAAAAAA..",
        @".AAAAAAAAA.", @"AAAAAAAAAAA", @"AAAAAAAAAAA", @"AAEEAAAEEAA",
        @"AAEEAAAEEAA", @"AAAAAAAAAAA", @".AAAMMMAAA.", @"..AAAAAAA..",
    ];
}
static UIColor *MiOSLighten(UIColor *c, CGFloat amount) {
    CGFloat h, s, b, a;
    if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) return c;
    return [UIColor colorWithHue:h saturation:MAX(0, s - amount * 0.5) brightness:MIN(1, b + amount) alpha:1.0];
}
static UIColor *MiOSDarken(UIColor *c, CGFloat amount) {
    CGFloat h, s, b, a;
    if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) return c;
    return [UIColor colorWithHue:h saturation:MIN(1, s + amount * 0.3) brightness:MAX(0, b - amount) alpha:1.0];
}

@implementation MiOSMascotRenderer

+ (void)drawMascotInContext:(CGContextRef)ctx rect:(CGRect)rect accent:(UIColor *)accent glow:(BOOL)glow {
    NSArray<NSString *> *grid = MiOSMascotGrid();
    NSInteger rows = grid.count;
    NSInteger cols = grid.firstObject.length;
    CGFloat inset = rect.size.width * 0.06;
    CGRect area = CGRectInset(rect, inset, inset);
    CGFloat cell = MIN(area.size.width / cols, area.size.height / rows);
    CGFloat gridW = cell * cols, gridH = cell * rows;
    CGFloat ox = area.origin.x + (area.size.width - gridW) / 2.0;
    CGFloat oy = area.origin.y + (area.size.height - gridH) / 2.0;

    UIColor *bodyTop = MiOSLighten(accent, 0.18);
    UIColor *bodyBottom = MiOSDarken(accent, 0.12);
    UIColor *eye = [UIColor colorWithWhite:1.0 alpha:1.0];
    UIColor *mouth = MiOSDarken(accent, 0.45);
    CGFloat pad = cell * 0.08;
    CGFloat radius = cell * 0.18;

    for (NSInteger r = 0; r < rows; r++) {
        NSString *row = grid[r];
        for (NSInteger c = 0; c < cols; c++) {
            unichar ch = [row characterAtIndex:c];
            if (ch == '.') continue;
            UIColor *fill;
            BOOL isEye = (ch == 'E');
            if (ch == 'E') fill = eye;
            else if (ch == 'M') fill = mouth;
            else {
                CGFloat t = (CGFloat)r / (CGFloat)(rows - 1);
                CGFloat rr, gg, bb, aa, rr2, gg2, bb2, aa2;
                [bodyTop getRed:&rr green:&gg blue:&bb alpha:&aa];
                [bodyBottom getRed:&rr2 green:&gg2 blue:&bb2 alpha:&aa2];
                fill = [UIColor colorWithRed:rr + (rr2 - rr) * t
                                       green:gg + (gg2 - gg) * t
                                        blue:bb + (bb2 - bb) * t alpha:1.0];
            }
            CGRect px = CGRectMake(ox + c * cell + pad, oy + r * cell + pad, cell - pad * 2, cell - pad * 2);
            if (isEye && glow) {
                CGContextSaveGState(ctx);
                CGContextSetShadowWithColor(ctx, CGSizeZero, cell * 0.9, accent.CGColor);
                [[UIBezierPath bezierPathWithRoundedRect:px cornerRadius:radius] fill];
            }
            [fill setFill];
            [[UIBezierPath bezierPathWithRoundedRect:px cornerRadius:radius] fill];
            if (isEye && glow) CGContextRestoreGState(ctx);
        }
    }
}

+ (UIImage *)mascotWithSize:(CGSize)size accent:(UIColor *)accent {
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef ctx = rc.CGContext;
        CGRect bounds = CGRectMake(0, 0, size.width, size.height);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, size.width * 0.12, [accent colorWithAlphaComponent:0.6].CGColor);
        [self drawMascotInContext:ctx rect:bounds accent:accent glow:NO];
        CGContextRestoreGState(ctx);
        [self drawMascotInContext:ctx rect:bounds accent:accent glow:YES];
    }];
}
@end

#pragma mark - MiOSHeroBannerView

@implementation MiOSHeroBannerView {
    UIView *_gradientContainer;
    CAGradientLayer *_gradient;
    UILabel *_logoLabel;
    UILabel *_versionLabel;
    UILabel *_subtitleLabel;
    UILabel *_statusLabel;
    UIView *_statusDot;
    UISwitch *_masterToggle;
    UIView *_pixelGrid;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) { [self setupView]; }
    return self;
}

- (void)setupView {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = [MiOSTheme cardCornerRadius];
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;

    _gradientContainer = [[UIView alloc] init];
    _gradientContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_gradientContainer];

    [self buildPixelDecoration];

    UIView *overlay = [[UIView alloc] init];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
    overlay.userInteractionEnabled = NO;
    [self addSubview:overlay];

    _logoLabel = [[UILabel alloc] init];
    _logoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logoLabel.text = @"miOS";
    _logoLabel.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBlack];
    _logoLabel.textColor = [UIColor whiteColor];
    [self addSubview:_logoLabel];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.text = @"v2.0.0";
    _versionLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    _versionLabel.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [self addSubview:_versionLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _subtitleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    [self addSubview:_subtitleLabel];

    _statusDot = [[UIView alloc] init];
    _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    _statusDot.backgroundColor = [UIColor systemGreenColor];
    _statusDot.layer.cornerRadius = 4;
    [self addSubview:_statusDot];

    _statusLabel = [[UILabel alloc] init];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.text = @"Active";
    _statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.8];
    [self addSubview:_statusLabel];

    _masterToggle = [[UISwitch alloc] init];
    _masterToggle.translatesAutoresizingMaskIntoConstraints = NO;
    _masterToggle.onTintColor = [UIColor colorWithWhite:1 alpha:0.3];
    _masterToggle.thumbTintColor = [UIColor whiteColor];
    [_masterToggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_masterToggle];

    self.layer.shadowColor = [MiOSTheme accentColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    self.layer.shadowRadius = 20;
    self.layer.shadowOpacity = 0.2;

    [NSLayoutConstraint activateConstraints:@[
        [_gradientContainer.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_gradientContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_gradientContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_gradientContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [overlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [overlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_logoLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:22],
        [_logoLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_versionLabel.leadingAnchor constraintEqualToAnchor:_logoLabel.trailingAnchor constant:8],
        [_versionLabel.bottomAnchor constraintEqualToAnchor:_logoLabel.bottomAnchor constant:-4],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_logoLabel.bottomAnchor constant:4],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-96],
        [_statusDot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
        [_statusDot.widthAnchor constraintEqualToConstant:8],
        [_statusDot.heightAnchor constraintEqualToConstant:8],
        [_statusDot.centerYAnchor constraintEqualToAnchor:_statusLabel.centerYAnchor],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_statusDot.trailingAnchor constant:6],
        [_statusLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-18],
        [_masterToggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-20],
        [_masterToggle.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
        [self.heightAnchor constraintEqualToConstant:150],
    ]];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshAccent)
                                                 name:MiOSThemeDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)buildPixelDecoration {
    _pixelGrid = [[UIView alloc] init];
    _pixelGrid.translatesAutoresizingMaskIntoConstraints = NO;
    _pixelGrid.alpha = 0.10;
    _pixelGrid.userInteractionEnabled = NO;
    [self addSubview:_pixelGrid];
    [NSLayoutConstraint activateConstraints:@[
        [_pixelGrid.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_pixelGrid.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_pixelGrid.widthAnchor constraintEqualToConstant:120],
        [_pixelGrid.heightAnchor constraintEqualToConstant:120],
    ]];
    CGFloat size = 8;
    NSArray *pixels = @[
        @[@2,@1],@[@3,@1],@[@4,@1],@[@5,@1], @[@1,@2],@[@2,@2],@[@5,@2],@[@6,@2],
        @[@1,@3],@[@2,@3],@[@3,@3],@[@4,@3],@[@5,@3],@[@6,@3], @[@2,@4],@[@3,@4],@[@4,@4],@[@5,@4],
        @[@1,@5],@[@2,@5],@[@5,@5],@[@6,@5], @[@3,@6],@[@4,@6],
        @[@2,@7],@[@3,@7],@[@4,@7],@[@5,@7], @[@1,@8],@[@6,@8],
    ];
    for (NSArray *p in pixels) {
        UIView *px = [[UIView alloc] initWithFrame:CGRectMake([p[0] floatValue]*(size+2)+20,
                                                              [p[1] floatValue]*(size+2)+10, size, size)];
        px.backgroundColor = [UIColor whiteColor];
        px.layer.cornerRadius = 2;
        [_pixelGrid addSubview:px];
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (!_gradient) {
        _gradient = [CAGradientLayer layer];
        [_gradientContainer.layer insertSublayer:_gradient atIndex:0];
        [self refreshAccent];
    }
    _gradient.frame = _gradientContainer.bounds;
}

- (void)refreshAccent {
    UIColor *accent = [MiOSTheme accentColor];
    UIColor *accentEnd = [MiOSTheme accentGradientEnd];
    CGFloat r1,g1,b1,a1; [accent getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    CGFloat r2,g2,b2,a2; [accentEnd getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    UIColor *mid = [UIColor colorWithRed:(r1+r2)*0.5 green:(g1+g2)*0.5 blue:(b1+b2)*0.5 alpha:1.0];
    _gradient.colors = @[(id)accent.CGColor, (id)mid.CGColor, (id)accentEnd.CGColor];
    _gradient.startPoint = CGPointMake(0, 0);
    _gradient.endPoint = CGPointMake(1, 1);
    self.layer.shadowColor = accent.CGColor;
}

- (void)setSubtitleText:(NSString *)subtitleText { _subtitleText = [subtitleText copy]; _subtitleLabel.text = subtitleText; }
- (void)setStatusText:(NSString *)status { _statusLabel.text = status; }

- (void)setEnabled:(BOOL)enabled animated:(BOOL)animated {
    _isEnabled = enabled;
    _masterToggle.on = enabled;
    void (^updates)(void) = ^{
        self->_statusLabel.text = enabled ? @"Spoofing active" : @"Spoofing off";
        self->_statusDot.backgroundColor = enabled ? [UIColor systemGreenColor] : [UIColor systemRedColor];
        self->_gradientContainer.alpha = enabled ? 1.0 : 0.4;
    };
    if (animated) [UIView animateWithDuration:0.3 animations:updates]; else updates();
}

- (void)toggleChanged:(UISwitch *)sender {
    [self setEnabled:sender.on animated:YES];
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    if (_onToggle) _onToggle(sender.on);
}
@end

#pragma mark - MiOSPrimaryButton

@implementation MiOSPrimaryButton {
    MiOSGradientView *_fill;
    MiOSGradientView *_sheen;
    UIImageView *_watermark;
    UILabel *_label;
}
- (instancetype)initWithTitle:(NSString *)title watermark:(NSString *)symbolName {
    if (self = [super initWithFrame:CGRectZero]) {
        self.translatesAutoresizingMaskIntoConstraints = NO;

        _fill = [[MiOSGradientView alloc] init];
        _fill.translatesAutoresizingMaskIntoConstraints = NO;
        _fill.userInteractionEnabled = NO;
        _fill.layer.cornerRadius = 24;
        _fill.layer.cornerCurve = kCACornerCurveContinuous;
        _fill.layer.borderWidth = 1.0;
        _fill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        _fill.clipsToBounds = YES;
        [self addSubview:_fill];

        _sheen = [[MiOSGradientView alloc] init];
        _sheen.translatesAutoresizingMaskIntoConstraints = NO;
        _sheen.userInteractionEnabled = NO;
        [_sheen setColors:@[[UIColor colorWithWhite:1 alpha:0.22], [UIColor colorWithWhite:1 alpha:0]]
                    start:CGPointMake(0.5, 0) end:CGPointMake(0.5, 0.75)];
        [_fill addSubview:_sheen];

        if (symbolName) {
            UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:54 weight:UIImageSymbolWeightBold];
            _watermark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:cfg]];
            _watermark.translatesAutoresizingMaskIntoConstraints = NO;
            _watermark.transform = CGAffineTransformMakeRotation(-0.2);
            [_fill addSubview:_watermark];
            [NSLayoutConstraint activateConstraints:@[
                [_watermark.centerXAnchor constraintEqualToAnchor:_fill.trailingAnchor constant:-34],
                [_watermark.centerYAnchor constraintEqualToAnchor:_fill.centerYAnchor constant:8],
            ]];
        }

        _label = [[UILabel alloc] init];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        _label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        _label.textAlignment = NSTextAlignmentCenter;
        [_fill addSubview:_label];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:56],
            [_fill.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_fill.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_fill.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_fill.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_sheen.topAnchor constraintEqualToAnchor:_fill.topAnchor],
            [_sheen.leadingAnchor constraintEqualToAnchor:_fill.leadingAnchor],
            [_sheen.trailingAnchor constraintEqualToAnchor:_fill.trailingAnchor],
            [_sheen.bottomAnchor constraintEqualToAnchor:_fill.bottomAnchor],
            [_label.centerXAnchor constraintEqualToAnchor:_fill.centerXAnchor],
            [_label.centerYAnchor constraintEqualToAnchor:_fill.centerYAnchor],
            [_label.leadingAnchor constraintGreaterThanOrEqualToAnchor:_fill.leadingAnchor constant:20],
        ]];

        self.layer.shadowOffset = CGSizeMake(0, 8);
        self.layer.shadowRadius = 16;
        self.layer.shadowOpacity = 0.35;
        self.title = title;
        [self refreshTheme];
    }
    return self;
}
- (void)setTitle:(NSString *)title { _title = [title copy]; _label.text = title; }
- (void)refreshTheme {
    UIColor *accent = [MiOSTheme accentColor];
    [_fill setColors:@[accent, [MiOSTheme accentGradientEnd]] start:CGPointMake(0, 0) end:CGPointMake(1, 1)];
    UIColor *text = [MiOSTheme textColorOnAccent];
    _label.textColor = text;
    _watermark.tintColor = [text colorWithAlphaComponent:0.14];
    self.layer.shadowColor = accent.CGColor;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
        self.alpha = highlighted ? 0.9 : 1.0;
    } completion:nil];
}
@end

#pragma mark - MiOSSectionCardView

@implementation MiOSSectionCardView {
    UILabel *_headerLabel;
    UIView *_cardBg;
}
- (instancetype)initWithTitle:(NSString *)title {
    if (self = [super initWithFrame:CGRectZero]) {
        [self setupViewWithTitle:title];
    }
    return self;
}
- (void)setupViewWithTitle:(NSString *)title {
    self.translatesAutoresizingMaskIntoConstraints = NO;

    _headerLabel = [[UILabel alloc] init];
    _headerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _headerLabel.text = [title uppercaseString];
    _headerLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    _headerLabel.textColor = [MiOSTheme accentColor];
    _headerLabel.hidden = (title.length == 0);
    [self addSubview:_headerLabel];

    _cardBg = [[UIView alloc] init];
    _cardBg.translatesAutoresizingMaskIntoConstraints = NO;
    _cardBg.backgroundColor = [MiOSTheme tileBackground];
    _cardBg.layer.cornerRadius = 24;
    _cardBg.layer.cornerCurve = kCACornerCurveContinuous;
    _cardBg.layer.borderWidth = 1.0;
    _cardBg.layer.borderColor = [MiOSTheme hairline].CGColor;
    [self addSubview:_cardBg];

    _contentStack = [[UIStackView alloc] init];
    _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    _contentStack.axis = UILayoutConstraintAxisVertical;
    _contentStack.spacing = 0;
    [_cardBg addSubview:_contentStack];

    CGFloat headerHeight = title.length > 0 ? 24 : 0;
    [NSLayoutConstraint activateConstraints:@[
        [_headerLabel.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_headerLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_headerLabel.heightAnchor constraintEqualToConstant:headerHeight],
        [_cardBg.topAnchor constraintEqualToAnchor:_headerLabel.bottomAnchor constant:title.length > 0 ? 8 : 0],
        [_cardBg.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_cardBg.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_cardBg.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_contentStack.topAnchor constraintEqualToAnchor:_cardBg.topAnchor],
        [_contentStack.leadingAnchor constraintEqualToAnchor:_cardBg.leadingAnchor],
        [_contentStack.trailingAnchor constraintEqualToAnchor:_cardBg.trailingAnchor],
        [_contentStack.bottomAnchor constraintEqualToAnchor:_cardBg.bottomAnchor],
    ]];
}
- (void)addCellView:(UIView *)cell {
    cell.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentStack addArrangedSubview:cell];
}
- (void)addSeparator {
    UIView *wrapper = [[UIView alloc] init];
    wrapper.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentStack addArrangedSubview:wrapper];
    UIView *line = [[UIView alloc] init];
    line.translatesAutoresizingMaskIntoConstraints = NO;
    line.backgroundColor = [MiOSTheme separator];
    [wrapper addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
        [wrapper.heightAnchor constraintEqualToConstant:0.5],
        [line.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
        [line.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
        [line.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor constant:54],
        [line.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    ]];
}
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    _cardBg.layer.borderColor = [MiOSTheme hairline].CGColor;
}
@end

#pragma mark - Icon chip helper

static UIView *MiOSIconChip(NSString *iconName, UIColor *iconColor, UIImageView **outIcon) {
    UIView *chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = [iconColor colorWithAlphaComponent:0.18];
    chip.layer.cornerRadius = 16;
    chip.layer.shadowColor = iconColor.CGColor;
    chip.layer.shadowOffset = CGSizeZero;
    chip.layer.shadowRadius = 6;
    chip.layer.shadowOpacity = 0.2;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:iconName withConfiguration:config]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.tintColor = iconColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [chip addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [chip.widthAnchor constraintEqualToConstant:32],
        [chip.heightAnchor constraintEqualToConstant:32],
        [icon.centerXAnchor constraintEqualToAnchor:chip.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:chip.centerYAnchor],
    ]];
    if (outIcon) *outIcon = icon;
    return chip;
}

#pragma mark - MiOSToggleCell

@implementation MiOSToggleCell {
    UIView *_iconContainer;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UISwitch *_toggle;
    UIColor *_iconColor;
}
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                         icon:(NSString *)icon color:(UIColor *)color key:(NSString *)key {
    if (self = [super initWithFrame:CGRectZero]) {
        _key = [key copy];
        _iconColor = color ?: [MiOSTheme accentColor];
        [self setupWithTitle:title subtitle:subtitle icon:icon];
    }
    return self;
}
- (void)setupWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(NSString *)icon {
    self.backgroundColor = [UIColor clearColor];
    UIImageView *iconLocal = nil;
    _iconContainer = MiOSIconChip(icon, _iconColor, &iconLocal);
    _iconView = iconLocal;
    [self addSubview:_iconContainer];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = title;
    _titleLabel.font = [MiOSTheme headlineFont];
    _titleLabel.textColor = [MiOSTheme primaryText];
    _titleLabel.numberOfLines = 1;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    [_titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.text = subtitle;
    _subtitleLabel.font = [MiOSTheme captionFont];
    _subtitleLabel.textColor = [MiOSTheme secondaryText];
    _subtitleLabel.numberOfLines = 2;
    _subtitleLabel.hidden = (subtitle.length == 0);
    [self addSubview:_subtitleLabel];

    _toggle = [[UISwitch alloc] init];
    _toggle.translatesAutoresizingMaskIntoConstraints = NO;
    _toggle.onTintColor = [MiOSTheme accentColor];
    _toggle.on = _isOn;
    [_toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_toggle];

    [NSLayoutConstraint activateConstraints:@[
        [_iconContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_iconContainer.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:10],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_toggle.leadingAnchor constant:-8],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_toggle.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_toggle.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:56],
    ]];
    if (subtitle.length > 0) {
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
        ]];
    } else {
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
    }
}
- (void)setIsOn:(BOOL)isOn { _isOn = isOn; _toggle.on = isOn; }
- (void)setSubtitle:(NSString *)subtitle { _subtitleLabel.text = subtitle; _subtitleLabel.hidden = (subtitle.length == 0); }
- (void)toggleChanged:(UISwitch *)sender {
    _isOn = sender.on;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    if (_onChange) _onChange(sender.on);
    if (_delegate) [_delegate toggleCell:self didChangeValue:sender.on forKey:_key];
}
@end

#pragma mark - MiOSNavigationCell

@implementation MiOSNavigationCell {
    UIView *_iconContainer;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_subtitleLabel;
    UILabel *_valueLabel;
    UIImageView *_chevron;
    UILabel *_badgeLabel;
    UIColor *_iconColor;
}
- (instancetype)initWithTitle:(NSString *)title subtitle:(NSString *)subtitle
                         icon:(NSString *)icon color:(UIColor *)color {
    if (self = [super initWithFrame:CGRectZero]) {
        _iconColor = color ?: [MiOSTheme accentColor];
        [self setupWithTitle:title subtitle:subtitle icon:icon];
    }
    return self;
}
- (void)setupWithTitle:(NSString *)title subtitle:(NSString *)subtitle icon:(NSString *)icon {
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;
    UIImageView *iconLocal = nil;
    _iconContainer = MiOSIconChip(icon, _iconColor, &iconLocal);
    _iconView = iconLocal;
    [self addSubview:_iconContainer];

    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.text = title;
    _titleLabel.font = [MiOSTheme headlineFont];
    _titleLabel.textColor = [MiOSTheme primaryText];
    _titleLabel.numberOfLines = 1;
    [self addSubview:_titleLabel];

    _subtitleLabel = [[UILabel alloc] init];
    _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _subtitleLabel.text = subtitle;
    _subtitleLabel.font = [MiOSTheme captionFont];
    _subtitleLabel.textColor = [MiOSTheme secondaryText];
    _subtitleLabel.numberOfLines = 1;
    _subtitleLabel.hidden = (subtitle.length == 0);
    [self addSubview:_subtitleLabel];

    _valueLabel = [[UILabel alloc] init];
    _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _valueLabel.font = [MiOSTheme bodyFont];
    _valueLabel.textColor = [MiOSTheme secondaryText];
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [_valueLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:_valueLabel];

    UIImageSymbolConfiguration *chevCfg = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right" withConfiguration:chevCfg]];
    _chevron.translatesAutoresizingMaskIntoConstraints = NO;
    _chevron.tintColor = [MiOSTheme tertiaryText];
    [self addSubview:_chevron];

    _badgeLabel = [[UILabel alloc] init];
    _badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _badgeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _badgeLabel.textColor = [UIColor whiteColor];
    _badgeLabel.textAlignment = NSTextAlignmentCenter;
    _badgeLabel.backgroundColor = [MiOSTheme accentColor];
    _badgeLabel.layer.cornerRadius = 10;
    _badgeLabel.layer.masksToBounds = YES;
    _badgeLabel.hidden = YES;
    [self addSubview:_badgeLabel];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];

    [NSLayoutConstraint activateConstraints:@[
        [_iconContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_iconContainer.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:10],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:_chevron.leadingAnchor constant:-8],
        [_valueLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:8],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor constant:-8],
        [_chevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [_chevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_badgeLabel.trailingAnchor constraintEqualToAnchor:_chevron.leadingAnchor constant:-8],
        [_badgeLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:20],
        [_badgeLabel.heightAnchor constraintEqualToConstant:20],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:56],
    ]];
    if (subtitle.length > 0) {
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:11],
            [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-11],
        ]];
    } else {
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;
    }
}
- (void)setValueText:(NSString *)valueText { _valueText = [valueText copy]; _valueLabel.text = valueText; }
- (void)setBadgeText:(NSString *)badgeText {
    _badgeText = [badgeText copy];
    _badgeLabel.text = [NSString stringWithFormat:@"  %@  ", badgeText];
    _badgeLabel.hidden = (badgeText.length == 0);
}
- (void)setSubtitle:(NSString *)subtitle { _subtitleLabel.text = subtitle; _subtitleLabel.hidden = (subtitle.length == 0); }
- (void)tapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [UIView animateWithDuration:0.1 animations:^{ self.alpha = 0.5; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.15 animations:^{ self.alpha = 1.0; }];
    }];
    if (_tapAction) _tapAction();
}
@end

#pragma mark - MiOSFieldCell

@implementation MiOSFieldCell {
    UIView *_iconContainer;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UITextField *_field;
}
- (instancetype)initWithTitle:(NSString *)title icon:(NSString *)icon
                        value:(NSString *)value placeholder:(NSString *)placeholder {
    if (self = [super initWithFrame:CGRectZero]) {
        self.backgroundColor = [UIColor clearColor];
        UIImageView *iconLocal = nil;
        _iconContainer = MiOSIconChip(icon ?: @"pencil", [MiOSTheme accentColor], &iconLocal);
        _iconView = iconLocal;
        [self addSubview:_iconContainer];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = title;
        _titleLabel.font = [MiOSTheme headlineFont];
        _titleLabel.textColor = [MiOSTheme primaryText];
        [_titleLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self addSubview:_titleLabel];

        _field = [[UITextField alloc] init];
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        _field.font = [MiOSTheme bodyFont];
        _field.textColor = [MiOSTheme secondaryText];
        _field.textAlignment = NSTextAlignmentRight;
        _field.text = value;
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder ?: @""
            attributes:@{NSForegroundColorAttributeName: [MiOSTheme tertiaryText]}];
        [_field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_field];

        [NSLayoutConstraint activateConstraints:@[
            [_iconContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [_iconContainer.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:10],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_field.leadingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor constant:8],
            [_field.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
            [_field.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:56],
        ]];
    }
    return self;
}
- (UITextField *)textField { return _field; }
- (void)changed { if (_onChange) _onChange(_field.text ?: @""); }
@end

#pragma mark - MiOSSearchField

@implementation MiOSSearchField {
    UITextField *_field;
}
- (instancetype)initWithPlaceholder:(NSString *)placeholder {
    if (self = [super initWithFrame:CGRectZero]) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = [MiOSTheme tileBackground];
        self.layer.cornerRadius = 14;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [MiOSTheme hairline].CGColor;

        UIImageView *glass = [[UIImageView alloc] initWithImage:
            [MiOSTheme symbol:@"magnifyingglass" size:15 color:[MiOSTheme secondaryText]]];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:glass];

        _field = [[UITextField alloc] init];
        _field.translatesAutoresizingMaskIntoConstraints = NO;
        _field.font = [MiOSTheme bodyFont];
        _field.textColor = [MiOSTheme primaryText];
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.clearButtonMode = UITextFieldViewModeWhileEditing;
        _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder ?: @""
            attributes:@{NSForegroundColorAttributeName: [MiOSTheme tertiaryText]}];
        [_field addTarget:self action:@selector(changed) forControlEvents:UIControlEventEditingChanged];
        [self addSubview:_field];

        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintEqualToConstant:44],
            [glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
            [glass.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_field.leadingAnchor constraintEqualToAnchor:glass.trailingAnchor constant:8],
            [_field.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_field.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}
- (UITextField *)textField { return _field; }
- (void)changed { if (_onChange) _onChange(_field.text ?: @""); }
@end

#pragma mark - MiOSButtonCell

@implementation MiOSButtonCell {
    UILabel *_titleLabel;
    UIColor *_buttonColor;
}
- (instancetype)initWithTitle:(NSString *)title color:(UIColor *)color {
    if (self = [super initWithFrame:CGRectZero]) {
        _buttonColor = color ?: [MiOSTheme accentColor];
        self.backgroundColor = [_buttonColor colorWithAlphaComponent:0.12];
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _titleLabel.textColor = _buttonColor;
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
        [NSLayoutConstraint activateConstraints:@[
            [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintEqualToConstant:50],
        ]];
    }
    return self;
}
- (void)tapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [UIView animateWithDuration:0.08 animations:^{
        self.transform = CGAffineTransformMakeScale(0.97, 0.97); self.alpha = 0.7;
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0 animations:^{
            self.transform = CGAffineTransformIdentity; self.alpha = 1.0;
        } completion:nil];
    }];
    if (_tapAction) _tapAction();
}
@end

#pragma mark - MiOSFloatingTabBar

static const CGFloat kItemSize = 50;
static const CGFloat kCenterItemSize = 60;
static const CGFloat kTopPadding = 8;

@implementation MiOSFloatingTabBar {
    NSArray<NSString *> *_titles;
    NSArray<NSString *> *_icons;
    NSMutableArray<UIView *> *_circles;
    NSMutableArray<UIImageView *> *_iconViews;
    NSMutableArray<UILabel *> *_labels;
    CAGradientLayer *_fadeLayer;
    CAShapeLayer *_arcLayer;
}
+ (CGFloat)contentHeight { return 104; }

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles icons:(NSArray<NSString *> *)icons {
    if (self = [super initWithFrame:CGRectZero]) {
        _titles = [titles copy];
        _icons = [icons copy];
        _circles = [NSMutableArray array];
        _iconViews = [NSMutableArray array];
        _labels = [NSMutableArray array];
        [self setupView];
    }
    return self;
}
- (void)setupView {
    _fadeLayer = [CAGradientLayer layer];
    _fadeLayer.colors = @[
        (id)[UIColor colorWithRed:0.03 green:0.03 blue:0.06 alpha:0.0].CGColor,
        (id)[UIColor colorWithRed:0.03 green:0.03 blue:0.06 alpha:0.85].CGColor,
        (id)[UIColor colorWithRed:0.03 green:0.03 blue:0.06 alpha:0.97].CGColor,
    ];
    _fadeLayer.locations = @[@0.0, @0.35, @1.0];
    [self.layer addSublayer:_fadeLayer];

    _arcLayer = [CAShapeLayer layer];
    _arcLayer.fillColor = [UIColor clearColor].CGColor;
    _arcLayer.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    _arcLayer.lineWidth = 1.0;
    [self.layer addSublayer:_arcLayer];

    for (NSInteger i = 0; i < (NSInteger)_titles.count; i++) {
        UIView *circle = [[UIView alloc] init];
        circle.tag = i;
        circle.layer.borderWidth = 1.0;
        [circle addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(itemTapped:)]];
        [self addSubview:circle];
        [_circles addObject:circle];

        BOOL isCenter = [self isCenterIndex:i];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:isCenter ? 22 : 19
                                                                                           weight:UIImageSymbolWeightSemibold];
        UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:_icons[i] withConfiguration:cfg]];
        iconView.contentMode = UIViewContentModeCenter;
        [circle addSubview:iconView];
        [_iconViews addObject:iconView];

        UILabel *label = [[UILabel alloc] init];
        label.text = _titles[i];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [MiOSTheme roundedFont:10 weight:UIFontWeightMedium];
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        [self addSubview:label];
        [_labels addObject:label];
    }
    [self applySelectionStyle];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applySelectionStyle)
                                                 name:MiOSThemeDidChangeNotification object:nil];
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (BOOL)isCenterIndex:(NSInteger)index { return index == (NSInteger)_titles.count / 2; }
- (CGFloat)verticalOffsetForIndex:(NSInteger)index {
    NSInteger count = (NSInteger)_titles.count;
    NSInteger center = count / 2;
    NSInteger distance = labs(index - center);
    if (distance == 0) return 0;
    return (distance % 2 == 1) ? 22 : 10;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    _fadeLayer.frame = self.bounds;
    NSInteger count = (NSInteger)_titles.count;
    if (count == 0) return;
    CGFloat columnWidth = (width - 16) / count;
    for (NSInteger i = 0; i < count; i++) {
        CGFloat size = [self isCenterIndex:i] ? kCenterItemSize : kItemSize;
        CGFloat centerX = 8 + columnWidth * (i + 0.5);
        CGFloat top = kTopPadding + [self verticalOffsetForIndex:i];
        UIView *circle = _circles[i];
        circle.frame = CGRectMake(centerX - size / 2, top, size, size);
        circle.layer.cornerRadius = size / 2;
        _iconViews[i].frame = circle.bounds;
        _labels[i].frame = CGRectMake(centerX - columnWidth / 2, CGRectGetMaxY(circle.frame) + 5, columnWidth, 13);
    }
    UIBezierPath *arc = [UIBezierPath bezierPath];
    CGFloat arcY = kTopPadding + kItemSize / 2 + 30;
    [arc moveToPoint:CGPointMake(-20, arcY)];
    [arc addQuadCurveToPoint:CGPointMake(width + 20, arcY) controlPoint:CGPointMake(width / 2, kTopPadding - 26)];
    _arcLayer.path = arc.CGPath;
}
- (void)setSelectedIndex:(NSInteger)selectedIndex { _selectedIndex = selectedIndex; [self applySelectionStyle]; }
- (void)applySelectionStyle {
    for (NSInteger i = 0; i < (NSInteger)_circles.count; i++) {
        BOOL selected = (i == _selectedIndex);
        UIView *circle = _circles[i];
        if (selected) {
            circle.backgroundColor = [UIColor whiteColor];
            circle.layer.borderColor = [UIColor whiteColor].CGColor;
            circle.layer.shadowColor = [UIColor whiteColor].CGColor;
            circle.layer.shadowOpacity = 0.35;
            circle.layer.shadowRadius = 12;
            circle.layer.shadowOffset = CGSizeZero;
            _iconViews[i].tintColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:1.0];
            _labels[i].textColor = [UIColor whiteColor];
            _labels[i].font = [MiOSTheme roundedFont:10 weight:UIFontWeightSemibold];
        } else {
            BOOL isCenter = [self isCenterIndex:i];
            UIColor *accent = [MiOSTheme accentColor];
            circle.backgroundColor = isCenter ? [accent colorWithAlphaComponent:0.95]
                                              : [UIColor colorWithRed:0.16 green:0.17 blue:0.24 alpha:0.92];
            circle.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:isCenter ? 0.30 : 0.10].CGColor;
            circle.layer.shadowOpacity = isCenter ? 0.45 : 0.0;
            circle.layer.shadowColor = accent.CGColor;
            circle.layer.shadowRadius = 14;
            circle.layer.shadowOffset = CGSizeZero;
            _iconViews[i].tintColor = isCenter ? [MiOSTheme textColorOnAccent] : [UIColor colorWithWhite:1.0 alpha:0.85];
            _labels[i].textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
            _labels[i].font = [MiOSTheme roundedFont:10 weight:UIFontWeightMedium];
        }
    }
}
- (void)itemTapped:(UITapGestureRecognizer *)sender {
    NSInteger index = sender.view.tag;
    UIView *circle = sender.view;
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
    [UIView animateWithDuration:0.08 animations:^{ circle.transform = CGAffineTransformMakeScale(0.9, 0.9); }
                     completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.5 initialSpringVelocity:0 options:0
                         animations:^{ circle.transform = CGAffineTransformIdentity; } completion:nil];
    }];
    self.selectedIndex = index;
    if (_onSelect) _onSelect(index);
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end

#pragma mark - MiOSColorExtractor

@implementation MiOSColorExtractor

+ (UIColor *)normalizedColorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b {
    CGFloat h, s, v, a;
    UIColor *c = [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    [c getHue:&h saturation:&s brightness:&v alpha:&a];
    s = fmin(fmax(s, 0.55), 0.95);
    v = fmin(fmax(v, 0.80), 1.0);
    return [UIColor colorWithHue:h saturation:s brightness:v alpha:1.0];
}

+ (NSArray<UIColor *> *)paletteFromImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return @[];
    enum { sampleSize = 24, binCount = 12 };
    unsigned char *raw = calloc(sampleSize * sampleSize * 4, 1);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(raw, sampleSize, sampleSize, 8, sampleSize * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) { free(raw); return @[]; }
    CGContextDrawImage(ctx, CGRectMake(0, 0, sampleSize, sampleSize), cgImage);
    CGContextRelease(ctx);

    CGFloat weight[binCount] = {0};
    CGFloat sumR[binCount] = {0}, sumG[binCount] = {0}, sumB[binCount] = {0};
    for (NSInteger i = 0; i < sampleSize * sampleSize; i++) {
        CGFloat a = raw[i * 4 + 3] / 255.0;
        if (a < 0.5) continue;
        CGFloat r = raw[i * 4] / 255.0 / a;
        CGFloat g = raw[i * 4 + 1] / 255.0 / a;
        CGFloat b = raw[i * 4 + 2] / 255.0 / a;
        CGFloat h, s, v, alpha;
        [[UIColor colorWithRed:fmin(r, 1) green:fmin(g, 1) blue:fmin(b, 1) alpha:1] getHue:&h saturation:&s brightness:&v alpha:&alpha];
        if (s < 0.25 || v < 0.2) continue;
        NSInteger bin = (NSInteger)floor(h * binCount) % binCount;
        CGFloat w = s * v;
        weight[bin] += w; sumR[bin] += r * w; sumG[bin] += g * w; sumB[bin] += b * w;
    }
    free(raw);

    NSInteger top = -1;
    for (NSInteger i = 0; i < binCount; i++)
        if (weight[i] > 0 && (top < 0 || weight[i] > weight[top])) top = i;
    if (top < 0) return @[];

    NSMutableArray<UIColor *> *palette = [NSMutableArray array];
    [palette addObject:[self normalizedColorWithRed:sumR[top] / weight[top]
                                              green:sumG[top] / weight[top]
                                               blue:sumB[top] / weight[top]]];
    NSInteger second = -1;
    for (NSInteger i = 0; i < binCount; i++) {
        NSInteger distance = labs(i - top);
        distance = MIN(distance, binCount - distance);
        if (distance < 2 || weight[i] < weight[top] * 0.15) continue;
        if (second < 0 || weight[i] > weight[second]) second = i;
    }
    if (second >= 0)
        [palette addObject:[self normalizedColorWithRed:sumR[second] / weight[second]
                                                  green:sumG[second] / weight[second]
                                                   blue:sumB[second] / weight[second]]];
    return palette;
}

+ (UIColor *)accentGradientEndFromColor:(UIColor *)color {
    if (!color) return [UIColor colorWithRed:0.45 green:0.30 blue:1.0 alpha:1.0];
    CGFloat hue, sat, bri, a;
    [color getHue:&hue saturation:&sat brightness:&bri alpha:&a];
    hue = fmod(hue + 0.08, 1.0);
    sat = fmin(sat * 1.2, 1.0);
    bri = fmax(bri * 0.7, 0.3);
    return [UIColor colorWithHue:hue saturation:sat brightness:bri alpha:1.0];
}

@end

#pragma mark - MiOSDeviceImageRenderer

typedef NS_ENUM(NSInteger, MiOSCameraLayout) {
    MiOSCameraSingle,
    MiOSCameraDualHorizontalPill,
    MiOSCameraDualVerticalPill,
    MiOSCameraDualSquareVertical,
    MiOSCameraDualSquareDiagonal,
    MiOSCameraTripleSquare,
    MiOSCameraPlateauSingle,
    MiOSCameraPlateauTriple,
};

static UIColor *MiOSAdjust(UIColor *c, CGFloat delta) {
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return [UIColor colorWithRed:fmin(fmax(r + delta, 0), 1) green:fmin(fmax(g + delta, 0), 1)
                            blue:fmin(fmax(b + delta, 0), 1) alpha:a];
}
static BOOL MiOSIsLight(UIColor *c) {
    CGFloat r, g, b, a;
    [c getRed:&r green:&g blue:&b alpha:&a];
    return (0.299 * r + 0.587 * g + 0.114 * b) > 0.55;
}
static void MiOSFillLinear(CGContextRef ctx, UIBezierPath *path, NSArray<UIColor *> *colors, CGPoint start, CGPoint end) {
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, NULL);
    CGContextSaveGState(ctx);
    [path addClip];
    CGContextDrawLinearGradient(ctx, gradient, start, end, kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGContextRestoreGState(ctx);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}
static void MiOSFillRadial(CGContextRef ctx, CGPoint center, CGFloat radius, UIColor *inner, UIColor *outer) {
    NSArray *cg = @[(id)inner.CGColor, (id)outer.CGColor];
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)cg, NULL);
    CGContextDrawRadialGradient(ctx, gradient, center, 0, center, radius, 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

@implementation MiOSDeviceImageRenderer

+ (MiOSDeviceFormFactor)formFactorForDeviceName:(NSString *)name {
    NSString *lower = name.lowercaseString ?: @"";
    if ([lower containsString:@"iphone se"] || [lower containsString:@"iphone 7"] || [lower containsString:@"iphone 8"])
        return MiOSDeviceFormFactorHomeButton;
    if ([lower containsString:@"16e"]) return MiOSDeviceFormFactorNotch;
    if ([lower containsString:@"14 pro"] || [lower containsString:@"iphone 15"] ||
        [lower containsString:@"iphone 16"] || [lower containsString:@"iphone 17"])
        return MiOSDeviceFormFactorDynamicIsland;
    return MiOSDeviceFormFactorNotch;
}

+ (MiOSCameraLayout)cameraLayoutForName:(NSString *)name {
    NSString *lower = name.lowercaseString ?: @"";
    BOOL pro = [lower containsString:@"pro"];
    if ([lower containsString:@"17 air"]) return MiOSCameraPlateauSingle;
    if ([lower containsString:@"17 pro"]) return MiOSCameraPlateauTriple;
    if (pro) return MiOSCameraTripleSquare;
    if ([lower containsString:@"16e"] || [lower containsString:@"xr"] || [lower containsString:@"iphone se"]) return MiOSCameraSingle;
    if ([lower containsString:@"iphone 7"] || [lower containsString:@"iphone 8"])
        return [lower containsString:@"plus"] ? MiOSCameraDualHorizontalPill : MiOSCameraSingle;
    if ([lower containsString:@"iphone x"] || [lower containsString:@"iphone 16"] || [lower containsString:@"iphone 17"])
        return MiOSCameraDualVerticalPill;
    if ([lower containsString:@"iphone 11"] || [lower containsString:@"iphone 12"]) return MiOSCameraDualSquareVertical;
    return MiOSCameraDualSquareDiagonal;
}

+ (UIColor *)finishForName:(NSString *)name {
    NSString *lower = name.lowercaseString ?: @"";
    NSUInteger hash = 0;
    for (NSUInteger i = 0; i < lower.length; i++) hash = hash * 31 + [lower characterAtIndex:i];
    if ([lower containsString:@"15 pro"] || [lower containsString:@"16 pro"] || [lower containsString:@"17 pro"])
        return [UIColor colorWithRed:0.74 green:0.72 blue:0.68 alpha:1.0];
    BOOL steelX = [lower containsString:@"iphone x"] && ![lower containsString:@"xr"];
    if ([lower containsString:@"pro"] || steelX) {
        NSArray *premium = @[
            [UIColor colorWithRed:0.30 green:0.31 blue:0.33 alpha:1.0],
            [UIColor colorWithRed:0.89 green:0.89 blue:0.87 alpha:1.0],
            [UIColor colorWithRed:0.91 green:0.85 blue:0.73 alpha:1.0],
            [UIColor colorWithRed:0.38 green:0.34 blue:0.44 alpha:1.0],
        ];
        return premium[hash % premium.count];
    }
    NSArray *colors = @[
        [UIColor colorWithRed:0.20 green:0.21 blue:0.23 alpha:1.0],
        [UIColor colorWithRed:0.93 green:0.93 blue:0.92 alpha:1.0],
        [UIColor colorWithRed:0.72 green:0.12 blue:0.18 alpha:1.0],
        [UIColor colorWithRed:0.38 green:0.55 blue:0.74 alpha:1.0],
        [UIColor colorWithRed:0.95 green:0.80 blue:0.84 alpha:1.0],
        [UIColor colorWithRed:0.63 green:0.78 blue:0.69 alpha:1.0],
        [UIColor colorWithRed:0.96 green:0.88 blue:0.60 alpha:1.0],
        [UIColor colorWithRed:0.75 green:0.71 blue:0.87 alpha:1.0],
    ];
    return colors[hash % colors.count];
}

+ (UIImage *)renderDeviceForName:(NSString *)displayName size:(CGSize)size accentColor:(UIColor *)accent {
    if (size.width < 1 || size.height < 1) return nil;
    if (!accent) accent = [UIColor colorWithRed:0.0 green:0.82 blue:0.95 alpha:1.0];
    MiOSDeviceFormFactor form = [self formFactorForDeviceName:displayName];
    MiOSCameraLayout camera = [self cameraLayoutForName:displayName];
    UIColor *finish = [self finishForName:displayName];

    CGFloat aspect = (form == MiOSDeviceFormFactorHomeButton) ? 0.50 : 0.485;
    CGFloat phoneHeight = size.height * 0.90;
    CGFloat phoneWidth = phoneHeight * aspect;
    const CGFloat spread = 1.70;
    if (phoneWidth * spread > size.width * 0.94) {
        phoneWidth = size.width * 0.94 / spread;
        phoneHeight = phoneWidth / aspect;
    }
    CGFloat originX = (size.width - phoneWidth * spread) / 2.0;
    CGFloat originY = (size.height - phoneHeight) / 2.0;
    CGRect backRect = CGRectMake(originX, originY - phoneHeight * 0.015, phoneWidth, phoneHeight);
    CGRect frontRect = CGRectMake(originX + phoneWidth * 0.70, originY + phoneHeight * 0.015, phoneWidth, phoneHeight);

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef ctx = rc.CGContext;
        [self drawBackInRect:backRect finish:finish camera:camera form:form context:ctx];
        [self drawFrontInRect:frontRect finish:finish accent:accent form:form context:ctx];
    }];
}

+ (void)drawBackInRect:(CGRect)r finish:(UIColor *)finish camera:(MiOSCameraLayout)camera
                  form:(MiOSDeviceFormFactor)form context:(CGContextRef)ctx {
    CGFloat pw = r.size.width;
    CGFloat radius = pw * (form == MiOSDeviceFormFactorHomeButton ? 0.16 : 0.19);
    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, pw * 0.05), pw * 0.14, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
    [MiOSAdjust(finish, -0.1) setFill];
    [body fill];
    CGContextRestoreGState(ctx);
    MiOSFillLinear(ctx, body, @[MiOSAdjust(finish, 0.08), finish, MiOSAdjust(finish, -0.10)],
                   CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r)), CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)));
    CGContextSaveGState(ctx);
    [body addClip];
    MiOSFillRadial(ctx, CGPointMake(CGRectGetMinX(r) + pw * 0.3, CGRectGetMinY(r) + pw * 0.4), pw * 1.1,
                   [UIColor colorWithWhite:1 alpha:0.16], [UIColor colorWithWhite:1 alpha:0]);
    CGContextRestoreGState(ctx);
    [MiOSAdjust(finish, -0.22) setStroke];
    body.lineWidth = MAX(pw * 0.022, 1.0);
    [body stroke];
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, pw * 0.02, pw * 0.02) cornerRadius:radius - pw * 0.02];
    [[UIColor colorWithWhite:1 alpha:0.22] setStroke];
    inner.lineWidth = 0.6;
    [inner stroke];
    [self drawCameraLayout:camera inRect:r finish:finish context:ctx];
    UIImage *logo = [UIImage systemImageNamed:@"apple.logo"];
    if (logo) {
        UIColor *tint = MiOSIsLight(finish) ? [MiOSAdjust(finish, -0.22) colorWithAlphaComponent:0.8]
                                            : [MiOSAdjust(finish, 0.20) colorWithAlphaComponent:0.8];
        logo = [logo imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
        CGFloat lw = pw * 0.22;
        CGFloat lh = lw * logo.size.height / MAX(logo.size.width, 1);
        [logo drawInRect:CGRectMake(CGRectGetMidX(r) - lw / 2, CGRectGetMinY(r) + r.size.height * 0.47 - lh / 2, lw, lh)];
    }
}

+ (void)drawLensAt:(CGPoint)c radius:(CGFloat)rad context:(CGContextRef)ctx {
    UIBezierPath *outer = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - rad, c.y - rad, rad * 2, rad * 2)];
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, rad * 0.15), rad * 0.4, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
    [[UIColor colorWithWhite:0.12 alpha:1] setFill];
    [outer fill];
    CGContextRestoreGState(ctx);
    [[UIColor colorWithWhite:0.62 alpha:0.9] setStroke];
    outer.lineWidth = MAX(rad * 0.14, 0.6);
    [outer stroke];
    CGFloat g = rad * 0.64;
    CGContextSaveGState(ctx);
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - g, c.y - g, g * 2, g * 2)] addClip];
    MiOSFillRadial(ctx, CGPointMake(c.x - g * 0.2, c.y - g * 0.2), g * 1.3,
                   [UIColor colorWithRed:0.20 green:0.24 blue:0.40 alpha:1], [UIColor colorWithRed:0.02 green:0.02 blue:0.05 alpha:1]);
    CGContextRestoreGState(ctx);
    CGFloat h = g * 0.32;
    [[UIColor colorWithWhite:1 alpha:0.65] setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - g * 0.45, c.y - g * 0.45, h, h)] fill];
}

+ (void)drawDotAt:(CGPoint)c radius:(CGFloat)rad color:(UIColor *)color {
    [color setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - rad, c.y - rad, rad * 2, rad * 2)] fill];
}

+ (void)drawBumpPath:(UIBezierPath *)bump finish:(UIColor *)finish context:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 3, [UIColor colorWithWhite:0 alpha:0.35].CGColor);
    [MiOSAdjust(finish, -0.06) setFill];
    [bump fill];
    CGContextRestoreGState(ctx);
    CGRect b = bump.bounds;
    MiOSFillLinear(ctx, bump, @[MiOSAdjust(finish, 0.06), MiOSAdjust(finish, -0.08)],
                   CGPointMake(CGRectGetMinX(b), CGRectGetMinY(b)), CGPointMake(CGRectGetMaxX(b), CGRectGetMaxY(b)));
    [[UIColor colorWithWhite:1 alpha:0.30] setStroke];
    bump.lineWidth = 0.7;
    [bump stroke];
}

+ (void)drawCameraLayout:(MiOSCameraLayout)layout inRect:(CGRect)r finish:(UIColor *)finish context:(CGContextRef)ctx {
    CGFloat pw = r.size.width;
    CGFloat m = pw * 0.07;
    CGFloat x = CGRectGetMinX(r) + m, y = CGRectGetMinY(r) + m;
    UIColor *flash = [UIColor colorWithRed:1.0 green:0.96 blue:0.85 alpha:0.95];
    UIColor *sensor = [UIColor colorWithWhite:0.08 alpha:1];
    switch (layout) {
        case MiOSCameraTripleSquare: {
            CGFloat s = pw * 0.46;
            [self drawBumpPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, s, s) cornerRadius:s * 0.28] finish:finish context:ctx];
            CGFloat lr = s * 0.2;
            [self drawLensAt:CGPointMake(x + s * 0.28, y + s * 0.27) radius:lr context:ctx];
            [self drawLensAt:CGPointMake(x + s * 0.28, y + s * 0.73) radius:lr context:ctx];
            [self drawLensAt:CGPointMake(x + s * 0.72, y + s * 0.50) radius:lr context:ctx];
            [self drawDotAt:CGPointMake(x + s * 0.74, y + s * 0.18) radius:s * 0.06 color:flash];
            [self drawDotAt:CGPointMake(x + s * 0.74, y + s * 0.82) radius:s * 0.06 color:sensor];
            break;
        }
        case MiOSCameraDualSquareDiagonal:
        case MiOSCameraDualSquareVertical: {
            CGFloat s = pw * 0.38;
            [self drawBumpPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, s, s) cornerRadius:s * 0.28] finish:finish context:ctx];
            CGFloat lr = s * 0.22;
            BOOL diagonal = (layout == MiOSCameraDualSquareDiagonal);
            [self drawLensAt:CGPointMake(x + s * 0.30, y + s * 0.30) radius:lr context:ctx];
            [self drawLensAt:CGPointMake(x + (diagonal ? s * 0.70 : s * 0.30), y + s * 0.70) radius:lr context:ctx];
            [self drawDotAt:CGPointMake(x + s * 0.74, y + s * (diagonal ? 0.26 : 0.30)) radius:s * 0.07 color:flash];
            break;
        }
        case MiOSCameraDualVerticalPill: {
            CGFloat w = pw * 0.18, h = pw * 0.38;
            [self drawBumpPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h) cornerRadius:w / 2] finish:finish context:ctx];
            CGFloat lr = w * 0.38;
            [self drawLensAt:CGPointMake(x + w / 2, y + w / 2) radius:lr context:ctx];
            [self drawLensAt:CGPointMake(x + w / 2, y + h - w / 2) radius:lr context:ctx];
            [self drawDotAt:CGPointMake(x + w + pw * 0.07, y + h / 2) radius:pw * 0.03 color:flash];
            break;
        }
        case MiOSCameraDualHorizontalPill: {
            CGFloat w = pw * 0.38, h = pw * 0.18;
            [self drawBumpPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h) cornerRadius:h / 2] finish:finish context:ctx];
            CGFloat lr = h * 0.38;
            [self drawLensAt:CGPointMake(x + h / 2, y + h / 2) radius:lr context:ctx];
            [self drawLensAt:CGPointMake(x + w - h / 2, y + h / 2) radius:lr context:ctx];
            [self drawDotAt:CGPointMake(x + w + pw * 0.07, y + h / 2) radius:pw * 0.03 color:flash];
            break;
        }
        case MiOSCameraPlateauSingle:
        case MiOSCameraPlateauTriple: {
            CGFloat w = pw * 0.94, h = pw * 0.30;
            CGFloat px = CGRectGetMinX(r) + (pw - w) / 2, py = CGRectGetMinY(r) + pw * 0.06;
            [self drawBumpPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(px, py, w, h) cornerRadius:h * 0.45] finish:finish context:ctx];
            if (layout == MiOSCameraPlateauTriple) {
                CGFloat lr = h * 0.2;
                [self drawLensAt:CGPointMake(px + h * 0.32, py + h * 0.30) radius:lr context:ctx];
                [self drawLensAt:CGPointMake(px + h * 0.32, py + h * 0.72) radius:lr context:ctx];
                [self drawLensAt:CGPointMake(px + h * 0.76, py + h * 0.51) radius:lr context:ctx];
            } else {
                [self drawLensAt:CGPointMake(px + h * 0.5, py + h * 0.5) radius:h * 0.28 context:ctx];
            }
            [self drawDotAt:CGPointMake(px + w - h * 0.4, py + h * 0.5) radius:h * 0.1 color:flash];
            break;
        }
        case MiOSCameraSingle:
        default: {
            CGFloat lr = pw * 0.085;
            CGPoint c = CGPointMake(x + lr * 1.2, y + lr * 1.2);
            [self drawBumpPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x - lr * 1.25, c.y - lr * 1.25, lr * 2.5, lr * 2.5)]
                        finish:finish context:ctx];
            [self drawLensAt:c radius:lr context:ctx];
            [self drawDotAt:CGPointMake(c.x + lr * 2.4, c.y) radius:pw * 0.03 color:flash];
            break;
        }
    }
}

+ (void)drawFrontInRect:(CGRect)r finish:(UIColor *)finish accent:(UIColor *)accent
                   form:(MiOSDeviceFormFactor)form context:(CGContextRef)ctx {
    CGFloat pw = r.size.width, ph = r.size.height;
    BOOL homeButton = (form == MiOSDeviceFormFactorHomeButton);
    CGFloat radius = pw * (homeButton ? 0.16 : 0.19);
    UIBezierPath *body = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
    [MiOSAdjust(finish, -0.08) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMaxX(r) - pw * 0.01, CGRectGetMinY(r) + ph * 0.24, pw * 0.03, ph * 0.11)
                                cornerRadius:pw * 0.01] fill];
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(-pw * 0.03, pw * 0.05), pw * 0.16, [UIColor colorWithWhite:0 alpha:0.6].CGColor);
    [finish setFill];
    [body fill];
    CGContextRestoreGState(ctx);
    MiOSFillLinear(ctx, body, @[MiOSAdjust(finish, 0.12), MiOSAdjust(finish, -0.12)],
                   CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r)), CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r)));
    CGFloat rim = pw * 0.022;
    UIBezierPath *face = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, rim, rim) cornerRadius:radius - rim];
    [[UIColor colorWithRed:0.03 green:0.03 blue:0.04 alpha:1] setFill];
    [face fill];
    CGRect screen; CGFloat screenRadius;
    if (homeButton) {
        screen = CGRectMake(CGRectGetMinX(r) + pw * 0.065, CGRectGetMinY(r) + ph * 0.125, pw * 0.87, ph * 0.75);
        screenRadius = pw * 0.015;
    } else {
        CGFloat inset = pw * 0.05;
        screen = CGRectInset(r, inset, inset);
        screenRadius = radius - inset;
    }
    UIBezierPath *screenPath = [UIBezierPath bezierPathWithRoundedRect:screen cornerRadius:screenRadius];
    CGContextSaveGState(ctx);
    [screenPath addClip];
    MiOSFillLinear(ctx, screenPath, @[[UIColor colorWithRed:0.12 green:0.11 blue:0.24 alpha:1],
                                      [UIColor colorWithRed:0.03 green:0.03 blue:0.08 alpha:1]],
                   CGPointMake(CGRectGetMidX(screen), CGRectGetMinY(screen)), CGPointMake(CGRectGetMidX(screen), CGRectGetMaxY(screen)));
    CGFloat h, s, v, a;
    [accent getHue:&h saturation:&s brightness:&v alpha:&a];
    UIColor *second = [UIColor colorWithHue:fmod(h + 0.12, 1.0) saturation:s brightness:v alpha:1];
    MiOSFillRadial(ctx, CGPointMake(CGRectGetMinX(screen) + screen.size.width * 0.25, CGRectGetMinY(screen) + screen.size.height * 0.72),
                   screen.size.width * 0.95, [accent colorWithAlphaComponent:0.95], [accent colorWithAlphaComponent:0.0]);
    MiOSFillRadial(ctx, CGPointMake(CGRectGetMinX(screen) + screen.size.width * 0.85, CGRectGetMinY(screen) + screen.size.height * 0.40),
                   screen.size.width * 0.75, [second colorWithAlphaComponent:0.75], [second colorWithAlphaComponent:0.0]);
    NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
    para.alignment = NSTextAlignmentCenter;
    CGFloat fontSize = pw * 0.17;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.92],
        NSParagraphStyleAttributeName: para,
    };
    [@"9:41" drawInRect:CGRectMake(CGRectGetMinX(screen), CGRectGetMinY(screen) + screen.size.height * 0.13,
                                   screen.size.width, fontSize * 1.3) withAttributes:attrs];
    UIBezierPath *glare = [UIBezierPath bezierPath];
    [glare moveToPoint:CGPointMake(CGRectGetMinX(screen), CGRectGetMinY(screen))];
    [glare addLineToPoint:CGPointMake(CGRectGetMinX(screen) + screen.size.width * 0.65, CGRectGetMinY(screen))];
    [glare addLineToPoint:CGPointMake(CGRectGetMinX(screen), CGRectGetMinY(screen) + screen.size.height * 0.55)];
    [glare closePath];
    [[UIColor colorWithWhite:1 alpha:0.07] setFill];
    [glare fill];
    CGContextRestoreGState(ctx);
    UIColor *black = [UIColor colorWithRed:0.01 green:0.01 blue:0.02 alpha:1];
    if (form == MiOSDeviceFormFactorDynamicIsland) {
        CGFloat w = pw * 0.30, ih = pw * 0.085;
        [black setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMidX(screen) - w / 2, CGRectGetMinY(screen) + pw * 0.04, w, ih)
                                    cornerRadius:ih / 2] fill];
    } else if (form == MiOSDeviceFormFactorNotch) {
        CGFloat w = pw * 0.46, nh = pw * 0.075;
        CGContextSaveGState(ctx);
        [screenPath addClip];
        [black setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMidX(screen) - w / 2, CGRectGetMinY(screen) - nh, w, nh * 2)
                                    cornerRadius:nh * 0.7] fill];
        CGContextRestoreGState(ctx);
    } else {
        CGFloat bottomBezelMid = (CGRectGetMaxY(screen) + CGRectGetMaxY(r)) / 2;
        CGFloat br = pw * 0.075;
        UIBezierPath *button = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(CGRectGetMidX(r) - br, bottomBezelMid - br, br * 2, br * 2)];
        [[UIColor colorWithWhite:0.06 alpha:1] setFill];
        [button fill];
        [MiOSAdjust(finish, 0.05) setStroke];
        button.lineWidth = MAX(pw * 0.012, 0.6);
        [button stroke];
        CGFloat topBezelMid = (CGRectGetMinY(r) + CGRectGetMinY(screen)) / 2;
        [[UIColor colorWithWhite:0.18 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMidX(r) - pw * 0.09, topBezelMid - pw * 0.012, pw * 0.18, pw * 0.024)
                                    cornerRadius:pw * 0.012] fill];
        [self drawDotAt:CGPointMake(CGRectGetMidX(r) - pw * 0.16, topBezelMid) radius:pw * 0.02 color:[UIColor colorWithWhite:0.15 alpha:1]];
    }
}

@end
