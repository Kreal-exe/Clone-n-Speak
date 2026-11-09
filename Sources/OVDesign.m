#import "OVDesign.h"
#import "OVLocale.h"
#import "OVStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Helpers

static NSColor *C(OVRole r) { return OVColor(r); }
static BOOL ReduceMotion(void) { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }

/// `img` painted in `color` (resolved when the image is drawn, in the drawing view's appearance).
static NSImage *Tinted(NSImage *img, NSColor *color) {
    if (!img) return nil;
    return [NSImage imageWithSize:img.size flipped:NO drawingHandler:^BOOL(NSRect r) {
        [img drawInRect:r];
        [color set];
        NSRectFillUsingOperation(r, NSCompositingOperationSourceIn);
        return YES;
    }];
}

static NSImage *Glyph(NSString *symbol, CGFloat size, NSFontWeight weight) {
    NSImage *i = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    return [i imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:size weight:weight]] ?: i;
}

static void FixSize(NSView *v, CGFloat w, CGFloat h) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.widthAnchor constraintEqualToConstant:w].active = YES;
    [v.heightAnchor constraintEqualToConstant:h].active = YES;
}

static void Center(NSView *child, NSView *parent) {
    child.translatesAutoresizingMaskIntoConstraints = NO;
    [child.centerXAnchor constraintEqualToAnchor:parent.centerXAnchor].active = YES;
    [child.centerYAnchor constraintEqualToAnchor:parent.centerYAnchor].active = YES;
}

#pragma mark - Box

@implementation OVBoxView
+ (instancetype)boxWithFill:(NSColor *)fill border:(NSColor *)border radius:(CGFloat)radius {
    OVBoxView *b = [[self alloc] initWithFrame:NSZeroRect];
    b.fillColor = fill;
    b.borderColor = border;
    b.radius = radius;
    return b;
}
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) { _borderWidth = 1; self.wantsLayer = YES; }
    return self;
}
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:OVThemeDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { OVRepaintAll(); }];
}
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    CALayer *l = self.layer;
    l.cornerRadius = self.radius;
    l.cornerCurve = kCACornerCurveContinuous;
    l.backgroundColor = self.fillColor.CGColor;
    l.borderWidth = self.borderColor ? self.borderWidth : 0;
    l.borderColor = self.borderColor.CGColor;
}
- (void)setFillColor:(NSColor *)c { _fillColor = c; self.needsDisplay = YES; }
- (void)setBorderColor:(NSColor *)c { _borderColor = c; self.needsDisplay = YES; }
- (void)setRadius:(CGFloat)r { _radius = r; self.needsDisplay = YES; }
@end

#pragma mark - Pill button (CTA / ghost)

@interface OVPillButton : NSButton
@property BOOL ghost, hovered;
@end
@implementation OVPillButton
- (NSSize)intrinsicContentSize {
    CGFloat w = ceil([self.title sizeWithAttributes:@{NSFontAttributeName: self.font}].width) + 36 + (self.image ? 21 : 0);
    return NSMakeSize(w, 36);
}
- (void)setTitle:(NSString *)t { [super setTitle:t]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setImage:(NSImage *)i { [super setImage:i]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; self.needsDisplay = YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill]; }
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    NSColor *fg = self.ghost ? C(OVRoleText) : C(OVRoleCTAText);
    NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 0.5, 0.5) xRadius:10 yRadius:10];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.4);
    if (self.ghost) {
        if (self.isHighlighted || self.hovered) { [[C(OVRoleText) colorWithAlphaComponent:self.isHighlighted ? 0.12 : 0.07] setFill]; [pill fill]; }
        [C(OVRoleGhostBorder) setStroke];
        pill.lineWidth = 1;
        [pill stroke];
    } else {
        [C(OVRoleCTA) setFill];
        [pill fill];
        if (self.isHighlighted) { [[C(OVRoleCTAText) colorWithAlphaComponent:0.18] setFill]; [pill fill]; }
        else if (self.hovered) { [[C(OVRoleCTAText) colorWithAlphaComponent:0.08] setFill]; [pill fill]; }
    }
    NSDictionary *attrs = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: fg};
    NSSize ts = [self.title sizeWithAttributes:attrs];
    NSImage *img = self.image ? Tinted([self.image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightSemibold]], fg) : nil;
    CGFloat iw = img ? img.size.width + 7 : 0;
    CGFloat x = round((NSWidth(b) - ts.width - iw) / 2);
    if (img) [img drawInRect:NSMakeRect(x, round((NSHeight(b) - img.size.height) / 2), img.size.width, img.size.height)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [self.title drawAtPoint:NSMakePoint(x + iw, round((NSHeight(b) - ts.height) / 2) - (self.isFlipped ? 1 : -1)) withAttributes:attrs];
    [NSGraphicsContext restoreGraphicsState];
}
@end

NSButton *OVPillButtonMake(NSString *title, NSString *symbol, id target, SEL action, BOOL ghost) {
    OVPillButton *b = [OVPillButton buttonWithTitle:title target:target action:action];
    b.bordered = NO;
    b.ghost = ghost;
    b.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    if (symbol.length) b.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    [b setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

NSButton *OVGhostButton(NSString *title, NSString *symbol, id target, SEL action) {
    return OVPillButtonMake(title, symbol, target, action, YES);
}

#pragma mark - Card header, step card

NSView *OVCardHeader(NSInteger step, NSString *symbol, NSString *title, NSView *accessory) {
    NSMutableArray *views = [NSMutableArray array];
    if (step > 0) {
        OVBoxView *n = [OVBoxView boxWithFill:C(OVRoleAccentSoft) border:nil radius:7.5];
        FixSize(n, 23, 23);
        NSTextField *num = OVLabel([NSString stringWithFormat:@"%ld", (long)step], 12, NSFontWeightSemibold, C(OVRoleAccent));
        [n addSubview:num];
        Center(num, n);
        [views addObject:n];
    }
    if (symbol.length) [views addObject:OVSymbol(symbol, 17, C(OVRoleText))];
    [views addObject:OVSectionTitle(title)];
    [views addObject:OVSpacer()];
    if (accessory) [views addObject:accessory];
    NSStackView *h = OVHStack(views, 10);
    return h;
}

NSView *OVStepCard(NSInteger step, NSString *symbol, NSString *title, NSString *subtitle, NSView *content) {
    NSView *header = OVCardHeader(step, symbol, title, nil);
    NSMutableArray *rows = [NSMutableArray arrayWithObject:header];
    if (subtitle.length) [rows addObject:OVWrapLabel(subtitle, 13, nil)];
    [rows addObject:content];
    NSStackView *s = OVVStack(rows, 12);
    OVFillWidth(rows, s);
    return OVCard(s, 20);
}

#pragma mark - Disclosure

@class OVDisclosure;
@interface OVDisclosureHeader : NSControl
@property (weak) OVDisclosure *owner;
@end

@interface OVDisclosure ()
@property OVDisclosureHeader *header;
@property NSView *clip, *content;
@property NSLayoutConstraint *heightC, *bottomPin;
@property NSImageView *chevron;
@property (copy) NSString *titleText;
@property NSTextField *subtitleLabel;
@end

@implementation OVDisclosureHeader
- (BOOL)acceptsFirstResponder { return YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill]; }
- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; [self sendAction:self.action to:self.target]; }
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@" "] || [c isEqualToString:@"\r"]) [self sendAction:self.action to:self.target]; else [super keyDown:e];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSArray *)accessibilityChildren { return @[]; }
- (BOOL)accessibilityPerformPress { [self sendAction:self.action to:self.target]; return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityDisclosureTriangleRole; }
- (id)accessibilityValue { return @(self.owner.expanded); }
@end

