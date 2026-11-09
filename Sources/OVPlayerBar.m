#import "OVPlayerBar.h"
#import "OVDesign.h"
#import "OVLocale.h"

NSString *OVFormatTime(NSTimeInterval t) {
    if (!isfinite(t) || t < 0) t = 0;
    long s = (long)floor(t);
    long h = s / 3600, m = (s / 60) % 60, sec = s % 60;
    return h > 0 ? [NSString stringWithFormat:@"%ld:%02ld:%02ld", h, m, sec] : [NSString stringWithFormat:@"%ld:%02ld", m, sec];
}

double OVScrubberValueForX(CGFloat x, CGFloat width) {
    if (!(width > 0) || !isfinite(x)) return 0;
    return MAX(0, MIN(1, x / width));
}

#pragma mark - Scrubber

static const CGFloat kTrackH = 4, kKnob = 12;

@interface OVScrubber : NSView
@property (nonatomic) double value;                       // 0…1
@property (nonatomic) NSTimeInterval position, duration;  // for the accessibility value
@property (nonatomic, copy) void (^onChange)(double value);      // click / drag
@property (nonatomic, copy) void (^onStep)(NSTimeInterval dt);   // keys, VoiceOver
@end

@implementation OVScrubber
- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        self.focusRingType = NSFocusRingTypeNone;
        self.accessibilityRole = NSAccessibilitySliderRole;
        self.accessibilityLabel = L(@"Playback position");
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self.heightAnchor constraintEqualToConstant:24].active = YES;
        [self setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSSize)intrinsicContentSize { return NSMakeSize(120, 24); }
- (void)setValue:(double)v {
    v = MAX(0, MIN(1, isfinite(v) ? v : 0));
    if (v == _value) return;
    _value = v;
    self.needsDisplay = YES;   // no animation: the knob follows the player, nothing eases
}
- (void)setPosition:(NSTimeInterval)p { _position = p; }
- (void)drawRect:(NSRect)dirty {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
        CGFloat x0 = kKnob / 2, tw = MAX(0, w - kKnob), cy = h / 2;
        CGFloat kx = x0 + tw * self.value;
        NSRect track = NSMakeRect(x0, cy - kTrackH / 2, tw, kTrackH);
        [OVColor(OVRoleBorder) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:track xRadius:kTrackH / 2 yRadius:kTrackH / 2] fill];
        NSRect fill = NSMakeRect(x0, track.origin.y, kx - x0, kTrackH);
        if (fill.size.width > 0) {
            [OVColor(OVRoleCTA) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:fill xRadius:kTrackH / 2 yRadius:kTrackH / 2] fill];
        }
        NSRect knob = NSMakeRect(kx - kKnob / 2, cy - kKnob / 2, kKnob, kKnob);
        [OVColor(OVRoleCTA) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:knob] fill];
        if (self.window.firstResponder == self && self.window.isKeyWindow) {
            NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:6 yRadius:6];
            ring.lineWidth = 2;
            [OVColor(OVRoleFocus) setStroke];
            [ring stroke];
        }
    }];
}
- (BOOL)becomeFirstResponder { self.needsDisplay = YES; return [super becomeFirstResponder]; }
- (BOOL)resignFirstResponder { self.needsDisplay = YES; return [super resignFirstResponder]; }

- (void)changeAtEvent:(NSEvent *)e {
    CGFloat x = [self convertPoint:e.locationInWindow fromView:nil].x - kKnob / 2;
    double v = OVScrubberValueForX(x, MAX(1, NSWidth(self.bounds) - kKnob));
    self.value = v;
    if (self.onChange) self.onChange(v);
}
- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; [self changeAtEvent:e]; }
- (void)mouseDragged:(NSEvent *)e { [self changeAtEvent:e]; }
- (void)keyDown:(NSEvent *)e {
    NSTimeInterval s = (e.modifierFlags & NSEventModifierFlagShift) ? 5 : 1;
    if (e.keyCode == 123) { if (self.onStep) self.onStep(-s); }
    else if (e.keyCode == 124) { if (self.onStep) self.onStep(s); }
    else [super keyDown:e];
}
- (BOOL)isAccessibilityElement { return YES; }
- (id)accessibilityValue {
    return [NSString stringWithFormat:L(@"%@ of %@"), OVFormatTime(self.position), OVFormatTime(self.duration)];
}
- (BOOL)accessibilityPerformIncrement { if (self.onStep) self.onStep(1); return YES; }
- (BOOL)accessibilityPerformDecrement { if (self.onStep) self.onStep(-1); return YES; }
@end

#pragma mark - Bar

@protocol OVPlayerSingleton
+ (id<OVPlaying>)shared;
@end

@interface OVPlayerBar ()
@property (nonatomic) NSButton *playButton;
@property (nonatomic) NSTextField *elapsed, *total;
@property (nonatomic) OVScrubber *scrub;
@property (nonatomic) OVSegmented *ab;
@property (nonatomic) BOOL originalSide;
@property (nonatomic) NSTimer *timer;
@end

@implementation OVPlayerBar

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) [self build];
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [super initWithCoder:c])) [self build];
    return self;
}

