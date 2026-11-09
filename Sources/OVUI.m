#import "OVUI.h"
#import "OVTheme.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

NSNotificationName const OVLogBufferNotification = @"OVLogBuffer";

static NSColor *RGB(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }

NSColor *OVCardColor(void) { return OVColor(OVRoleSurface); }
NSColor *OVWindowColor(void) { return OVColor(OVRoleBackground); }
NSColor *OVAccent(void) { return OVColor(OVRoleAccent); }
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
    l.textColor = color ?: OVColor(OVRoleText);
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

NSTextField *OVWrapLabel(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text ?: @""];
    l.font = [NSFont systemFontOfSize:size];
    l.textColor = color ?: OVColor(OVRoleMuted);
    l.selectable = NO;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

NSTextField *OVTitle(NSString *text) {
    NSTextField *l = OVLabel(text, 28, NSFontWeightBold, nil);
    // tracking -0.025em
    l.attributedStringValue = [[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:28 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: OVColor(OVRoleText), NSKernAttributeName: @(-0.7)}];
    return l;
}
NSTextField *OVSectionTitle(NSString *text) {
    return OVLabel(text, 18.5, NSFontWeightBold, nil);
}

#pragma mark - Text field

@interface OVFieldCell : NSTextFieldCell
@end
@implementation OVFieldCell
- (NSRect)drawingRectForBounds:(NSRect)r {
    NSRect d = [super drawingRectForBounds:r];
    d.origin.x += 12;
    d.size.width -= 24;
    CGFloat h = ceil(self.font.ascender - self.font.descender) + 2;   // center the line vertically
    if (NSHeight(r) > h) { d.origin.y = NSMinY(r) + floor((NSHeight(r) - h) / 2); d.size.height = h; }
    return d;
}
- (void)selectWithFrame:(NSRect)r inView:(NSView *)v editor:(NSText *)t delegate:(id)d start:(NSInteger)s length:(NSInteger)l {
    [super selectWithFrame:[self drawingRectForBounds:r] inView:v editor:t delegate:d start:s length:l];
}
- (void)editWithFrame:(NSRect)r inView:(NSView *)v editor:(NSText *)t delegate:(id)d event:(NSEvent *)e {
    [super editWithFrame:[self drawingRectForBounds:r] inView:v editor:t delegate:d event:e];
}
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)v {
    BOOL focus = [(NSControl *)v currentEditor] != nil && v.window.firstResponder == [(NSControl *)v currentEditor];
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(frame, 0.5, 0.5) xRadius:10 yRadius:10];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.6);
    [OVColor(OVRoleField) setFill];
    [p fill];
    [(focus ? OVColor(OVRoleFocus) : OVColor(OVRoleBorder)) setStroke];
    p.lineWidth = focus ? 2 : 1;
    [p stroke];
    [NSGraphicsContext restoreGraphicsState];
    [self drawInteriorWithFrame:frame inView:v];
}
@end

@interface OVFieldText : NSTextField
@end
@implementation OVFieldText
+ (Class)cellClass { return OVFieldCell.class; }
- (NSSize)intrinsicContentSize { NSSize s = [super intrinsicContentSize]; s.height = 34; return s; }
- (BOOL)becomeFirstResponder {
    BOOL r = [super becomeFirstResponder];
    self.needsDisplay = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ self.needsDisplay = YES; });
    return r;
}
- (void)textDidEndEditing:(NSNotification *)n { [super textDidEndEditing:n]; self.needsDisplay = YES; }
@end

NSTextField *OVField(NSString *placeholder) {
    OVFieldText *f = [[OVFieldText alloc] initWithFrame:NSZeroRect];
    f.placeholderString = placeholder;
    f.font = [NSFont systemFontOfSize:13];
    f.textColor = OVColor(OVRoleText);
    f.bezeled = NO;
    f.bordered = NO;
    f.drawsBackground = NO;
    f.focusRingType = NSFocusRingTypeNone;
    f.editable = YES;
    f.selectable = YES;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    f.usesSingleLineMode = YES;
    [f setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return f;
}

NSButton *OVButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.controlSize = NSControlSizeLarge;
    return b;
}