@implementation OVDisclosure {
    BOOL _expanded;
}
+ (instancetype)disclosureWithTitle:(NSString *)t subtitle:(NSString *)s symbol:(NSString *)sym content:(NSView *)c {
    OVDisclosure *d = [[OVDisclosure alloc] initWithFrame:NSZeroRect];
    d.titleText = t;
    d.content = c;

    d.header = [OVDisclosureHeader new];
    d.header.owner = d;
    d.header.target = d;
    d.header.action = @selector(toggle:);
    d.header.accessibilityLabel = t;
    d.header.accessibilityHelp = s;
    d.chevron = OVSymbol(@"chevron.right", 12, C(OVRoleMuted));
    [d.chevron.widthAnchor constraintEqualToConstant:14].active = YES;
    NSMutableArray *row = [NSMutableArray arrayWithObject:d.chevron];
    if (sym.length) [row addObject:OVSymbol(sym, 15, C(OVRoleText))];
    NSTextField *title = OVLabel(t, 14, NSFontWeightSemibold, C(OVRoleText));
    d.subtitleLabel = OVLabel(s ?: @"", 12, NSFontWeightRegular, C(OVRoleMuted));
    d.subtitleLabel.hidden = !s.length;
    NSArray *texts = @[title, d.subtitleLabel];
    [row addObject:OVVStack(texts, 1)];
    [row addObject:OVSpacer()];
    NSStackView *line = OVHStack(row, 8);
    for (NSView *v in row) v.accessibilityElement = NO;
    for (NSView *v in texts) v.accessibilityElement = NO;
    [d.header addSubview:line];
    OVPin(line, d.header, NSEdgeInsetsMake(6, 0, 6, 0));

    d.clip = [NSView new];
    d.clip.wantsLayer = YES;
    d.clip.layer.masksToBounds = YES;
    d.clip.hidden = YES;
    [d.clip addSubview:c];
    c.translatesAutoresizingMaskIntoConstraints = NO;
    d.header.translatesAutoresizingMaskIntoConstraints = NO;
    d.clip.translatesAutoresizingMaskIntoConstraints = NO;
    [d addSubview:d.header];
    [d addSubview:d.clip];
    d.heightC = [d.clip.heightAnchor constraintEqualToConstant:0];
    d.bottomPin = [c.bottomAnchor constraintEqualToAnchor:d.clip.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [d.header.topAnchor constraintEqualToAnchor:d.topAnchor],
        [d.header.leadingAnchor constraintEqualToAnchor:d.leadingAnchor],
        [d.header.trailingAnchor constraintEqualToAnchor:d.trailingAnchor],
        [d.clip.topAnchor constraintEqualToAnchor:d.header.bottomAnchor],
        [d.clip.leadingAnchor constraintEqualToAnchor:d.leadingAnchor],
        [d.clip.trailingAnchor constraintEqualToAnchor:d.trailingAnchor],
        [d.clip.bottomAnchor constraintEqualToAnchor:d.bottomAnchor],
        [c.topAnchor constraintEqualToAnchor:d.clip.topAnchor constant:8],
        [c.leadingAnchor constraintEqualToAnchor:d.clip.leadingAnchor],
        [c.trailingAnchor constraintEqualToAnchor:d.clip.trailingAnchor],
        d.heightC,
    ]];
    return d;
}
- (NSString *)subtitle { return self.subtitleLabel.stringValue.length ? self.subtitleLabel.stringValue : nil; }
- (void)setSubtitle:(NSString *)s {
    self.subtitleLabel.stringValue = s ?: @"";
    self.subtitleLabel.hidden = !s.length;
    self.header.accessibilityHelp = s;
}
- (void)toggle:(id)sender { [self setExpanded:!_expanded animated:YES]; }
- (BOOL)expanded { return _expanded; }
- (void)setExpanded:(BOOL)e { [self setExpanded:e animated:YES]; }
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (expanded == _expanded) return;
    _expanded = expanded;
    self.chevron.image = [NSImage imageWithSystemSymbolName:expanded ? @"chevron.down" : @"chevron.right" accessibilityDescription:nil];
    NSAccessibilityPostNotification(self.header, NSAccessibilityValueChangedNotification);
    BOOL anim = animated && self.window && !ReduceMotion();
    if (expanded) {
        self.clip.hidden = NO;
        self.bottomPin.active = NO;
        self.heightC.constant = 0;
        self.heightC.active = YES;
        [self layoutSubtreeIfNeeded];
        CGFloat h = NSHeight(self.content.frame) + 8;
        void (^done)(void) = ^{ self.heightC.active = NO; self.bottomPin.active = YES; };
        if (!anim) { done(); return; }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            ctx.allowsImplicitAnimation = YES;
            self.heightC.animator.constant = h;
            [self.window.contentView layoutSubtreeIfNeeded];
        } completionHandler:^{ if (self->_expanded) done(); }];
    } else {
        self.heightC.constant = NSHeight(self.clip.frame);
        self.bottomPin.active = NO;
        self.heightC.active = YES;
        void (^done)(void) = ^{ if (!self->_expanded) self.clip.hidden = YES; };
        if (!anim) { self.heightC.constant = 0; done(); return; }
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.3;
            ctx.allowsImplicitAnimation = YES;
            self.heightC.animator.constant = 0;
            [self.window.contentView layoutSubtreeIfNeeded];
        } completionHandler:done];
    }
}
@end

