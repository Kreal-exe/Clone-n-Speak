#import "OVUI.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

NSNotificationName const OVLogBufferNotification = @"OVLogBuffer";

static NSColor *Dynamic(NSColor *light, NSColor *dark) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        return [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua ? dark : light;
    }];
}

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }

NSColor *OVCardColor(void) {
    static NSColor *c;
    if (!c) c = Dynamic([NSColor colorWithWhite:1 alpha:1], RGB(0.150, 0.156, 0.176));
    return c;
}
NSColor *OVWindowColor(void) {
    static NSColor *c;
    if (!c) c = Dynamic(RGB(0.953, 0.957, 0.972), RGB(0.090, 0.094, 0.110));
    return c;
}
NSColor *OVAccent(void) {
    static NSColor *c;
    if (!c) c = Dynamic(RGB(0.14, 0.42, 0.96), RGB(0.42, 0.64, 1.0));
    return c;
}
NSColor *OVGreen(void) { return NSColor.systemGreenColor; }

NSGradient *OVBrandGradient(void) {
    static NSGradient *g;
    if (!g) g = [[NSGradient alloc] initWithStartingColor:RGB(0.16, 0.50, 1.0) endingColor:RGB(0.43, 0.33, 0.95)];
    return g;
}

NSFont *OVRoundedFont(CGFloat size, NSFontWeight weight) {
    NSFont *f = [NSFont systemFontOfSize:size weight:weight];
    NSFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
    return (d ? [NSFont fontWithDescriptor:d size:size] : nil) ?: f;
}

NSTextField *OVLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text ?: @""];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color ?: NSColor.labelColor;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

NSTextField *OVWrapLabel(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text ?: @""];
    l.font = [NSFont systemFontOfSize:size];
    l.textColor = color ?: NSColor.secondaryLabelColor;
    l.selectable = NO;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

NSTextField *OVTitle(NSString *text) {
    NSTextField *l = OVLabel(text, 28, NSFontWeightBold, nil);
    l.font = OVRoundedFont(28, NSFontWeightBold);
    return l;
}
NSTextField *OVSectionTitle(NSString *text) {
    NSTextField *l = OVLabel(text, 15, NSFontWeightSemibold, nil);
    l.font = OVRoundedFont(15, NSFontWeightSemibold);
    return l;
}

NSTextField *OVField(NSString *placeholder) {
    NSTextField *f = [NSTextField textFieldWithString:@""];
    f.placeholderString = placeholder;
    f.font = [NSFont systemFontOfSize:13];
    f.bezelStyle = NSTextFieldRoundedBezel;
    [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return f;
}

NSButton *OVButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeLarge;
    return b;
}

/// Borderless button drawn as a gradient pill with a white title (and symbol).
@interface OVPillButton : NSButton
@end
@implementation OVPillButton
- (NSSize)intrinsicContentSize {
    CGFloat w = ceil([self.title sizeWithAttributes:@{NSFontAttributeName: self.font}].width) + 36 + (self.image ? 20 : 0);
    return NSMakeSize(w, 34);
}
- (void)setTitle:(NSString *)title { [super setTitle:title]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setImage:(NSImage *)image { [super setImage:image]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)enabled { [super setEnabled:enabled]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:b xRadius:10 yRadius:10];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.4);
    [OVBrandGradient() drawInBezierPath:pill angle:self.isFlipped ? 90 : -90];
    if (self.isHighlighted) { [[NSColor colorWithWhite:0 alpha:0.18] setFill]; [pill fill]; }
    NSDictionary *attrs = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize ts = [self.title sizeWithAttributes:attrs];
    NSImage *img = [self.image imageWithSymbolConfiguration:
                    [[NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightBold]
                     configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[NSColor.whiteColor]]]];
    CGFloat iw = img ? img.size.width + 7 : 0;
    CGFloat x = round((NSWidth(b) - ts.width - iw) / 2);
    if (img) [img drawInRect:NSMakeRect(x, round((NSHeight(b) - img.size.height) / 2), img.size.width, img.size.height)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.title drawAtPoint:NSMakePoint(x + iw, round((NSHeight(b) - ts.height) / 2) - (self.isFlipped ? 1 : -1)) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
}
@end

