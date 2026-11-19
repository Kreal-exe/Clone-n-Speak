#import "OVWaveformView.h"
#import "OVPlayerBar.h"
#import "OVDesign.h"
#import "OVLocale.h"
#import "OVTrim.h"

static const CGFloat kHandleGrab = 12;   // width of the area that takes a handle, centred on the edge
static const NSTimeInterval kTrimAXStep = 0.1;   // VoiceOver increment / decrement of a handle
static const CGFloat kRegionBar = 3;   // solid strip at the top of a region: carries the 3:1 contrast, the fill only tints

/// One of the adjustable parts VoiceOver sees while trimming: the position, the trim start, the trim end.
typedef NS_ENUM(NSInteger, OVWaveAXKind) { OVWaveAXPosition, OVWaveAXTrimStart, OVWaveAXTrimEnd };

@class OVWaveformView;
@interface OVWaveAXElement : NSAccessibilityElement
@property (nonatomic, weak) OVWaveformView *view;
@property (nonatomic) OVWaveAXKind kind;
@end

@interface OVWaveformView ()
@property (nonatomic) NSInteger hoverIndex;   // index into regions, -1 = none
@property (nonatomic) id themeObserver;
@property (nonatomic) OVWaveAXKind dragging;  // handle being dragged (OVWaveAXPosition = none)
@property (nonatomic) NSArray<OVWaveAXElement *> *axElements;
- (BOOL)axAdjust:(OVWaveAXKind)kind by:(NSTimeInterval)dt;
- (NSRect)axRectOfKind:(OVWaveAXKind)kind;
- (id)axValueOfKind:(OVWaveAXKind)kind;
@end

@implementation OVWaveformView

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) [self setup];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [super initWithCoder:c])) [self setup];
    return self;
}
- (void)setup {
    _peaks = @[];
    _regions = @[];
    _hoverIndex = -1;
    self.focusRingType = NSFocusRingTypeNone;
    __weak OVWaveformView *w = self;
    self.themeObserver = [NSNotificationCenter.defaultCenter addObserverForName:OVThemeDidChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { w.needsDisplay = YES; }];
    self.accessibilityRole = NSAccessibilitySliderRole;
    self.accessibilityLabel = L(@"Audio waveform");
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self.themeObserver]; }

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(NSViewNoIntrinsicMetric, 80); }

- (void)setPeaks:(NSArray *)p { _peaks = [p copy] ?: @[]; self.needsDisplay = YES; }
- (void)setRegions:(NSArray *)r { _regions = [r copy] ?: @[]; self.hoverIndex = -1; self.needsDisplay = YES; }
- (void)setDuration:(NSTimeInterval)d {
    _duration = (isfinite(d) && d > 0) ? d : 0;
    if (_duration > 0) {   // a new file: the kept part starts as the whole of it unless the handles were set already
        if (_trimEnd <= 0 || _trimEnd > _duration) _trimEnd = _duration;
        _trimStart = OVClampTrimStart(_trimStart, _trimEnd, _duration, OVTrimMinKeep);
        _trimEnd = OVClampTrimEnd(_trimStart, _trimEnd, _duration, OVTrimMinKeep);
    }
    self.needsDisplay = YES;
    [self trimGeometryChanged];
}

#pragma mark Trim

- (void)trimGeometryChanged {
    self.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}