#pragma mark - Segmented

@class OVSegmented;
@interface OVSegmentA11y : NSAccessibilityElement
@property (weak) OVSegmented *owner;
@property NSInteger index;
@end

@interface OVSegmented ()
@property NSArray<NSString *> *titles, *symbols, *labels;
@property NSArray<OVSegmentA11y *> *segA11y;   // cached: VoiceOver keeps identity and focus
@end

@implementation OVSegmentA11y
- (id)accessibilityValue { return @(self.owner.selectedIndex == self.index); }
- (BOOL)accessibilityPerformPress {
    [self.owner setSelectedIndex:self.index];
    [self.owner sendAction:self.owner.action to:self.owner.target];
    return YES;
}
@end

static const CGFloat kSegPad = 4, kSegH = 28;

@implementation OVSegmented
+ (instancetype)segmentedWithItems:(NSArray<NSArray<NSString *> *> *)items {
    OVSegmented *s = [[OVSegmented alloc] initWithFrame:NSZeroRect];
    NSMutableArray *t = [NSMutableArray array], *y = [NSMutableArray array], *l = [NSMutableArray array];
    for (NSArray *it in items) {
        [t addObject:it[0]];
        [y addObject:it.count > 1 ? it[1] : @""];
        [l addObject:it.count > 2 && [it[2] length] ? it[2] : it[0]];
    }
    s.titles = t;
    s.symbols = y;
    s.labels = l;
    s.selectedIndex = 0;
    for (NSUInteger i = 0; i < items.count; i++)
        if ([items[i] count] > 2 && [items[i][2] length]) [s addToolTipRect:[s rectOfSegment:i] owner:s userData:(void *)(uintptr_t)i];
    [s setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return s;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (NSFont *)segFont { return [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]; }
- (CGFloat)widthOfSegment:(NSInteger)i {
    if (![self.titles[i] length] && [self.symbols[i] length]) return 40;   // icon only
    CGFloat w = ceil([self.titles[i] sizeWithAttributes:@{NSFontAttributeName: self.segFont}].width) + 28;
    return w + ([self.symbols[i] length] ? 20 : 0);
}
- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)data {
    NSUInteger i = (NSUInteger)(uintptr_t)data;
    return i < self.labels.count ? self.labels[i] : nil;
}
- (NSRect)rectOfSegment:(NSInteger)i {
    CGFloat x = kSegPad;
    for (NSInteger k = 0; k < i; k++) x += [self widthOfSegment:k];
    return NSMakeRect(x, kSegPad, [self widthOfSegment:i], kSegH);
}
- (NSSize)intrinsicContentSize {
    if (!self.titles.count) return NSMakeSize(NSViewNoIntrinsicMetric, kSegH + 2 * kSegPad);
    NSRect last = [self rectOfSegment:self.titles.count - 1];
    return NSMakeSize(NSMaxX(last) + kSegPad, kSegH + 2 * kSegPad);
}
- (void)setSelectedIndex:(NSInteger)i {
    if (i < -1 || i >= (NSInteger)self.titles.count || i == _selectedIndex) return;
    _selectedIndex = i;
    self.needsDisplay = YES;
    for (id c in self.segA11y) NSAccessibilityPostNotification(c, NSAccessibilityValueChangedNotification);
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.5);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:12 yRadius:12];
    [C(OVRoleField) setFill];
    [track fill];
    [C(OVRoleBorder) setStroke];
    track.lineWidth = 1;
    [track stroke];
    for (NSInteger i = 0; i < (NSInteger)self.titles.count; i++) {
        NSRect r = [self rectOfSegment:i];
        BOOL sel = i == self.selectedIndex;
        if (sel) { [C(OVRoleCTA) setFill]; [[NSBezierPath bezierPathWithRoundedRect:r xRadius:9 yRadius:9] fill]; }
        NSColor *fg = sel ? C(OVRoleCTAText) : C(OVRoleMuted);
        NSDictionary *a = @{NSFontAttributeName: self.segFont, NSForegroundColorAttributeName: fg};
        NSSize ts = [self.titles[i] sizeWithAttributes:a];
        NSImage *g = [self.symbols[i] length] ? Tinted(Glyph(self.symbols[i], 13, NSFontWeightMedium), fg) : nil;
        BOOL iconOnly = g && ![self.titles[i] length];
        CGFloat iw = g ? g.size.width + (iconOnly ? 0 : 6) : 0;
        CGFloat x = NSMinX(r) + round((NSWidth(r) - ts.width - iw) / 2);
        if (g) [g drawInRect:NSMakeRect(x, NSMidY(r) - g.size.height / 2, g.size.width, g.size.height)
                    fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
        [self.titles[i] drawAtPoint:NSMakePoint(x + iw, round(NSMidY(r) - ts.height / 2)) withAttributes:a];
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill]; }
- (void)choose:(NSInteger)i {
    if (i == self.selectedIndex || i < 0 || i >= (NSInteger)self.titles.count) return;
    self.selectedIndex = i;
    [self sendAction:self.action to:self.target];
}
- (void)mouseDown:(NSEvent *)e {
    if (!self.enabled) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    for (NSInteger i = 0; i < (NSInteger)self.titles.count; i++)
        if (NSPointInRect(p, NSInsetRect([self rectOfSegment:i], -2, -kSegPad))) { [self choose:i]; break; }
    [self.window makeFirstResponder:self];
}
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 123) [self choose:self.selectedIndex - 1];
    else if (e.keyCode == 124) [self choose:self.selectedIndex + 1];
    else [super keyDown:e];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioGroupRole; }
- (id)accessibilityValue {
    return (self.selectedIndex >= 0 && self.selectedIndex < (NSInteger)self.titles.count) ? self.labels[self.selectedIndex] : nil;
}
- (NSArray *)accessibilityChildren {
    if (self.segA11y.count != self.titles.count) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)self.titles.count; i++) {
            OVSegmentA11y *e = [OVSegmentA11y accessibilityElementWithRole:NSAccessibilityRadioButtonRole
                                                                     frame:NSZeroRect label:self.labels[i] parent:self];
            e.owner = self;
            e.index = i;
            [out addObject:e];
        }
        self.segA11y = out;
    }
    for (OVSegmentA11y *e in self.segA11y)
        if (self.window) e.accessibilityFrame = [self.window convertRectToScreen:[self convertRect:[self rectOfSegment:e.index] toView:nil]];
    return self.segA11y;
}
@end