- (void)build {
    self.playButton = OVPlayButton(self, @selector(togglePlay:));
    self.elapsed = OVLabel(@"0:00", 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    self.total = OVLabel(@"0:00", 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    for (NSTextField *t in @[self.elapsed, self.total]) {
        t.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
        [t setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
        [t setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    }
    self.elapsed.alignment = NSTextAlignmentRight;
    self.scrub = [[OVScrubber alloc] initWithFrame:NSZeroRect];
    __weak OVPlayerBar *w = self;
    self.scrub.onChange = ^(double v) { [w seekFraction:v]; };
    self.scrub.onStep = ^(NSTimeInterval dt) { [w seekBy:dt]; };

    self.ab = [OVSegmented segmentedWithItems:@[@[L(@"Original"), @""], @[L(@"Result"), @""]]];
    self.ab.selectedIndex = 1;
    self.ab.target = self;
    self.ab.action = @selector(abChanged:);
    self.ab.hidden = YES;

    NSStackView *row = [NSStackView stackViewWithViews:@[self.playButton, self.elapsed, self.scrub, self.total, self.ab]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10;
    [row setCustomSpacing:16 afterView:self.total];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor], [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor], [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:@"OVPlayerDidChange" object:nil];
    [self refresh];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.timer invalidate];
}

- (id<OVPlaying>)thePlayer {
    id<OVPlaying> p = self.player;
    if (p) return p;
    Class c = NSClassFromString(@"OVPlayer");
    return [c respondsToSelector:@selector(shared)] ? [(Class<OVPlayerSingleton>)c shared] : nil;
}

#pragma mark State

- (BOOL)showsABSwitch { return self.originalPath.length > 0; }
- (BOOL)originalSelected { return self.showsABSwitch && self.originalSide; }
- (NSString *)activePath { return self.originalSelected ? self.originalPath : self.path; }
- (BOOL)isOurs:(NSString *)p { return p.length && ([p isEqualToString:self.path] || [p isEqualToString:self.originalPath]); }

- (void)setPath:(NSString *)p { _path = [p copy]; [self refresh]; }
- (void)setOriginalPath:(NSString *)p {
    _originalPath = [p copy];
    if (!_originalPath.length) self.originalSide = NO;
    [self refresh];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) { [self.timer invalidate]; self.timer = nil; }
    else [self refresh];
}

- (void)refresh {
    id<OVPlaying> p = [self thePlayer];
    BOOL here = p.currentPath.length && [p.currentPath isEqualToString:self.activePath];
    BOOL playing = here && p.playing;
    self.ab.hidden = !self.showsABSwitch;
    self.ab.selectedIndex = self.originalSelected ? 0 : 1;
    self.playButton.enabled = self.activePath.length > 0;
    self.playButton.image = [NSImage imageWithSystemSymbolName:playing ? @"pause.fill" : @"play.fill" accessibilityDescription:nil];
    self.playButton.accessibilityLabel = playing ? L(@"Pause") : L(@"Play");
    NSTimeInterval dur = here ? p.duration : 0, pos = here ? p.currentTime : 0;
    self.scrub.duration = dur;
    self.scrub.position = pos;
    self.scrub.value = dur > 0 ? pos / dur : 0;
    NSString *a = OVFormatTime(pos), *b = OVFormatTime(dur);
    BOOL textChanged = ![self.elapsed.stringValue isEqualToString:a] || ![self.total.stringValue isEqualToString:b];
    if (textChanged) {
        self.elapsed.stringValue = a;
        self.total.stringValue = b;
        NSAccessibilityPostNotification(self.scrub, NSAccessibilityValueChangedNotification);
    }
    if (playing && self.window && !self.timer) {
        __weak OVPlayerBar *w = self;
        self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [w refresh]; }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    } else if ((!playing || !self.window) && self.timer) {
        [self.timer invalidate];
        self.timer = nil;
    }
}

#pragma mark Actions

- (void)togglePlay:(id)sender {
    id<OVPlaying> p = [self thePlayer];
    NSString *path = self.activePath;
    if (!path.length || !p) return;
    if ([p.currentPath isEqualToString:path]) [p pauseOrResume];
    else [p play:path];
    [self refresh];
}

- (void)seekFraction:(double)v {
    id<OVPlaying> p = [self thePlayer];
    if (![p.currentPath isEqualToString:self.activePath] || p.duration <= 0) return;
    [p seek:v * p.duration];
    [self refresh];
}

- (void)seekBy:(NSTimeInterval)dt {
    id<OVPlaying> p = [self thePlayer];
    if (![p.currentPath isEqualToString:self.activePath] || p.duration <= 0) return;
    [p seek:MAX(0, MIN(p.duration, p.currentTime + dt))];
    [self refresh];
}

- (void)abChanged:(OVSegmented *)s { [self selectOriginal:s.selectedIndex == 0]; }

- (void)selectOriginal:(BOOL)original {
    original = original && self.showsABSwitch;
    if (original == self.originalSelected) { [self refresh]; return; }
    id<OVPlaying> p = [self thePlayer];
    NSString *old = self.activePath;
    BOOL loaded = old.length && [p.currentPath isEqualToString:old];
    NSTimeInterval pos = loaded ? p.currentTime : 0;
    BOOL wasPlaying = loaded && p.playing;
    self.originalSide = original;
    NSString *now = self.activePath;
    if (loaded && now.length) {
        [p play:now];
        if ([p.currentPath isEqualToString:now]) {
            // Positions are in seconds, not fractions; past the end of the new file means the end.
            NSTimeInterval d = p.duration;
            [p seek:d > 0 ? MIN(pos, d) : pos];
            if (!wasPlaying) [p pauseOrResume];
        }
    }
    [self refresh];
}

- (void)stopIfPlayingThis {
    id<OVPlaying> p = [self thePlayer];
    if ([self isOurs:p.currentPath]) [p stop];
    [self refresh];
}

- (NSView *)scrubber { return self.scrub; }

@end
