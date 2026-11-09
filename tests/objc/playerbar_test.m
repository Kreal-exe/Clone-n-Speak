// deps: OVPlayerBar.m OVWaveformView.m OVDesign.m OVUI.m OVTheme.m OVLocale.m
// Pure functions need only OVPlayerBar.m; drawing needs AppKit (the other files are its design-system dependencies).
#import <Cocoa/Cocoa.h>
#import "OVPlayerBar.h"
#import "OVWaveformView.h"
#import "OVTheme.h"

static int failures = 0, checks = 0;
#define CHECK(cond, ...) do { checks++; if (!(cond)) { failures++; printf("FAIL %s:%d  ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

#pragma mark - Helpers

static double Lum(NSColor *c) {
    c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    double v[3] = {c.redComponent, c.greenComponent, c.blueComponent};
    for (int i = 0; i < 3; i++) v[i] = v[i] <= 0.03928 ? v[i] / 12.92 : pow((v[i] + 0.055) / 1.055, 2.4);
    return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
}
static double Contrast(NSColor *a, NSColor *b) {
    double x = Lum(a), y = Lum(b);
    return (MAX(x, y) + 0.05) / (MIN(x, y) + 0.05);
}
static NSColor *Resolve(OVRole r, NSAppearance *ap) {
    __block NSColor *out;
    [ap performAsCurrentDrawingAppearance:^{ out = [OVColor(r) colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; }];
    return out;
}
static NSBitmapImageRep *Render(NSView *v, NSAppearance *ap) {
    v.appearance = ap;
    // Always 1x, whatever the screen: one pixel per point.
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)v.bounds.size.width
        pixelsHigh:(NSInteger)v.bounds.size.height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = ctx;
    [v displayRectIgnoringOpacity:v.bounds inContext:ctx];
    [NSGraphicsContext restoreGraphicsState];
    return rep;
}
static NSColor *Px(NSBitmapImageRep *r, NSInteger x, NSInteger y) {
    return [[r colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
/// Pixels of column x that were painted.
static int Painted(NSBitmapImageRep *r, NSInteger x) {
    int n = 0;
    for (NSInteger y = 0; y < r.pixelsHigh; y++) if (Px(r, x, y).alphaComponent > 0.5) n++;
    return n;
}
static NSArray *Peaks(NSInteger n, NSInteger loudAt) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) [a addObject:i == loudAt ? @[@-1.0, @1.0] : @[@0.0, @0.0]];
    return a;
}

#pragma mark - Fake player

@interface FakePlayer : NSObject <OVPlaying>
@property (nullable) NSString *currentPath;
@property BOOL playing;
@property NSTimeInterval currentTime, duration;
@property NSDictionary<NSString *, NSNumber *> *durations;   // path -> length
@property NSMutableArray<NSString *> *log;
@end
@implementation FakePlayer
- (instancetype)init { if ((self = [super init])) _log = [NSMutableArray array]; return self; }
- (void)play:(NSString *)p {
    [self.log addObject:[@"play:" stringByAppendingString:p]];
    self.currentPath = p; self.playing = YES; self.currentTime = 0; self.duration = self.durations[p].doubleValue;
}
- (void)pauseOrResume { [self.log addObject:@"pauseOrResume"]; self.playing = !self.playing; }
- (void)seek:(NSTimeInterval)t { [self.log addObject:[NSString stringWithFormat:@"seek:%g", t]]; self.currentTime = MAX(0, MIN(t, self.duration)); }
- (void)stop { [self.log addObject:@"stop"]; self.currentPath = nil; self.playing = NO; }
@end

#pragma mark - Tests

static void testFormatTime(void) {
    CHECK([OVFormatTime(75.4) isEqualToString:@"1:15"], "%s", OVFormatTime(75.4).UTF8String);
    CHECK([OVFormatTime(3725) isEqualToString:@"1:02:05"], "%s", OVFormatTime(3725).UTF8String);
    CHECK([OVFormatTime(-3) isEqualToString:@"0:00"], "negative");
    CHECK([OVFormatTime(NAN) isEqualToString:@"0:00"], "nan");
    CHECK([OVFormatTime(INFINITY) isEqualToString:@"0:00"], "inf");
    CHECK([OVFormatTime(59.99) isEqualToString:@"0:59"], "%s", OVFormatTime(59.99).UTF8String);
    CHECK([OVFormatTime(0) isEqualToString:@"0:00"], "zero");
    CHECK([OVFormatTime(3600) isEqualToString:@"1:00:00"], "hour");
}

static void testScrubberValue(void) {
    CHECK(OVScrubberValueForX(-5, 200) == 0, "left");
    CHECK(OVScrubberValueForX(205, 200) == 1, "right");
    CHECK(OVScrubberValueForX(100, 200) == 0.5, "middle");
    CHECK(OVScrubberValueForX(10, 0) == 0, "zero width");
}

static void testWaveformRendersPeaksAndRegions(void) {
    for (NSString *pal in @[@"applio", @"midnight"]) {
        [OVTheme setPaletteId:pal];
        for (NSAppearanceName an in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            NSAppearance *ap = [NSAppearance appearanceNamed:an];
            const char *tag = [NSString stringWithFormat:@"%@/%@", pal, an].UTF8String;
            OVWaveformView *w = [[OVWaveformView alloc] initWithFrame:NSMakeRect(0, 0, 400, 80)];
            w.duration = 4;

            w.peaks = Peaks(400, 200);
            NSBitmapImageRep *rep = Render(w, ap);
            CHECK(rep.pixelsWide == 400 && rep.pixelsHigh == 80, "%s: bitmap %ldx%ld (needs 1x)", tag, (long)rep.pixelsWide, (long)rep.pixelsHigh);
            int loud = Painted(rep, 200);
            CHECK(loud >= 72, "%s: full-scale peak paints %d of 80 px", tag, loud);
            int quiet = Painted(rep, 50);
            CHECK(quiet >= 1 && quiet <= 2, "%s: silent column beside the peak: %d px", tag, quiet);

            w.peaks = Peaks(400, -1);
            rep = Render(w, ap);
            int hair = Painted(rep, 200);
            CHECK(hair >= 1 && hair <= 2, "%s: silence is a hairline, got %d px", tag, hair);

            for (NSArray *c in @[@[@"clipping", @(OVRoleErr)], @[@"noise", @(OVRoleWarn)]]) {
                w.regions = @[@{@"start": @1, @"end": @2, @"kind": c[0], @"severity": @0.8}];
                rep = Render(w, ap);
                NSColor *bg = Resolve(OVRoleBackground, ap), *surface = Resolve(OVRoleSurface, ap);
                for (NSInteger x = 100; x < 200; x += 33) {
                    NSColor *p = Px(rep, x, 1);
                    CHECK(p.alphaComponent > 0.99, "%s %s: column %ld not painted", tag, [c[0] UTF8String], (long)x);
                    CHECK(Contrast(p, bg) >= 3.0 && Contrast(p, surface) >= 3.0, "%s %s: contrast %.2f / %.2f", tag, [c[0] UTF8String],
                          Contrast(p, bg), Contrast(p, surface));
                }
                CHECK(Px(rep, 99, 1).alphaComponent < 0.1 && Px(rep, 201, 1).alphaComponent < 0.1, "%s %s: region bleeds outside 100–200", tag, [c[0] UTF8String]);
            }

            w.regions = @[@{@"start": @1, @"end": @2, @"kind": @"pause", @"severity": @0.5}];
            rep = Render(w, ap);
            int hatched = 0;
            for (NSInteger x = 100; x < 200; x++) hatched += Px(rep, x, 10).alphaComponent > 0.1;
            CHECK(hatched > 5 && hatched < 100, "%s: pause region should be hatched, %d px painted", tag, hatched);
        }
    }
}

static void testWaveformSeek(void) {
    OVWaveformView *w = [[OVWaveformView alloc] initWithFrame:NSMakeRect(0, 0, 400, 80)];
    w.duration = 10;
    __block NSTimeInterval got = -1;
    w.onSeek = ^(NSTimeInterval t) { got = t; };
    w.position = 3;
    NSEvent *right = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                    characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:124];
    [w keyDown:right];
    CHECK(fabs(got - 4) < 1e-9, "right = +1 s, got %g", got);
    NSEvent *shiftLeft = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagShift timestamp:0 windowNumber:0
                                           context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:123];
    [w keyDown:shiftLeft];
    CHECK(got == 0, "shift+left = -5 s clamped at 0, got %g", got);
}