#pragma mark - Slider

@implementation OVSliderCell
- (CGFloat)fraction {
    double span = self.maxValue - self.minValue;
    return span > 0 ? (self.doubleValue - self.minValue) / span : 0;
}
- (NSRect)knobRectFlipped:(BOOL)flipped {
    NSRect b = self.controlView.bounds;
    return NSMakeRect(NSMinX(b) + [self fraction] * (NSWidth(b) - 16), NSMidY(b) - 8, 16, 16);
}
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped {
    NSRect b = self.controlView.bounds;
    NSRect track = NSMakeRect(NSMinX(b), NSMidY(b) - 3, NSWidth(b), 6);
    CGFloat knobX = NSMidX([self knobRectFlipped:flipped]);
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45);
    NSBezierPath *t = [NSBezierPath bezierPathWithRoundedRect:track xRadius:3 yRadius:3];
    [C(OVRoleField) setFill];
    [t fill];
    [C(OVRoleBorder) setStroke];
    [t stroke];
    NSRect fill = track;
    fill.size.width = MAX(0, knobX - NSMinX(track));
    [C(OVRoleAccent) setFill];
    [NSGraphicsContext saveGraphicsState];
    [t addClip];
    NSRectFill(fill);
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawKnob:(NSRect)r {
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45);
    [C(OVRoleBackground) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:r] fill];
    [C(OVRoleAccent) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 3, 3)] fill];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation OVSlider
+ (Class)cellClass { return OVSliderCell.class; }
@end

#pragma mark - Badges

static NSView *MakeBadge(NSString *text, OVRole tone, CGFloat font, CGFloat vpad, CGFloat hpad, CGFloat radius) {
    BOOL muted = tone == OVRoleMuted;
    NSColor *tc = C(tone);
    NSTextField *l = OVLabel(text, font, NSFontWeightMedium, tc);
    OVBoxView *b = [OVBoxView boxWithFill:muted ? nil : OVColorAlpha(tone, 0.12)
                                   border:muted ? C(OVRoleBorder) : OVColorAlpha(tone, 0.45) radius:radius];
    [b addSubview:l];
    OVPin(l, b, NSEdgeInsetsMake(vpad, hpad, vpad, hpad));
    [b setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

NSView *OVBadge(NSString *text, OVRole tone) { return MakeBadge(text, tone, 12, 3, 9, 10); }

NSView *OVCompactBadge(NSString *text, OVRole tone) { return MakeBadge(text, tone, 10, 1, 6, 7); }

static NSView *ProBadge(BOOL compact) {
    NSView *b = compact ? MakeBadge(L(@"16 GB"), OVRoleWarn, 10, 1, 6, 7) : OVBadge(L(@"16 GB"), OVRoleWarn);
    b.toolTip = L(@"This feature is meant for Macs with 16 GB of memory or more. On a Mac with less it may run out of memory.");
    b.accessibilityElement = YES;
    b.accessibilityRole = NSAccessibilityStaticTextRole;
    b.accessibilityLabel = L(@"16 GB: needs a Mac with 16 GB of memory or more");
    b.accessibilityHelp = b.toolTip;
    return b;
}
NSView *OVProBadge(void) { return ProBadge(NO); }
NSView *OVProBadgeCompact(void) { return ProBadge(YES); }

/// `w` is only used to center the alert over that window: a synchronous BOOL answer rules out a sheet.
BOOL OVConfirmProRun(NSWindow *w) {
    double gb = [OVSettings physicalMemoryGB];
    if (gb >= 16) return YES;
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"This may run out of memory");
    a.informativeText = [NSString stringWithFormat:L(@"This feature is meant for Macs with 16 GB of memory or more. This Mac has %.0f GB, so it may run out of memory or slow down a lot."), gb];
    [a addButtonWithTitle:L(@"Cancel")];       // Return = the safe answer
    [a addButtonWithTitle:L(@"Run anyway")];
    if (w) {
        NSRect f = a.window.frame;
        [a.window setFrameOrigin:NSMakePoint(NSMidX(w.frame) - NSWidth(f) / 2, NSMidY(w.frame) - NSHeight(f) / 2)];
    }
    return [a runModal] == NSAlertSecondButtonReturn;
}

#pragma mark - Drop zone

@interface OVDropZone ()
@property (copy) void (^callback)(NSArray<NSURL *> *);
@property NSArray<NSString *> *exts;
@property BOOL dragging;
@property (copy) NSString *titleText;
@end

@implementation OVDropZone
+ (instancetype)zoneWithTitle:(NSString *)t hint:(NSString *)h types:(NSArray<NSString *> *)exts onFiles:(void (^)(NSArray<NSURL *> *))cb {
    OVDropZone *z = [[OVDropZone alloc] initWithFrame:NSZeroRect];
    z.callback = cb;
    z.exts = exts;
    z.titleText = t;
    OVBoxView *icon = [OVBoxView boxWithFill:C(OVRoleAccentSoft) border:nil radius:10];
    FixSize(icon, 40, 40);
    NSImageView *g = OVSymbol(@"arrow.up.doc", 18, C(OVRoleAccent));
    [icon addSubview:g];
    Center(g, icon);
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:icon, OVLabel(t, 14, NSFontWeightSemibold, C(OVRoleText)), nil];
    if (h.length) [rows addObject:OVLabel(h, 12, NSFontWeightRegular, C(OVRoleMuted))];
    if (exts.count) {
        NSMutableArray *chips = [NSMutableArray array];
        for (NSString *e in exts) [chips addObject:OVBadge(e.uppercaseString, OVRoleMuted)];
        [rows addObject:OVHStack(chips, 6)];
    }
    NSStackView *s = OVVStack(rows, 8);
    s.alignment = NSLayoutAttributeCenterX;
    for (NSView *v in rows) v.accessibilityElement = NO;
    [z addSubview:s];
    OVPin(s, z, NSEdgeInsetsMake(22, 20, 22, 20));
    [z registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    z.accessibilityLabel = h.length ? [NSString stringWithFormat:@"%@. %@", t, h] : t;
    return z;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString *)accessibilityHelp { return L(@"Click to choose files, or drop them here"); }
- (BOOL)accessibilityPerformPress { [self choose]; return YES; }
- (NSArray *)accessibilityChildren { return @[]; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12] fill]; }
- (void)drawRect:(NSRect)dirty {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:12 yRadius:12];
    if (self.dragging) { [C(OVRoleAccentSoft) setFill]; [p fill]; }
    CGFloat dash[2] = {5, 4};
    [p setLineDash:dash count:2 phase:0];
    p.lineWidth = 1;
    [(self.dragging ? C(OVRoleAccent) : C(OVRoleGhostBorder)) setStroke];
    [p stroke];
}
- (NSArray<NSURL *> *)acceptable:(id<NSDraggingInfo>)info {
    NSArray *urls = [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableArray *ok = [NSMutableArray array];
    for (NSURL *u in urls) if (!self.exts.count || [self.exts containsObject:u.pathExtension.lowercaseString]) [ok addObject:u];
    return ok;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
    if (![self acceptable:info].count) return NSDragOperationNone;
    self.dragging = YES;
    self.needsDisplay = YES;
    return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)info { self.dragging = NO; self.needsDisplay = YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
    self.dragging = NO;
    self.needsDisplay = YES;
    NSArray *urls = [self acceptable:info];
    if (urls.count && self.callback) self.callback(urls);
    return urls.count > 0;
}
- (void)choose {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = YES;
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *e in self.exts) { UTType *t = [UTType typeWithFilenameExtension:e]; if (t) [types addObject:t]; }
    if (types.count) p.allowedContentTypes = types;
    void (^done)(NSModalResponse) = ^(NSModalResponse r) { if (r == NSModalResponseOK && p.URLs.count && self.callback) self.callback(p.URLs); };
    if (self.window) [p beginSheetModalForWindow:self.window completionHandler:done]; else done([p runModal]);
}
- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; [self choose]; }
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@" "] || [c isEqualToString:@"\r"]) [self choose]; else [super keyDown:e];
}
@end

