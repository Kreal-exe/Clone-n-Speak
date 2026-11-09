#import "OVWaveformView.h"
#import "OVPlayerBar.h"
#import "OVDesign.h"
#import "OVLocale.h"

static const CGFloat kRegionBar = 3;   // solid strip at the top of a region: carries the 3:1 contrast, the fill only tints

@interface OVWaveformView ()
@property (nonatomic) NSInteger hoverIndex;   // index into regions, -1 = none
@property (nonatomic) id themeObserver;
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
- (void)setRegions:(NSArray *)r { _regions = [r copy] ?: @[]; _hoverIndex = -1; self.needsDisplay = YES; }
- (void)setDuration:(NSTimeInterval)d { _duration = (isfinite(d) && d > 0) ? d : 0; self.needsDisplay = YES; }
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
- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    [self seekToX:[self convertPoint:e.locationInWindow fromView:nil].x];
}
- (void)mouseDragged:(NSEvent *)e { [self seekToX:[self convertPoint:e.locationInWindow fromView:nil].x]; }

- (void)step:(NSTimeInterval)dt {
    if (self.duration <= 0) return;
    NSTimeInterval t = MAX(0, MIN(self.duration, self.position + dt));
    self.position = t;
    if (self.onSeek) self.onSeek(t);
}
- (void)keyDown:(NSEvent *)e {
    NSTimeInterval s = (e.modifierFlags & NSEventModifierFlagShift) ? 5 : 1;
    if (e.keyCode == 123) [self step:-s];
    else if (e.keyCode == 124) [self step:s];
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
@end