NSButton *OVPrimaryButton(NSString *title, id target, SEL action) {
    OVPillButton *b = [OVPillButton buttonWithTitle:title target:target action:action];
    b.bordered = NO;
    b.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    [b setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

#pragma mark - Avatar

@interface OVAvatar ()
@property (nonatomic, copy) NSString *initials;
@property (nonatomic) NSGradient *gradient;
@property CGFloat side;
@end

@implementation OVAvatar
+ (instancetype)avatarWithSize:(CGFloat)size {
    OVAvatar *a = [[OVAvatar alloc] initWithFrame:NSZeroRect];
    a.side = size;
    [a.widthAnchor constraintEqualToConstant:size].active = YES;
    [a.heightAnchor constraintEqualToConstant:size].active = YES;
    [a setName:nil];
    return a;
}
- (void)setName:(NSString *)name {
    if (!name) {
        self.initials = @"AI";
        self.gradient = OVBrandGradient();
    } else {
        NSMutableString *out = [NSMutableString string];
        for (NSString *w in [name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (w.length && out.length < 2) [out appendString:[w substringToIndex:[w rangeOfComposedCharacterSequenceAtIndex:0].length].uppercaseString];
        self.initials = out.length ? out : @"•";
        // a stable colour per name: the same voice looks the same everywhere
        NSUInteger h = 5381;
        for (NSUInteger i = 0; i < name.length; i++) h = h * 33 + [name characterAtIndex:i];
        CGFloat hue = (h % 360) / 360.0;
        self.gradient = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithHue:hue saturation:0.62 brightness:0.92 alpha:1]
                                                      endingColor:[NSColor colorWithHue:fmod(hue + 0.09, 1) saturation:0.72 brightness:0.74 alpha:1]];
    }
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)r {
    [self.gradient drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:self.bounds] angle:-60];
    NSDictionary *a = @{NSFontAttributeName: OVRoundedFont(self.side * 0.38, NSFontWeightBold), NSForegroundColorAttributeName: NSColor.whiteColor};
    NSSize s = [self.initials sizeWithAttributes:a];
    [self.initials drawAtPoint:NSMakePoint((NSWidth(self.bounds) - s.width) / 2, (NSHeight(self.bounds) - s.height) / 2) withAttributes:a];
}
@end

NSButton *OVIconButton(NSString *symbol, NSString *tooltip, id target, SEL action) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tooltip];
    NSButton *b = [NSButton buttonWithImage:img target:target action:action];
    b.bezelStyle = NSBezelStyleRegularSquare;
    b.bordered = NO;
    b.toolTip = tooltip;
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
    b.contentTintColor = NSColor.secondaryLabelColor;
    [b.widthAnchor constraintEqualToConstant:26].active = YES;
    [b.heightAnchor constraintEqualToConstant:26].active = YES;
    return b;
}

@interface OVDefaultsCheckbox : NSButton
@property (copy) NSString *key;
@end
@implementation OVDefaultsCheckbox
- (void)toggled:(id)s { [NSUserDefaults.standardUserDefaults setBool:self.state == NSControlStateValueOn forKey:self.key]; }
@end

NSButton *OVCheckbox(NSString *title, NSString *key) {
    OVDefaultsCheckbox *b = [OVDefaultsCheckbox checkboxWithTitle:title target:nil action:nil];
    b.key = key;
    b.target = b;
    b.action = @selector(toggled:);
    b.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

NSImageView *OVSymbol(NSString *name, CGFloat size, NSColor *tint) {
    NSImageView *v = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]];
    v.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium];
    v.contentTintColor = tint ?: NSColor.secondaryLabelColor;
    [v setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return v;
}

NSProgressIndicator *OVProgressBar(void) {
    NSProgressIndicator *p = [NSProgressIndicator new];
    p.style = NSProgressIndicatorStyleBar;
    p.indeterminate = NO;
    p.minValue = 0;
    p.maxValue = 1;
    p.controlSize = NSControlSizeSmall;
    return p;
}

NSProgressIndicator *OVSpinner(void) {
    NSProgressIndicator *p = [NSProgressIndicator new];
    p.style = NSProgressIndicatorStyleSpinning;
    p.controlSize = NSControlSizeSmall;
    p.displayedWhenStopped = NO;
    return p;
}

NSStackView *OVHStack(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeCenterY;
    s.distribution = NSStackViewDistributionFill;
    s.spacing = spacing;
    return s;
}

NSStackView *OVVStack(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = spacing;
    return s;
}

NSView *OVSpacer(void) {
    NSView *v = [NSView new];
    [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    return v;
}

@interface OVCardView : NSView
@end
@implementation OVCardView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    self.layer.backgroundColor = OVCardColor().CGColor;
    self.layer.borderColor = [NSColor.separatorColor colorWithAlphaComponent:0.5].CGColor;
}
@end

NSView *OVCard(NSView *content, CGFloat padding) {
    OVCardView *card = [OVCardView new];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 14;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.layer.borderWidth = 0.5;
    card.layer.shadowOpacity = 0.07;
    card.layer.shadowRadius = 10;
    card.layer.shadowOffset = CGSizeMake(0, -3);
    [card addSubview:content];
    OVPin(content, card, NSEdgeInsetsMake(padding, padding + 2, padding, padding + 2));
    return card;
}

void OVPin(NSView *view, NSView *container, NSEdgeInsets i) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:i.top],
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:i.left],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-i.right],
        [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-i.bottom],
    ]];
}