#pragma mark - Empty state, play, log

NSView *OVEmptyState(NSString *symbol, NSString *title, NSString *text, NSArray<NSButton *> *buttons) {
    OVBoxView *icon = [OVBoxView boxWithFill:C(OVRoleField) border:C(OVRoleBorder) radius:16];
    FixSize(icon, 64, 64);
    NSImageView *g = OVSymbol(symbol, 28, C(OVRoleMuted));
    [icon addSubview:g];
    Center(g, icon);
    NSTextField *t = OVLabel(title, 16, NSFontWeightSemibold, C(OVRoleText));
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:icon, t, nil];
    if (text.length) {
        NSTextField *d = OVWrapLabel(text, 13, nil);
        d.alignment = NSTextAlignmentCenter;
        [d.widthAnchor constraintLessThanOrEqualToConstant:380].active = YES;
        [rows addObject:d];
    }
    if (buttons.count) [rows addObject:OVHStack(buttons, 10)];
    NSStackView *s = OVVStack(rows, 10);
    s.alignment = NSLayoutAttributeCenterX;
    [s setCustomSpacing:14 afterView:icon];
    if (buttons.count) [s setCustomSpacing:16 afterView:rows[rows.count - 2]];
    return s;
}

@interface OVPlayCircle : NSButton
@end
@implementation OVPlayCircle
- (NSSize)intrinsicContentSize { return NSMakeSize(32, 32); }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (void)setImage:(NSImage *)i { [super setImage:i]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithOvalInRect:self.bounds] fill]; }
- (void)drawRect:(NSRect)dirty {
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.4);
    [[C(OVRoleText) colorWithAlphaComponent:self.isHighlighted ? 0.75 : 1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:self.bounds] fill];
    NSImage *g = Tinted([self.image imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightBold]], C(OVRoleBackground));
    if (g) [g drawInRect:NSMakeRect(round(NSMidX(self.bounds) - g.size.width / 2 + 0.5), round(NSMidY(self.bounds) - g.size.height / 2), g.size.width, g.size.height)
                fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    [NSGraphicsContext restoreGraphicsState];
}
@end

NSButton *OVPlayButton(id target, SEL action) {
    OVPlayCircle *b = [OVPlayCircle buttonWithTitle:@"" target:target action:action];
    b.bordered = NO;
    b.image = [NSImage imageWithSystemSymbolName:@"play.fill" accessibilityDescription:nil];
    b.accessibilityLabel = L(@"Play");
    FixSize(b, 32, 32);
    return b;
}

NSScrollView *OVLogView(NSTextView **outText) {
    NSScrollView *sv = [NSScrollView new];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = YES;
    sv.backgroundColor = C(OVRoleLog);
    sv.borderType = NSNoBorder;
    sv.wantsLayer = YES;
    sv.layer.cornerRadius = 8;
    sv.layer.cornerCurve = kCACornerCurveContinuous;
    sv.layer.masksToBounds = YES;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 100)];
    tv.minSize = NSMakeSize(0, 0);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.textContainerInset = NSMakeSize(10, 8);
    tv.editable = NO;
    tv.selectable = YES;
    tv.drawsBackground = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    tv.textColor = C(OVRoleText);
    tv.accessibilityLabel = L(@"Log");
    sv.documentView = tv;
    if (outText) *outText = tv;
    return sv;
}

#pragma mark - Colors and repaint

NSColor *OVColorAlpha(OVRole role, CGFloat alpha) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        __block NSColor *out = NSColor.magentaColor;
        [a performAsCurrentDrawingAppearance:^{
            NSColor *c = [OVColor(role) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            if (c) out = [c colorWithAlphaComponent:c.alphaComponent * alpha];
        }];
        return out;
    }];
}

static void RepaintView(NSView *v) {
    if ([v isKindOfClass:NSScrollView.class]) {
        NSScrollView *sv = (NSScrollView *)v;
        if (sv.drawsBackground && sv.backgroundColor) sv.backgroundColor = sv.backgroundColor;
    }
    if ([v isKindOfClass:NSTextField.class]) {
        NSTextField *t = (NSTextField *)v;
        if (t.textColor) t.textColor = t.textColor;
    }
    if ([v isKindOfClass:NSImageView.class]) {
        NSImageView *iv = (NSImageView *)v;
        if (iv.contentTintColor) iv.contentTintColor = iv.contentTintColor;
    }
    if ([v isKindOfClass:NSButton.class]) {
        NSButton *b = (NSButton *)v;
        if (b.contentTintColor) b.contentTintColor = b.contentTintColor;
    }
    if ([v isKindOfClass:NSTextView.class]) {
        NSTextView *tv = (NSTextView *)v;
        if (tv.textColor && !tv.isEditable) tv.textColor = tv.textColor;
    }
    v.needsDisplay = YES;
    [v.layer setNeedsDisplay];
    for (NSView *sub in v.subviews) RepaintView(sub);
}