- (void)setTrimEnabled:(BOOL)on {
    if (on == _trimEnabled) return;
    _trimEnabled = on;
    if (on && _duration > 0 && _trimEnd <= 0) _trimEnd = _duration;
    [self trimGeometryChanged];
    NSAccessibilityPostNotification(self, NSAccessibilityLayoutChangedNotification);
}
- (void)setTrimStart:(NSTimeInterval)t { [self setTrimStart:t end:_trimEnd]; }
- (void)setTrimEnd:(NSTimeInterval)t { [self setTrimStart:_trimStart end:t]; }
- (void)setTrimStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    if (_duration > 0) {
        NSTimeInterval e = isfinite(end) ? MIN(end, _duration) : _duration, s;
        if (start != _trimStart && end == _trimEnd) {   // only the start moves: it stops against the end
            s = OVClampTrimStart(start, e, _duration, OVTrimMinKeep);
        } else {                                        // the end moves (or both): the end stops against the start
            s = MAX(0, MIN(isfinite(start) ? start : 0, _duration - OVTrimMinKeep));
            e = OVClampTrimEnd(s, e, _duration, OVTrimMinKeep);
        }
        start = s; end = e;
    } else { start = isfinite(start) ? MAX(0, start) : 0; end = isfinite(end) ? MAX(0, end) : 0; }
    if (start == _trimStart && end == _trimEnd) return;
    _trimStart = start; _trimEnd = end;
    [self trimGeometryChanged];
}
/// A change made by the user: tells the owner and VoiceOver.
- (void)userSetTrimStart:(NSTimeInterval)start end:(NSTimeInterval)end {
    NSTimeInterval s0 = _trimStart, e0 = _trimEnd;
    [self setTrimStart:start end:end];
    if (_trimStart == s0 && _trimEnd == e0) return;
    if (self.onTrimChange) self.onTrimChange(_trimStart, _trimEnd);
    for (OVWaveAXElement *el in self.axElements)
        if ((el.kind == OVWaveAXTrimStart && _trimStart != s0) || (el.kind == OVWaveAXTrimEnd && _trimEnd != e0))
            NSAccessibilityPostNotification(el, NSAccessibilityValueChangedNotification);
}
- (BOOL)axAdjust:(OVWaveAXKind)kind by:(NSTimeInterval)dt {
    if (kind == OVWaveAXPosition) { [self step:dt * 10]; return YES; }
    if (kind == OVWaveAXTrimStart) [self userSetTrimStart:_trimStart + dt end:_trimEnd];
    else [self userSetTrimStart:_trimStart end:_trimEnd + dt];
    return YES;
}

- (void)setPosition:(NSTimeInterval)p {
    p = isfinite(p) ? MAX(0, _duration > 0 ? MIN(p, _duration) : p) : 0;
    if (p == _position) return;
    _position = p;
    self.needsDisplay = YES;
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}

#pragma mark Drawing

static NSColor *RegionColor(NSString *kind, BOOL *hatch) {
    *hatch = NO;
    if ([kind isEqualToString:@"clipping"]) return OVColor(OVRoleErr);
    if ([kind isEqualToString:@"noise"] || [kind isEqualToString:@"hum"]) return OVColor(OVRoleWarn);
    *hatch = YES;   // pause, low_level and anything unknown
    return OVColor(OVRoleMuted);
}

- (CGFloat)xForTime:(NSTimeInterval)t { return _duration > 0 ? round(t / _duration * NSWidth(self.bounds)) : 0; }