void OVFillWidth(NSArray<NSView *> *views, NSStackView *stack) {
    for (NSView *v in views) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-(stack.edgeInsets.left + stack.edgeInsets.right)].active = YES;
    }
}

@interface OVFlippedView : NSView
@end
@implementation OVFlippedView
- (BOOL)isFlipped { return YES; }
@end

NSScrollView *OVScrollPage(NSStackView *content) {
    NSScrollView *sv = [NSScrollView new];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;
    sv.automaticallyAdjustsContentInsets = NO;
    OVFlippedView *doc = [OVFlippedView new];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    sv.documentView = doc;
    [doc addSubview:content];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [doc.leadingAnchor constraintEqualToAnchor:sv.contentView.leadingAnchor],
        [doc.trailingAnchor constraintEqualToAnchor:sv.contentView.trailingAnchor],
        [doc.topAnchor constraintEqualToAnchor:sv.contentView.topAnchor],
        [content.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    ]];
    return sv;
}

#pragma mark - Slider row

@interface OVSliderRow ()
@property NSSlider *slider;
@property NSTextField *value;
@property NSString *key, *format;
@property BOOL integer;
@end

@implementation OVSliderRow
+ (instancetype)rowWithTitle:(NSString *)title hint:(NSString *)hint key:(NSString *)key
                         min:(double)min max:(double)max format:(NSString *)format integer:(BOOL)integer {
    OVSliderRow *r = [OVSliderRow new];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.alignment = NSLayoutAttributeCenterY;
    r.spacing = 12;
    r.key = key;
    r.format = format;
    r.integer = integer;

    NSTextField *t = OVLabel(title, 13, NSFontWeightMedium, nil);
    NSStackView *left = OVVStack(hint ? @[t, OVWrapLabel(hint, 11, nil)] : @[t], 2);
    [left.widthAnchor constraintEqualToConstant:210].active = YES;

    r.slider = [NSSlider sliderWithValue:[NSUserDefaults.standardUserDefaults doubleForKey:key]
                                minValue:min maxValue:max target:r action:@selector(moved:)];
    r.slider.continuous = YES;
    [r.slider.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    r.value = OVLabel(@"", 13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    r.value.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    r.value.alignment = NSTextAlignmentRight;
    [r.value.widthAnchor constraintEqualToConstant:52].active = YES;
    [r setViews:@[left, r.slider, r.value] inGravity:NSStackViewGravityLeading];
    [r refresh];
    return r;
}
- (void)moved:(NSSlider *)s {
    double v = self.integer ? round(s.doubleValue) : round(s.doubleValue * 100) / 100;
    [NSUserDefaults.standardUserDefaults setDouble:v forKey:self.key];
    self.value.stringValue = [NSString stringWithFormat:self.format, v];
}
- (void)refresh {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:self.key];
    self.slider.doubleValue = v;
    self.value.stringValue = [NSString stringWithFormat:self.format, v];
}
@end

#pragma mark - Popup

@interface OVPopupBinder : NSObject
@property NSString *key;
@property NSArray *values;
@property (weak) id target;
@property SEL action;
@end
@implementation OVPopupBinder
- (void)picked:(NSPopUpButton *)p {
    [NSUserDefaults.standardUserDefaults setObject:self.values[p.indexOfSelectedItem] forKey:self.key];
    if (self.target && self.action) [NSApp sendAction:self.action to:self.target from:p];
}
@end

NSPopUpButton *OVDefaultsPopup(NSArray<NSArray<NSString *> *> *items, NSString *key, id target, SEL action) {
    NSPopUpButton *p = [NSPopUpButton new];
    OVPopupBinder *b = [OVPopupBinder new];
    b.key = key;
    b.target = target;
    b.action = action;
    NSMutableArray *vals = [NSMutableArray array];
    NSString *cur = [NSUserDefaults.standardUserDefaults stringForKey:key] ?: @"";
    for (NSArray *it in items) {
        [p addItemWithTitle:it[0]];
        [vals addObject:it[1]];
        if ([it[1] isEqualToString:cur]) [p selectItemAtIndex:p.numberOfItems - 1];
    }
    b.values = vals;
    p.target = b;
    p.action = @selector(picked:);
    objc_setAssociatedObject(p, "binder", b, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return p;
}

#pragma mark - Log buffer

static NSMutableString *gLog;

NSString *OVLogText(void) { return gLog ?: @""; }

void OVLogAppend(NSString *line) {
    if (!gLog) gLog = [NSMutableString string];
    [gLog appendString:line];
    [gLog appendString:@"\n"];
    if (gLog.length > 400000) [gLog deleteCharactersInRange:NSMakeRange(0, gLog.length - 300000)];
    [NSNotificationCenter.defaultCenter postNotificationName:OVLogBufferNotification object:nil userInfo:@{@"line": line}];
}