void OVRepaintAll(void) {
    for (NSWindow *w in NSApp.windows) {
        if (w.contentView) RepaintView(w.contentView);
        [w invalidateShadow];
    }
}

#pragma mark - Page header, scroll, field block, columns

@interface OVTextAreaBox : OVBoxView
@property (weak) NSTextView *textView;
@property (weak) NSWindow *observedWindow;
@property BOOL focused;
@end

/// The page title: a static text that VoiceOver reports as a heading.
@interface OVHeadingField : NSTextField
@end
@implementation OVHeadingField
- (NSAccessibilityRole)accessibilityRole { return @"AXHeading"; }   // no NSAccessibility constant for it
- (id)accessibilityValue { return self.stringValue; }
@end

NSView *OVPageHeader(NSString *title, NSString *subtitle, NSView *accessory) {
    NSTextField *t = [[OVHeadingField alloc] initWithFrame:NSZeroRect];   // labelWithString: would not give the subclass
    t.editable = NO;
    t.selectable = NO;
    t.bezeled = NO;
    t.drawsBackground = NO;
    t.stringValue = title ?: @"";
    t.accessibilityRole = @"AXHeading";
    [t.cell setAccessibilityRole:@"AXHeading"];
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    [t setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    t.attributedStringValue = [[NSAttributedString alloc] initWithString:title ?: @"" attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:28 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: C(OVRoleText), NSKernAttributeName: @(-0.7)}];
    NSMutableArray *texts = [NSMutableArray arrayWithObject:t];
    if (subtitle.length) {
        NSTextField *s = OVLabel(subtitle, 14, NSFontWeightRegular, C(OVRoleMuted));
        [texts addObject:s];
    }
    NSStackView *left = OVVStack(texts, 4);
    NSMutableArray *row = [NSMutableArray arrayWithObjects:left, OVSpacer(), nil];
    if (accessory) [row addObject:accessory];
    NSStackView *h = OVHStack(row, 12);
    h.alignment = NSLayoutAttributeCenterY;
    h.edgeInsets = NSEdgeInsetsMake(0, 0, 4, 0);
    return h;
}

NSScrollView *OVPageScroll(NSArray<NSView *> *views) {
    NSStackView *page = OVVStack(views, 16);
    page.edgeInsets = NSEdgeInsetsMake(24, 28, 28, 28);
    OVFillWidth(views, page);
    return OVScrollPage(page);
}

NSView *OVFieldBlock(NSString *label, NSString *hint, NSView *control) {
    NSTextField *l = OVLabel(label, 14, NSFontWeightSemibold, C(OVRoleText));
    NSMutableArray *rows = [NSMutableArray arrayWithObjects:l, control, nil];
    NSTextField *h = hint.length ? OVWrapLabel(hint, 13, C(OVRoleMuted)) : nil;
    if (h) [rows addObject:h];
    // a control that has no name of its own is named by the label (the text view inside an OVTextArea gets it)
    NSView *named = control;
    if ([control isKindOfClass:OVTextAreaBox.class]) named = ((OVTextAreaBox *)control).textView ?: control;
    if (!named.accessibilityLabel.length) {
        named.accessibilityLabel = label;
        if ([named isKindOfClass:NSControl.class]) [((NSControl *)named).cell setAccessibilityLabel:label];   // cell-based controls
    }
    NSStackView *s = OVVStack(rows, 8);
    if (h) [s setCustomSpacing:6 afterView:control];
    BOOL natural = [control isKindOfClass:NSButton.class] || [control isKindOfClass:OVSwitch.class] ||
                   [control isKindOfClass:OVSegmented.class] || [control isKindOfClass:NSImageView.class];
    NSMutableArray *fill = [NSMutableArray arrayWithObject:l];
    if (!natural) [fill addObject:control];
    if (h) [fill addObject:h];
    OVFillWidth(fill, s);
    return s;
}

NSView *OVCheckRow(NSButton *check, NSString *hint) {
    if (!hint.length) return check;
    NSTextField *h = OVWrapLabel(hint, 13, C(OVRoleMuted));
    NSView *indent = [NSView new];
    [indent addSubview:h];
    OVPin(h, indent, NSEdgeInsetsMake(0, 24, 0, 0));
    NSStackView *s = OVVStack(@[check, indent], 4);
    OVFillWidth(@[indent], s);
    return s;
}

static const CGFloat kColumnMin = 260;