- (void)drawRect:(NSRect)dirty {
    CGContextRef g = NSGraphicsContext.currentContext.CGContext;
    NSRect b = self.bounds;
    CGFloat w = NSWidth(b), h = NSHeight(b), mid = h / 2;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        // Regions go under the waveform: a tint plus a solid strip at the top.
        for (NSDictionary *r in self.regions) {
            if (self.duration <= 0) break;
            BOOL hatch;
            NSColor *c = RegionColor(r[@"kind"], &hatch);
            CGFloat x0 = [self xForTime:[r[@"start"] doubleValue]], x1 = MAX(x0 + 1, [self xForTime:[r[@"end"] doubleValue]]);
            x0 = MAX(0, MIN(x0, w)); x1 = MAX(0, MIN(x1, w));
            if (x1 <= x0) continue;
            CGRect rect = CGRectMake(x0, 0, x1 - x0, h);
            double sev = [r[@"severity"] respondsToSelector:@selector(doubleValue)] ? MAX(0, MIN(1, [r[@"severity"] doubleValue])) : 0.5;
            if (hatch) {
                CGContextSaveGState(g);
                CGContextClipToRect(g, rect);
                CGContextSetStrokeColorWithColor(g, [c colorWithAlphaComponent:0.45].CGColor);
                CGContextSetLineWidth(g, 1);
                for (CGFloat x = x0 - h; x < x1 + h; x += 6) {
                    CGContextMoveToPoint(g, x, h);
                    CGContextAddLineToPoint(g, x + h, 0);
                }
                CGContextStrokePath(g);
                CGContextRestoreGState(g);
            } else {
                CGContextSetFillColorWithColor(g, [c colorWithAlphaComponent:0.14 + 0.14 * sev].CGColor);
                CGContextFillRect(g, rect);
            }
            CGContextSetFillColorWithColor(g, c.CGColor);
            CGContextFillRect(g, CGRectMake(x0, 0, x1 - x0, kRegionBar));
        }

        // Peaks: one column per pixel, min/max of the peaks that fall into it.
        NSUInteger n = self.peaks.count;
        CGFloat playedX = [self xForTime:self.position];
        if (n && w >= 1) {
            CGColorRef played = OVColor(OVRoleAccent).CGColor, rest = OVColor(OVRoleMuted).CGColor;
            CGFloat amp = mid - 1;
            for (NSInteger x = 0; x < (NSInteger)w; x++) {
                NSUInteger i0 = (NSUInteger)floor((double)x / w * n), i1 = (NSUInteger)ceil((double)(x + 1) / w * n);
                i1 = MIN(MAX(i1, i0 + 1), n);
                double lo = 0, hi = 0;
                for (NSUInteger i = i0; i < i1; i++) {
                    NSArray *p = self.peaks[i];
                    if (p.count < 2) continue;
                    lo = MIN(lo, [p[0] doubleValue]);
                    hi = MAX(hi, [p[1] doubleValue]);
                }
                lo = MAX(-1, lo); hi = MIN(1, hi);
                CGFloat top = round(mid - hi * amp), bot = round(mid - lo * amp);
                if (bot - top < 1) { top = floor(mid); bot = top + 1; }   // silence stays a hairline
                CGContextSetFillColorWithColor(g, x < playedX ? played : rest);
                CGContextFillRect(g, CGRectMake(x, top, 1, bot - top));
            }
        }

        // Trim selection: what is cut away is dimmed, the handles sit on the edges of what stays.
        if (self.trimEnabled && self.duration > 0) {
            CGFloat xs = [self xForTime:self.trimStart], xe = [self xForTime:self.trimEnd];
            CGContextSetFillColorWithColor(g, [OVColor(OVRoleBackground) colorWithAlphaComponent:0.68].CGColor);
            CGContextFillRect(g, CGRectMake(0, 0, xs, h));
            CGContextFillRect(g, CGRectMake(xe, 0, w - xe, h));
            CGColorRef ink = OVColor(OVRoleText).CGColor, grip = OVColor(OVRoleBackground).CGColor;
            for (int i = 0; i < 2; i++) {
                CGFloat x = i == 0 ? xs : xe, bar = i == 0 ? MIN(x, w - 2) : MAX(x - 2, 0);
                CGContextSetFillColorWithColor(g, ink);
                CGContextFillRect(g, CGRectMake(bar, 0, 2, h));
                CGFloat kx = MAX(0, MIN(x - 4, w - 8)), ky = round(mid - 11);
                CGPathRef knob = CGPathCreateWithRoundedRect(CGRectMake(kx, ky, 8, 22), 3, 3, NULL);
                CGContextAddPath(g, knob);
                CGContextFillPath(g);
                CGPathRelease(knob);
                CGContextSetFillColorWithColor(g, grip);   // two grip lines
                CGContextFillRect(g, CGRectMake(kx + 2, ky + 7, 1, 8));
                CGContextFillRect(g, CGRectMake(kx + 5, ky + 7, 1, 8));
            }
        }

        // Playhead.
        if (self.duration > 0 && self.position > 0) {
            CGContextSetFillColorWithColor(g, OVColor(OVRoleCTA).CGColor);
            CGContextFillRect(g, CGRectMake(MIN(playedX, w - 2), 0, 2, h));
        }

        // Focus.
        if (self.window.firstResponder == self && self.window.isKeyWindow) {
            CGContextSetStrokeColorWithColor(g, OVColor(OVRoleFocus).CGColor);
            CGContextSetLineWidth(g, 2);
            CGContextStrokeRect(g, CGRectInset(b, 1, 1));
        }
    }];
}

- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }

#pragma mark Input

- (void)seekToX:(CGFloat)x {
    CGFloat w = NSWidth(self.bounds);
    if (w <= 0 || self.duration <= 0) return;
    NSTimeInterval t = MAX(0, MIN(1, x / w)) * self.duration;
    self.position = t;
    if (self.onSeek) self.onSeek(t);
}
/// The handle under x (within the grab area), or OVWaveAXPosition for none.
- (OVWaveAXKind)handleAtX:(CGFloat)x {
    if (!self.trimEnabled || self.duration <= 0) return OVWaveAXPosition;
    CGFloat ds = fabs(x - [self xForTime:self.trimStart]), de = fabs(x - [self xForTime:self.trimEnd]);
    BOOL s = ds <= kHandleGrab / 2, en = de <= kHandleGrab / 2;
    if (s && en) return ds < de || (ds == de && x < NSWidth(self.bounds) / 2) ? OVWaveAXTrimStart : OVWaveAXTrimEnd;
    return s ? OVWaveAXTrimStart : en ? OVWaveAXTrimEnd : OVWaveAXPosition;
}
- (NSTimeInterval)timeForX:(CGFloat)x {
    CGFloat w = NSWidth(self.bounds);
    return w > 0 ? MAX(0, MIN(1, x / w)) * self.duration : 0;
}
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    CGFloat x = [self convertPoint:e.locationInWindow fromView:nil].x;
    self.dragging = [self handleAtX:x];
    if (self.dragging == OVWaveAXPosition) { [self seekToX:x]; return; }
    [self mouseDragged:e];
}
- (void)mouseDragged:(NSEvent *)e {
    CGFloat x = [self convertPoint:e.locationInWindow fromView:nil].x;
    if (self.dragging == OVWaveAXTrimStart) { [NSCursor.resizeLeftRightCursor set]; [self userSetTrimStart:[self timeForX:x] end:self.trimEnd]; }
    else if (self.dragging == OVWaveAXTrimEnd) { [NSCursor.resizeLeftRightCursor set]; [self userSetTrimStart:self.trimStart end:[self timeForX:x]]; }
    else [self seekToX:x];
}
- (void)mouseUp:(NSEvent *)e { self.dragging = OVWaveAXPosition; }
- (void)resetCursorRects {
    [super resetCursorRects];
    if (!self.trimEnabled || self.duration <= 0) return;
    CGFloat h = NSHeight(self.bounds);
    for (NSNumber *k in @[@(OVWaveAXTrimStart), @(OVWaveAXTrimEnd)]) {
        CGFloat x = [self xForTime:k.integerValue == OVWaveAXTrimStart ? self.trimStart : self.trimEnd];
        [self addCursorRect:NSIntersectionRect(NSMakeRect(x - kHandleGrab / 2, 0, kHandleGrab, h), self.bounds) cursor:NSCursor.resizeLeftRightCursor];
    }
}
- (void)setFrameSize:(NSSize)s { [super setFrameSize:s]; [self trimGeometryChanged]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self.window invalidateCursorRectsForView:self]; }

- (void)step:(NSTimeInterval)dt {
    if (self.duration <= 0) return;
    NSTimeInterval t = MAX(0, MIN(self.duration, self.position + dt));
    self.position = t;
    if (self.onSeek) self.onSeek(t);
}
- (void)keyDown:(NSEvent *)e {
    NSTimeInterval s = (e.modifierFlags & NSEventModifierFlagShift) ? 5 : 1;
    NSString *ch = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption) ? nil : e.charactersIgnoringModifiers;
    if (e.keyCode == 123) [self step:-s];
    else if (e.keyCode == 124) [self step:s];
    else if (self.trimEnabled && self.duration > 0 && [ch isEqualToString:@"["]) [self userSetTrimStart:self.position end:self.trimEnd];
    else if (self.trimEnabled && self.duration > 0 && [ch isEqualToString:@"]"]) [self userSetTrimStart:self.trimStart end:self.position];
    else [super keyDown:e];
}