NSButton *OVPrimaryButton(NSString *title, id target, SEL action) {
    return OVPillButtonMake(title, nil, target, action, NO);
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
    b.contentTintColor = OVColor(OVRoleMuted);
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

/// Checkbox drawn by hand: 18 pt square, GhostBorder frame, on = CTA fill with a checkmark. Space (native) and Return toggle it.
@interface OVCheckButton : NSButton
@property (copy, nullable) NSString *key;
@end
@implementation OVCheckButton
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self setButtonType:NSButtonTypeSwitch];
        self.bordered = NO;
        self.focusRingType = NSFocusRingTypeDefault;
        self.font = [NSFont systemFontOfSize:14];
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    CGFloat w = 18 + (self.title.length ? 8 + ceil([self.title sizeWithAttributes:@{NSFontAttributeName: self.font}].width) : 0);
    return NSMakeSize(w, 22);
}
- (void)setTitle:(NSString *)t { [super setTitle:t]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setState:(NSControlStateValue)s { [super setState:s]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
- (NSRect)boxRect { return NSMakeRect(0, round((NSHeight(self.bounds) - 18) / 2), 18, 18); }
- (NSRect)focusRingMaskBounds { return [self boxRect]; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:[self boxRect] xRadius:5 yRadius:5] fill]; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 36 || e.keyCode == 76) [self performClick:nil]; else [super keyDown:e];
}
- (void)drawRect:(NSRect)dirty {
    BOOL on = self.state == NSControlStateValueOn;
    NSRect box = [self boxRect];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.5, 0.5) xRadius:5 yRadius:5];
    if (on) { [OVColor(OVRoleCTA) setFill]; [p fill]; }
    else if (self.isHighlighted) { [OVColorAlpha(OVRoleText, 0.08) setFill]; [p fill]; }
    [(on ? OVColor(OVRoleCTA) : OVColor(OVRoleGhostBorder)) setStroke];
    p.lineWidth = 1;
    [p stroke];
    if (on) {
        NSBezierPath *tick = [NSBezierPath bezierPath];
        CGFloat fy = self.isFlipped ? -1 : 1, y0 = self.isFlipped ? NSMaxY(box) : NSMinY(box);   // y measured from the bottom of the box
        [tick moveToPoint:NSMakePoint(NSMinX(box) + 4.5, y0 + fy * 9.5)];
        [tick lineToPoint:NSMakePoint(NSMinX(box) + 7.7, y0 + fy * 6.2)];
        [tick lineToPoint:NSMakePoint(NSMinX(box) + 13.5, y0 + fy * 12.4)];
        tick.lineWidth = 2;
        tick.lineCapStyle = NSLineCapStyleRound;
        tick.lineJoinStyle = NSLineJoinStyleRound;
        [OVColor(OVRoleCTAText) setStroke];
        [tick stroke];
    }
    if (self.title.length) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *a = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: OVColor(OVRoleText), NSParagraphStyleAttributeName: ps};
        CGFloat th = ceil([self.title sizeWithAttributes:a].height);
        [self.title drawInRect:NSMakeRect(26, round((NSHeight(self.bounds) - th) / 2), MAX(0, NSWidth(self.bounds) - 26), th) withAttributes:a];
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityCheckBoxRole; }
- (NSString *)accessibilityLabel { return super.accessibilityLabel ?: self.title; }
- (id)accessibilityValue { return @(self.state == NSControlStateValueOn); }
- (BOOL)accessibilityPerformPress { [self performClick:nil]; return YES; }
- (void)toggled:(id)s {
    if (self.key.length) [NSUserDefaults.standardUserDefaults setBool:self.state == NSControlStateValueOn forKey:self.key];
}
@end