@interface OVColumnsView : NSView
@property NSArray<NSView *> *cols;
@property CGFloat gap;
@property NSArray<NSLayoutConstraint *> *rowC, *stackC;
@property BOOL stacked;
@end
@implementation OVColumnsView
- (void)build {
    NSMutableArray *row = [NSMutableArray array], *stack = [NSMutableArray array];
    NSView *prev = nil;
    for (NSView *c in self.cols) {
        c.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:c];
        [row addObject:[c.topAnchor constraintEqualToAnchor:self.topAnchor]];
        [row addObject:[self.bottomAnchor constraintGreaterThanOrEqualToAnchor:c.bottomAnchor]];
        [stack addObject:[c.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
        [stack addObject:[c.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
        if (prev) {
            [row addObject:[c.leadingAnchor constraintEqualToAnchor:prev.trailingAnchor constant:self.gap]];
            [row addObject:[c.widthAnchor constraintEqualToAnchor:prev.widthAnchor]];
            [stack addObject:[c.topAnchor constraintEqualToAnchor:prev.bottomAnchor constant:self.gap]];
        } else {
            [row addObject:[c.leadingAnchor constraintEqualToAnchor:self.leadingAnchor]];
            [stack addObject:[c.topAnchor constraintEqualToAnchor:self.topAnchor]];
        }
        prev = c;
    }
    [row addObject:[prev.trailingAnchor constraintEqualToAnchor:self.trailingAnchor]];
    [stack addObject:[self.bottomAnchor constraintEqualToAnchor:prev.bottomAnchor]];
    // the tallest column sets the height of the row
    NSLayoutConstraint *tall = [self.bottomAnchor constraintEqualToAnchor:self.cols.firstObject.bottomAnchor];
    tall.priority = NSLayoutPriorityDefaultLow;
    [row addObject:tall];
    self.rowC = row;
    self.stackC = stack;
    [NSLayoutConstraint activateConstraints:row];
}
- (void)layout {
    [super layout];
    CGFloat need = kColumnMin * self.cols.count + self.gap * (self.cols.count - 1);
    BOOL stack = NSWidth(self.bounds) > 0 && NSWidth(self.bounds) < need;
    if (stack == self.stacked) return;
    self.stacked = stack;
    [NSLayoutConstraint deactivateConstraints:stack ? self.rowC : self.stackC];
    [NSLayoutConstraint activateConstraints:stack ? self.stackC : self.rowC];
    self.needsLayout = YES;
}
@end

NSView *OVColumns(NSArray<NSView *> *cols, CGFloat gap) {
    OVColumnsView *v = [[OVColumnsView alloc] initWithFrame:NSZeroRect];
    v.cols = cols;
    v.gap = gap;
    [v build];
    return v;
}

#pragma mark - Popup

@interface OVPopupCell : NSPopUpButtonCell
@end
@implementation OVPopupCell
- (void)drawWithFrame:(NSRect)f inView:(NSView *)v {
    BOOL focus = v.window.isKeyWindow && v.window.firstResponder == v;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(f, 0.5, 0.5) xRadius:10 yRadius:10];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.6);
    [C(OVRoleField) setFill];
    [p fill];
    if (self.isHighlighted) { [OVColorAlpha(OVRoleText, 0.06) setFill]; [p fill]; }
    [(focus ? C(OVRoleFocus) : C(OVRoleBorder)) setStroke];
    p.lineWidth = focus ? 2 : 1;
    [p stroke];
    NSImage *chev = Tinted(Glyph(@"chevron.down", 11, NSFontWeightSemibold), C(OVRoleMuted));
    CGFloat chevW = chev.size.width;
    if (chev) [chev drawInRect:NSMakeRect(NSMaxX(f) - 14 - chevW, round(NSMidY(f) - chev.size.height / 2), chevW, chev.size.height)
                      fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: C(OVRoleText), NSParagraphStyleAttributeName: ps};
    NSString *t = self.selectedItem.title ?: @"";
    CGFloat th = ceil([t sizeWithAttributes:a].height);
    [t drawInRect:NSMakeRect(NSMinX(f) + 12, round(NSMidY(f) - th / 2), MAX(0, NSWidth(f) - 12 - 14 - chevW - 8 - 4), th) withAttributes:a];
    [NSGraphicsContext restoreGraphicsState];
}
@end

@implementation OVPopup
+ (Class)cellClass { return OVPopupCell.class; }
+ (instancetype)popup {
    OVPopup *p = [[OVPopup alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.bordered = NO;
    p.focusRingType = NSFocusRingTypeNone;
    p.font = [NSFont systemFontOfSize:13];
    [p setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return p;
}
- (NSSize)intrinsicContentSize {
    CGFloat w = 120;
    NSDictionary *a = @{NSFontAttributeName: [NSFont systemFontOfSize:13]};
    for (NSMenuItem *it in self.itemArray) w = MAX(w, ceil([it.title sizeWithAttributes:a].width) + 12 + 14 + 11 + 8);
    return NSMakeSize(w, 36);
}
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
- (void)selectItemAtIndex:(NSInteger)i { [super selectItemAtIndex:i]; self.needsDisplay = YES; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (!self.window) return;
    for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(redraw:) name:n object:self.window];
}
- (void)redraw:(NSNotification *)n { self.needsDisplay = YES; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end

#pragma mark - Switch

@implementation OVSwitch
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, 36, 20)])) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.widthAnchor constraintEqualToConstant:36].active = YES;
        [self.heightAnchor constraintEqualToConstant:20].active = YES;
        [self setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [self setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(36, 20); }
- (void)setOn:(BOOL)on {
    if (on == _on) return;
    _on = on;
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
- (void)flip {
    if (!self.enabled) return;
    self.on = !self.on;
    [self sendAction:self.action to:self.target];
}
- (void)mouseDown:(NSEvent *)e {
    if (!self.enabled) return;
    [self.window makeFirstResponder:self];
    [self flip];
}
- (void)keyDown:(NSEvent *)e {
    NSString *c = e.charactersIgnoringModifiers;
    if ([c isEqualToString:@" "] || [c isEqualToString:@"\r"]) [self flip]; else [super keyDown:e];
}
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:10 yRadius:10] fill]; }
- (void)drawRect:(NSRect)dirty {
    NSRect b = self.bounds;
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45);
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:b xRadius:NSHeight(b) / 2 yRadius:NSHeight(b) / 2];
    [(self.on ? C(OVRoleCTA) : C(OVRoleGhostBorder)) setFill];
    [track fill];
    CGFloat k = NSHeight(b) - 6;
    NSRect knob = NSMakeRect(self.on ? NSMaxX(b) - 3 - k : NSMinX(b) + 3, NSMinY(b) + 3, k, k);
    [(self.on ? C(OVRoleCTAText) : C(OVRoleMuted)) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
    [NSGraphicsContext restoreGraphicsState];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityCheckBoxRole; }
- (NSAccessibilitySubrole)accessibilitySubrole { return NSAccessibilitySwitchSubrole; }
- (id)accessibilityValue { return @(self.on); }
- (BOOL)accessibilityPerformPress { [self flip]; return YES; }
@end

#pragma mark - Radio