static void testABSwitchKeepsPosition(void) {
    for (int playing = 1; playing >= 0; playing--) {
        FakePlayer *fp = [FakePlayer new];
        fp.durations = @{@"/r.wav": @30, @"/o.wav": @28};
        OVPlayerBar *bar = [[OVPlayerBar alloc] initWithFrame:NSMakeRect(0, 0, 500, 32)];
        bar.player = fp;
        bar.path = @"/r.wav";
        bar.originalPath = @"/o.wav";
        CHECK(bar.showsABSwitch && !bar.originalSelected, "A/B shown, Result first");
        [fp play:@"/r.wav"];
        fp.currentTime = 12.5;
        fp.playing = playing;
        [fp.log removeAllObjects];
        [bar selectOriginal:YES];
        NSArray *want = playing ? @[@"play:/o.wav", @"seek:12.5"] : @[@"play:/o.wav", @"seek:12.5", @"pauseOrResume"];
        CHECK([fp.log isEqualToArray:want], "playing=%d log %s", playing, fp.log.description.UTF8String);
        CHECK([fp.currentPath isEqualToString:@"/o.wav"] && fp.playing == playing && fp.currentTime == 12.5, "state after switch");
        CHECK(bar.originalSelected, "original selected");

        // The other file is shorter: past its end means its end.
        [bar selectOriginal:NO];
        fp.durations = @{@"/r.wav": @10, @"/o.wav": @28};
        [fp.log removeAllObjects];
        [bar selectOriginal:YES];
        CHECK(fp.currentTime == 10 || fp.currentTime == 12.5, "position kept in seconds (%g)", fp.currentTime);
    }
    // Nothing loaded: switching only changes the side.
    FakePlayer *idle = [FakePlayer new];
    OVPlayerBar *bar = [[OVPlayerBar alloc] initWithFrame:NSMakeRect(0, 0, 500, 32)];
    bar.player = idle; bar.path = @"/r.wav"; bar.originalPath = @"/o.wav";
    [bar selectOriginal:YES];
    CHECK(idle.log.count == 0 && bar.originalSelected, "idle switch plays nothing");
    bar.originalPath = nil;
    CHECK(!bar.showsABSwitch && !bar.originalSelected, "no original, no switch");
}

