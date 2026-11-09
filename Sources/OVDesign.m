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
    NSArray *texts = s.length ? @[title, OVLabel(s, 12, NSFontWeightRegular, C(OVRoleMuted))] : @[title];
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
@property NSArray<NSString *> *titles, *symbols;
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
    NSMutableArray *t = [NSMutableArray array], *y = [NSMutableArray array];
    for (NSArray *it in items) { [t addObject:it[0]]; [y addObject:it.count > 1 ? it[1] : @""]; }
    s.titles = t;
    s.symbols = y;
    [s setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return s;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (NSFont *)segFont { return [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]; }
- (CGFloat)widthOfSegment:(NSInteger)i {
    CGFloat w = ceil([self.titles[i] sizeWithAttributes:@{NSFontAttributeName: self.segFont}].width) + 28;
    return w + ([self.symbols[i] length] ? 20 : 0);
}
- (NSRect)rectOfSegment:(NSInteger)i {
    CGFloat x = kSegPad;
    for (NSInteger k = 0; k < i; k++) x += [self widthOfSegment:k];
    return NSMakeRect(x, kSegPad, [self widthOfSegment:i], kSegH);
}
- (NSSize)intrinsicContentSize {
    NSRect last = [self rectOfSegment:self.titles.count - 1];
    return NSMakeSize(NSMaxX(last) + kSegPad, kSegH + 2 * kSegPad);
}
- (void)setSelectedIndex:(NSInteger)i {
    if (i < 0 || i >= (NSInteger)self.titles.count || i == _selectedIndex) return;
    _selectedIndex = i;
    self.needsDisplay = YES;
    for (id c in self.accessibilityChildren) NSAccessibilityPostNotification(c, NSAccessibilityValueChangedNotification);
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
        CGFloat iw = g ? g.size.width + 6 : 0;
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
- (id)accessibilityValue { return self.titles[self.selectedIndex]; }
- (NSArray *)accessibilityChildren {
    NSMutableArray *out = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.titles.count; i++) {
        OVSegmentA11y *e = [OVSegmentA11y accessibilityElementWithRole:NSAccessibilityRadioButtonRole
                                                                 frame:NSZeroRect label:self.titles[i] parent:self];
        e.owner = self;
        e.index = i;
        if (self.window) e.accessibilityFrame = [self.window convertRectToScreen:[self convertRect:[self rectOfSegment:i] toView:nil]];
        [out addObject:e];
    }
    return out;
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

NSView *OVBadge(NSString *text, OVRole tone) {
    BOOL muted = tone == OVRoleMuted;
    NSColor *tc = C(tone);
    NSTextField *l = OVLabel(text, 12, NSFontWeightMedium, tc);
    OVBoxView *b = [OVBoxView boxWithFill:muted ? nil : [tc colorWithAlphaComponent:0.12]
                                   border:muted ? C(OVRoleBorder) : [tc colorWithAlphaComponent:0.45] radius:10];
    [b addSubview:l];
    OVPin(l, b, NSEdgeInsetsMake(3, 9, 3, 9));
    [b setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [b setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return b;
}

NSView *OVProBadge(void) {
    NSView *b = OVBadge(L(@"16 GB"), OVRoleWarn);
    b.toolTip = L(@"This feature is meant for Macs with 16 GB of memory or more. On a Mac with less it may run out of memory.");
    return b;
}

BOOL OVConfirmProRun(NSWindow *w) {
    double gb = [OVSettings physicalMemoryGB];
    if (gb >= 16) return YES;
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"This may run out of memory");
    a.informativeText = [NSString stringWithFormat:L(@"This feature is meant for Macs with 16 GB of memory or more. This Mac has %.0f GB, so it may run out of memory or slow down a lot."), gb];
    [a addButtonWithTitle:L(@"Run anyway")];
    [a addButtonWithTitle:L(@"Cancel")];
    return [a runModal] == NSAlertFirstButtonReturn;
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