@interface OVRadio : NSButton
@end
@implementation OVRadio
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        [self setButtonType:NSButtonTypeRadio];
        self.bordered = NO;
        self.font = [NSFont systemFontOfSize:14];
        [self setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (NSSize)intrinsicContentSize {
    return NSMakeSize(18 + (self.title.length ? 8 + ceil([self.title sizeWithAttributes:@{NSFontAttributeName: self.font}].width) : 0), 22);
}
- (void)setTitle:(NSString *)t { [super setTitle:t]; [self invalidateIntrinsicContentSize]; self.needsDisplay = YES; }
- (void)setState:(NSControlStateValue)s { [super setState:s]; self.needsDisplay = YES; }
- (void)setEnabled:(BOOL)e { [super setEnabled:e]; self.needsDisplay = YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }
- (NSRect)circleRect { return NSMakeRect(0, round((NSHeight(self.bounds) - 18) / 2), 18, 18); }
- (NSRect)focusRingMaskBounds { return [self circleRect]; }
- (void)drawFocusRingMask { [[NSBezierPath bezierPathWithOvalInRect:[self circleRect]] fill]; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 36 || e.keyCode == 76) [self performClick:nil]; else [super keyDown:e];
}
- (void)drawRect:(NSRect)dirty {
    BOOL on = self.state == NSControlStateValueOn;
    NSRect c = [self circleRect];
    [NSGraphicsContext saveGraphicsState];
    if (!self.enabled) CGContextSetAlpha(NSGraphicsContext.currentContext.CGContext, 0.45);
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(c, 0.5, 0.5)];
    if (self.isHighlighted) { [OVColorAlpha(OVRoleText, 0.08) setFill]; [ring fill]; }
    [(on ? C(OVRoleCTA) : C(OVRoleGhostBorder)) setStroke];
    ring.lineWidth = on ? 1.5 : 1;
    [ring stroke];
    if (on) {
        [C(OVRoleCTA) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(c, 5, 5)] fill];
    }
    if (self.title.length) {
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByTruncatingTail;
        NSDictionary *a = @{NSFontAttributeName: self.font, NSForegroundColorAttributeName: C(OVRoleText), NSParagraphStyleAttributeName: ps};
        CGFloat th = ceil([self.title sizeWithAttributes:a].height);
        [self.title drawInRect:NSMakeRect(26, round((NSHeight(self.bounds) - th) / 2), MAX(0, NSWidth(self.bounds) - 26), th) withAttributes:a];
    }
    [NSGraphicsContext restoreGraphicsState];
}
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityRadioButtonRole; }
- (NSString *)accessibilityLabel { return super.accessibilityLabel ?: self.title; }
- (id)accessibilityValue { return @(self.state == NSControlStateValueOn); }
- (BOOL)accessibilityPerformPress { [self performClick:nil]; return YES; }
/// Turns the siblings with the same target+action off; the button itself stays on when clicked again.
- (void)select {
    for (NSView *v in self.superview.subviews)
        if (v != self && [v isKindOfClass:OVRadio.class]) {
            NSButton *o = (NSButton *)v;
            if (o.action == self.action && o.target == self.target) o.state = NSControlStateValueOff;
        }
    self.state = NSControlStateValueOn;
}
- (void)mouseDown:(NSEvent *)e {
    if (!self.enabled) return;
    [self.window makeFirstResponder:self];
    [super mouseDown:e];   // tracks the click and sends the action on mouse up
}
- (BOOL)sendAction:(SEL)a to:(id)t {
    [self select];
    return [super sendAction:a to:t];
}
@end

NSButton *OVRadioButton(NSString *title, id target, SEL action) {
    OVRadio *b = [[OVRadio alloc] initWithFrame:NSZeroRect];
    b.title = title;
    b.target = target;
    b.action = action;
    return b;
}

#pragma mark - Text area

@implementation OVTextAreaBox
- (void)updateFocus {
    BOOL f = NO;
    NSResponder *r = self.window.firstResponder;
    f = self.textView && r == self.textView && self.window.isKeyWindow;
    if (f == self.focused) return;
    self.focused = f;
    self.borderColor = f ? C(OVRoleFocus) : C(OVRoleBorder);
    self.borderWidth = f ? 2 : 1;
}
- (void)observeWindow {
    if (self.observedWindow) {
        [self.observedWindow removeObserver:self forKeyPath:@"firstResponder"];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidBecomeKeyNotification object:self.observedWindow];
        [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowDidResignKeyNotification object:self.observedWindow];
        self.observedWindow = nil;
    }
    if (!self.window) return;
    self.observedWindow = self.window;
    [self.window addObserver:self forKeyPath:@"firstResponder" options:0 context:NULL];
    for (NSNotificationName n in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification])
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(focusChanged:) name:n object:self.window];
    [self updateFocus];
}
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self observeWindow]; }
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx { [self updateFocus]; }
- (void)focusChanged:(NSNotification *)n { [self updateFocus]; }
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    @try { [self.observedWindow removeObserver:self forKeyPath:@"firstResponder"]; } @catch (NSException *e) {}
}
@end

NSView *OVTextArea(NSScrollView *textScroll, CGFloat minHeight) {
    OVTextAreaBox *box = [OVTextAreaBox boxWithFill:C(OVRoleField) border:C(OVRoleBorder) radius:10];
    textScroll.drawsBackground = NO;
    textScroll.borderType = NSNoBorder;
    textScroll.hasVerticalScroller = YES;
    textScroll.wantsLayer = YES;
    textScroll.layer.cornerRadius = 9;
    textScroll.layer.cornerCurve = kCACornerCurveContinuous;
    textScroll.layer.masksToBounds = YES;
    NSTextView *tv = [textScroll.documentView isKindOfClass:NSTextView.class] ? textScroll.documentView : nil;
    if (tv) {
        tv.drawsBackground = NO;
        tv.textContainerInset = NSMakeSize(8, 10);
        // palette-driven (dynamic) colors, set unconditionally: the default text color is the system label color
        tv.textColor = C(OVRoleText);
        tv.insertionPointColor = C(OVRoleText);
        NSMutableDictionary *ta = [tv.typingAttributes mutableCopy] ?: [NSMutableDictionary dictionary];
        ta[NSForegroundColorAttributeName] = C(OVRoleText);
        tv.typingAttributes = ta;
        box.textView = tv;
        // Begin/EndEditing only cover typing; the first-responder observer in the box covers plain focus
        for (NSNotificationName n in @[NSTextDidBeginEditingNotification, NSTextDidEndEditingNotification])
            [NSNotificationCenter.defaultCenter addObserver:box selector:@selector(focusChanged:) name:n object:tv];
    }
    [box addSubview:textScroll];
    OVPin(textScroll, box, NSEdgeInsetsMake(2, 2, 2, 2));
    NSLayoutConstraint *h = [box.heightAnchor constraintGreaterThanOrEqualToConstant:minHeight];
    h.active = YES;
    return box;
}

#pragma mark - Table row

@implementation OVTableRowView
- (BOOL)isEmphasized { return NO; }
- (void)setEmphasized:(BOOL)e {}
- (NSBackgroundStyle)interiorBackgroundStyle { return NSBackgroundStyleNormal; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)prepareForReuse { [super prepareForReuse]; self.hovered = NO; }
- (void)mouseEntered:(NSEvent *)e { self.hovered = YES; }
- (void)mouseExited:(NSEvent *)e { self.hovered = NO; }
- (void)setHovered:(BOOL)h { if (h == _hovered) return; _hovered = h; self.needsDisplay = YES; }
- (void)drawBackgroundInRect:(NSRect)r {
    if (!self.hovered || self.selected) return;
    [C(OVRoleField) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1) xRadius:8 yRadius:8] fill];
}
- (void)drawSelectionInRect:(NSRect)r {
    [C(OVRoleAccentSoft) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 1) xRadius:8 yRadius:8] fill];
}
- (void)drawSeparatorInRect:(NSRect)r {}
@end