NSButton *OVCheckbox(NSString *title, NSString *key) {
    OVCheckButton *b = [[OVCheckButton alloc] initWithFrame:NSZeroRect];
    b.title = title;
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

/// Flat bar: the track is a field-coloured capsule, the fill is Text-coloured. Indeterminate draws a segment that runs back and forth
/// (still, in the middle, under Reduce Motion).
@interface OVFlatProgress : NSProgressIndicator
@property BOOL running;
@property CGFloat phase;
@property (nonatomic, strong, nullable) NSTimer *timer;
@end
@implementation OVFlatProgress
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 6); }
- (void)dealloc { [_timer invalidate]; }
- (BOOL)isFlipped { return YES; }
- (void)syncTimer {
    BOOL still = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    BOOL need = self.running && self.indeterminate && self.window && !self.hiddenOrHasHiddenAncestor && !still;
    if (need && !self.timer) {
        __weak OVFlatProgress *w = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
            OVFlatProgress *s = w;
            if (!s) { [t invalidate]; return; }
            s.phase = fmod(s.phase + 1.0 / 60, 1);
            s.needsDisplay = YES;
        }];
    } else if (!need && self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
}
- (void)startAnimation:(id)sender { self.running = YES; [self syncTimer]; self.needsDisplay = YES; }
- (void)stopAnimation:(id)sender { self.running = NO; [self syncTimer]; self.needsDisplay = YES; }
- (void)setIndeterminate:(BOOL)i { [super setIndeterminate:i]; [self syncTimer]; self.needsDisplay = YES; }
- (void)setDoubleValue:(double)v { [super setDoubleValue:v]; self.needsDisplay = YES; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self syncTimer]; }
- (void)viewDidHide { [super viewDidHide]; [self syncTimer]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self syncTimer]; }
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSRect track = NSMakeRect(NSMinX(b), round(NSMidY(b) - 3), NSWidth(b), 6);
    NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3];
    [OVColor(OVRoleField) setFill];
    [t fill];
    NSRect fill = NSZeroRect;
    if (self.indeterminate) {
        if (!self.running) return;
        CGFloat w = NSWidth(track) * 0.3;
        BOOL still = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        CGFloat u = still ? 0.5 : (self.phase < 0.5 ? self.phase * 2 : (1 - self.phase) * 2);   // 0…1…0
        fill = NSMakeRect(NSMinX(track) + u * (NSWidth(track) - w), NSMinY(track), w, 6);
    } else {
        double span = self.maxValue - self.minValue;
        double f = span > 0 ? MIN(1, MAX(0, (self.doubleValue - self.minValue) / span)) : 0;
        fill = NSMakeRect(NSMinX(track), NSMinY(track), NSWidth(track) * f, 6);
    }
    if (NSWidth(fill) <= 0) return;
    [NSGraphicsContext saveGraphicsState];
    [t addClip];
    [OVColor(OVRoleText) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:3 yRadius:3] fill];
    [NSGraphicsContext restoreGraphicsState];
}
@end