static void testAccessibility(void) {
    FakePlayer *fp = [FakePlayer new];
    fp.durations = @{@"/r.wav": @34};
    OVPlayerBar *bar = [[OVPlayerBar alloc] initWithFrame:NSMakeRect(0, 0, 500, 32)];
    bar.player = fp; bar.path = @"/r.wav";
    [fp play:@"/r.wav"];
    fp.currentTime = 12;
    [bar refresh];
    CHECK([bar.scrubber.accessibilityRole isEqualToString:NSAccessibilitySliderRole], "role");
    NSString *v = [bar.scrubber accessibilityValue];
    CHECK([v isKindOfClass:NSString.class] && v.length > 0, "value");
    CHECK([v isEqualToString:@"0:12 of 0:34"], "value text: %s", v.UTF8String);
    [fp.log removeAllObjects];
    CHECK([bar.scrubber accessibilityPerformIncrement], "increment");
    CHECK([fp.log.lastObject isEqualToString:@"seek:13"], "increment seeks +1 s: %s", fp.log.description.UTF8String);
    [bar.scrubber accessibilityPerformDecrement];
    CHECK([fp.log.lastObject isEqualToString:@"seek:12"], "decrement seeks -1 s: %s", fp.log.description.UTF8String);
    OVWaveformView *w = [OVWaveformView new];
    CHECK([w.accessibilityRole isEqualToString:NSAccessibilitySliderRole], "waveform role");
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        // OVTheme reads themes.json from the main bundle, which for a plain executable is its own directory.
        NSString *src = [[[@__FILE__ stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../Resources/themes.json"] stringByStandardizingPath];
        NSString *dst = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"themes.json"];
        [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
        NSError *cpErr = nil;
        if (![NSFileManager.defaultManager copyItemAtPath:src toPath:dst error:&cpErr]) { printf("cannot copy themes.json: %s\n", cpErr.description.UTF8String); return 2; }
        testFormatTime();
        testScrubberValue();
        testWaveformRendersPeaksAndRegions();
        testWaveformSeek();
        testABSwitchKeepsPosition();
        testAccessibility();
        printf("%d checks, %d failures\n", checks, failures);
    }
    return failures ? 1 : 0;
}

// OVDesign.m reads the RAM size from OVSettings (OVStore.m, which pulls in the whole app); the player bar never reaches it.
@interface OVSettings : NSObject
+ (double)physicalMemoryGB;
@end
@implementation OVSettings
+ (double)physicalMemoryGB { return 16; }
@end