- (void)updateTrackingAreas {
    for (NSTrackingArea *a in self.trackingAreas) [self removeTrackingArea:a];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)setHoverIndex:(NSInteger)i {
    if (i == _hoverIndex) return;
    _hoverIndex = i;
    if (self.onRegionHover) self.onRegionHover(i >= 0 && i < (NSInteger)self.regions.count ? self.regions[i] : nil);
}
- (void)mouseMoved:(NSEvent *)e {
    CGFloat x = [self convertPoint:e.locationInWindow fromView:nil].x;
    NSInteger hit = -1;
    for (NSInteger i = 0; i < (NSInteger)self.regions.count && self.duration > 0; i++) {
        NSDictionary *r = self.regions[i];
        CGFloat a = [self xForTime:[r[@"start"] doubleValue]], z = MAX([self xForTime:[r[@"end"] doubleValue]], a + 1);
        if (x >= a && x <= z) hit = i;
    }
    self.hoverIndex = hit;
}
- (void)mouseExited:(NSEvent *)e { self.hoverIndex = -1; }

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityValue {
    return [NSString stringWithFormat:L(@"%@ of %@"), OVFormatTime(self.position), OVFormatTime(self.duration)];
}
- (BOOL)accessibilityPerformIncrement { [self step:1]; return YES; }
- (BOOL)accessibilityPerformDecrement { [self step:-1]; return YES; }

// While trimming the view is a group of three adjustable parts: the playhead and the two handles.
- (NSAccessibilityRole)accessibilityRole { return self.trimEnabled ? NSAccessibilityGroupRole : NSAccessibilitySliderRole; }
- (NSArray *)accessibilityChildren {
    if (!self.trimEnabled) return nil;
    if (!self.axElements) {
        NSMutableArray *els = [NSMutableArray array];
        for (OVWaveAXKind k = OVWaveAXPosition; k <= OVWaveAXTrimEnd; k++) {
            OVWaveAXElement *el = [OVWaveAXElement new];
            el.view = self; el.kind = k;
            [els addObject:el];
        }
        self.axElements = els;
    }
    return self.axElements;
}
- (NSRect)axRectOfKind:(OVWaveAXKind)kind {
    NSRect r = self.bounds;
    if (kind != OVWaveAXPosition && self.duration > 0) {
        CGFloat x = [self xForTime:kind == OVWaveAXTrimStart ? self.trimStart : self.trimEnd];
        r = NSIntersectionRect(NSMakeRect(x - kHandleGrab / 2, 0, kHandleGrab, NSHeight(self.bounds)), self.bounds);
    }
    return [self.window convertRectToScreen:[self convertRect:r toView:nil]];
}
- (id)axValueOfKind:(OVWaveAXKind)kind {
    return @(kind == OVWaveAXPosition ? self.position : kind == OVWaveAXTrimStart ? self.trimStart : self.trimEnd);
}
@end

@implementation OVWaveAXElement
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilitySliderRole; }
- (NSString *)accessibilityLabel {
    return self.kind == OVWaveAXTrimStart ? L(@"Trim start") : self.kind == OVWaveAXTrimEnd ? L(@"Trim end") : self.view.accessibilityLabel;
}
- (id)accessibilityParent { return self.view; }
- (NSRect)accessibilityFrame { return [self.view axRectOfKind:self.kind]; }
- (id)accessibilityValue { return [self.view axValueOfKind:self.kind]; }
- (NSString *)accessibilityValueDescription {
    if (self.kind == OVWaveAXPosition) return [self.view accessibilityValue];
    return [NSString stringWithFormat:L(@"%.1f seconds"), [[self.view axValueOfKind:self.kind] doubleValue]];
}
- (id)accessibilityMinValue { return @0; }
- (id)accessibilityMaxValue { return @(self.view.duration); }
- (BOOL)accessibilityPerformIncrement { return [self.view axAdjust:self.kind by:self.kind == OVWaveAXPosition ? 0.1 : kTrimAXStep]; }
- (BOOL)accessibilityPerformDecrement { return [self.view axAdjust:self.kind by:self.kind == OVWaveAXPosition ? -0.1 : -kTrimAXStep]; }
@end