NSProgressIndicator *OVProgressBar(void) {
    OVFlatProgress *p = [[OVFlatProgress alloc] initWithFrame:NSZeroRect];
    p.style = NSProgressIndicatorStyleBar;
    p.indeterminate = NO;
    p.minValue = 0;
    p.maxValue = 1;
    p.displayedWhenStopped = YES;
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

NSView *OVCard(NSView *content, CGFloat padding) {
    OVBoxView *card = [OVBoxView boxWithFill:OVColor(OVRoleSurface) border:OVColor(OVRoleBorder) radius:12];
    [card addSubview:content];
    OVPin(content, card, NSEdgeInsetsMake(padding, padding, padding, padding));
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
@property NSView *valuePill;
@property NSTextField *value, *titleLabel, *hintLabel;
@property NSString *key, *format;
@property BOOL integer;
@property NSArray<NSLayoutConstraint *> *fillConstraints;
@end

@implementation OVSliderRow
+ (instancetype)rowWithTitle:(NSString *)title hint:(NSString *)hint key:(NSString *)key
                         min:(double)min max:(double)max format:(NSString *)format integer:(BOOL)integer {
    OVSliderRow *r = [OVSliderRow new];
    r.key = key;
    r.format = format;
    r.integer = integer;

    r.titleLabel = OVLabel(title, 14, NSFontWeightSemibold, nil);
    r.hintLabel = hint.length ? OVWrapLabel(hint, 13, nil) : nil;
    r.slider = [OVSlider sliderWithValue:[NSUserDefaults.standardUserDefaults doubleForKey:key]
                                minValue:min maxValue:max target:r action:@selector(moved:)];
    r.slider.continuous = YES;
    r.slider.accessibilityLabel = title;
    r.value = OVLabel(@"", 13, NSFontWeightMedium, nil);
    r.value.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium];
    r.value.alignment = NSTextAlignmentCenter;
    r.value.accessibilityElement = NO;
    OVBoxView *pill = [OVBoxView boxWithFill:OVColor(OVRoleField) border:OVColor(OVRoleBorder) radius:8];
    [pill addSubview:r.value];
    OVPin(r.value, pill, NSEdgeInsetsMake(4, 8, 4, 8));
    [pill.widthAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
    [pill setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    r.valuePill = pill;
    [r rebuild];
    [r refresh];
    return r;
}

/// Lays the pieces out for the current `compact` value.
- (void)rebuild {
    [NSLayoutConstraint deactivateConstraints:self.fillConstraints ?: @[]];
    for (NSView *v in self.arrangedSubviews) { [self removeArrangedSubview:v]; [v removeFromSuperview]; }
    NSMutableArray *fills = [NSMutableArray array];
    if (self.compact) {
        self.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        self.alignment = NSLayoutAttributeCenterY;
        self.spacing = 12;
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [fills addObject:[self.titleLabel.widthAnchor constraintEqualToConstant:82]];
        for (NSView *v in @[self.titleLabel, self.slider, self.valuePill]) [self addArrangedSubview:v];
        [self.slider setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
        [fills addObject:[self.slider.widthAnchor constraintGreaterThanOrEqualToConstant:110]];
    } else {
        self.orientation = NSUserInterfaceLayoutOrientationVertical;
        self.alignment = NSLayoutAttributeLeading;
        self.spacing = 6;
        NSStackView *top = OVHStack(@[self.titleLabel, OVSpacer(), self.valuePill], 8);
        NSMutableArray *rows = [NSMutableArray arrayWithObjects:top, self.slider, nil];
        if (self.hintLabel) [rows addObject:self.hintLabel];
        for (NSView *v in rows) {
            [self addArrangedSubview:v];
            v.translatesAutoresizingMaskIntoConstraints = NO;
            [fills addObject:[v.widthAnchor constraintEqualToAnchor:self.widthAnchor]];
        }
    }
    self.fillConstraints = fills;
    [NSLayoutConstraint activateConstraints:fills];
}
- (void)setCompact:(BOOL)c {
    if (c == _compact) return;
    _compact = c;
    [self rebuild];
}
- (void)moved:(NSSlider *)s {
    double v = s.doubleValue;
    if (self.step > 0) v = round((v - s.minValue) / self.step) * self.step + s.minValue;
    else v = self.integer ? round(v) : round(v * 100) / 100;
    v = MIN(s.maxValue, MAX(s.minValue, v));
    s.doubleValue = v;
    [NSUserDefaults.standardUserDefaults setDouble:v forKey:self.key];
    [self showValue:v];
    if (self.onChange) self.onChange();
}
- (void)showValue:(double)v {
    NSString *t = self.valueFormatter ? self.valueFormatter(v) : [NSString stringWithFormat:self.format, v];
    self.value.stringValue = t;
    self.slider.accessibilityValueDescription = t;
}
- (BOOL)enabled { return self.slider.enabled; }
- (void)setEnabled:(BOOL)e {
    self.slider.enabled = e;
    self.value.alphaValue = e ? 1 : 0.5;
    self.titleLabel.alphaValue = e ? 1 : 0.6;
}
- (void)refresh {
    double v = [NSUserDefaults.standardUserDefaults doubleForKey:self.key];
    self.slider.doubleValue = v;
    [self showValue:v];
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

OVPopup *OVDefaultsPopup(NSArray<NSArray<NSString *> *> *items, NSString *key, id target, SEL action) {
    OVPopup *p = [OVPopup popup];
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
