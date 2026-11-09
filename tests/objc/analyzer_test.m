// deps: OVAnalyzerView.m OVTheme.m OVDesign.m OVUI.m OVLocale.m
#import <Cocoa/Cocoa.h>
#import "OVAnalyzerView.h"
#import "OVTheme.h"

// OVDesign.m asks OVSettings for the memory size; the real class drags in the whole store, so the test supplies a stand-in.
@interface OVSettings : NSObject @end
@implementation OVSettings
+ (double)physicalMemoryGB { return 16; }
@end

static int gFails = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFails++; printf("FAIL %s:%d  ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSAppearance *Ap(BOOL dark) { return [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]; }

static void Rgb(NSColor *c, double o[3]) {
    NSColor *s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    o[0] = s.redComponent; o[1] = s.greenComponent; o[2] = s.blueComponent;
}
static double Lum(NSColor *c) {
    double rgb[3]; Rgb(c, rgb);
    for (int i = 0; i < 3; i++) rgb[i] = rgb[i] <= 0.03928 ? rgb[i] / 12.92 : pow((rgb[i] + 0.055) / 1.055, 2.4);
    return 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
}
static double Contrast(NSColor *a, NSColor *b) {
    double x = Lum(a), y = Lum(b);
    return (MAX(x, y) + 0.05) / (MIN(x, y) + 0.05);
}
static NSColor *LUT(uint8_t v, BOOL dark) {
    __block NSColor *c;
    [Ap(dark) performAsCurrentDrawingAppearance:^{ c = OVSpectrogramColor(v); }];
    return c;
}

static void testLUTEndsContrast(void) {
    NSString *saved = OVTheme.paletteId;
    NSArray *palettes = OVTheme.palettes;
    CHECK(palettes.count == 8, "expected 8 palettes, got %lu", (unsigned long)palettes.count);
    for (NSDictionary *p in palettes) {
        [OVTheme setPaletteId:p[@"id"]];
        for (int dark = 0; dark < 2; dark++) {
            double cr = Contrast(LUT(0, dark), LUT(255, dark));
            CHECK(cr >= 3.0, "%s %s contrast %.2f", [p[@"id"] UTF8String], dark ? "dark" : "light", cr);
            if (dark) {
                double prev = -1;
                for (int v = 0; v < 256; v++) {
                    double l = Lum(LUT((uint8_t)v, YES));
                    CHECK(l >= prev - 1e-9, "%s dark luminance drops at %d (%.4f < %.4f)", [p[@"id"] UTF8String], v, l, prev);
                    prev = l;
                }
            }
        }
    }
    [OVTheme setPaletteId:saved];
}

static void testImageSizeAndPixels(void) {
    [OVTheme setPaletteId:@"applio"];
    const uint8_t raw[12] = {0, 50, 100, 255,      // row 0: lowest frequency
                             10, 60, 110, 200,
                             20, 70, 120, 150};
    NSData *d = [NSData dataWithBytes:raw length:12];
    for (int dark = 0; dark < 2; dark++) {
        CGImageRef img = OVSpectrogramImage(d, 4, 3, dark);
        CHECK(img != NULL, "image is NULL");
        if (!img) continue;
        CHECK(CGImageGetWidth(img) == 4 && CGImageGetHeight(img) == 3, "size %zux%zu", CGImageGetWidth(img), CGImageGetHeight(img));
        CFDataRef raw8 = CGDataProviderCopyData(CGImageGetDataProvider(img));
        const uint8_t *bytes = CFDataGetBytePtr(raw8);
        size_t bpr = CGImageGetBytesPerRow(img);
        for (int r = 0; r < 3; r++) for (int c = 0; c < 4; c++) {
            const uint8_t *px = bytes + (2 - r) * bpr + c * 4;   // image row 0 is the top: data row 0 must be the bottom row
            double got[3] = {px[0] / 255.0, px[1] / 255.0, px[2] / 255.0}, want[3];
            Rgb(LUT(raw[r * 4 + c], dark), want);
            for (int i = 0; i < 3; i++)
                CHECK(fabs(got[i] - want[i]) <= 1.5 / 255, "dark=%d (%d,%d) ch%d got %.4f want %.4f", dark, c, r, i, got[i], want[i]);
        }
        CFRelease(raw8);
        CGImageRelease(img);
    }
    CHECK(OVSpectrogramImage(d, 5, 3, NO) == NULL, "mismatched size must give NULL");
}

static NSDictionary *MakeResult(NSString *dir, NSInteger cols, NSInteger rows, NSInteger fileBytes, NSArray *f0) {
    NSString *path = [dir stringByAppendingPathComponent:@"spectrogram.u8"];
    NSMutableData *d = [NSMutableData dataWithLength:fileBytes];
    uint8_t *p = d.mutableBytes;
    for (NSInteger i = 0; i < fileBytes; i++) p[i] = (uint8_t)(i % 256);
    [d writeToFile:path atomically:YES];
    NSMutableArray *hz = [NSMutableArray array];
    for (NSInteger r = 0; r < rows; r++) [hz addObject:@(100.0 * pow(80, (double)r / MAX(rows - 1, 1)))];
    return @{@"seconds": @(cols * 0.1), @"sr": @16000, @"channels": @1,
             @"spectrogram": @{@"path": path, @"cols": @(cols), @"rows": @(rows), @"fmin": @100, @"fmax": hz.lastObject,
                               @"db_floor": @-90, @"db_ceil": @0, @"row_hz": hz, @"col_s": @0.1},
             @"f0": @{@"hop_s": @0.1, @"values": f0, @"median_hz": @150},
             @"centroid": @{@"hop_s": @0.1, @"values_hz": @[@500, @600, @700, @800]}};
}

static NSString *TempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void testLoadRejectsBadSize(void) {
    NSString *dir = TempDir();
    OVAnalyzerView *v = [[OVAnalyzerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    NSDictionary *good = MakeResult(dir, 8, 4, 32, @[@120, @130, @0, @140, @150, @0, @0, @160]);
    CHECK([v loadResult:good error:nil], "good file rejected");
    NSString *before = v.accessibilityValue;
    NSString *dir2 = TempDir();
    NSDictionary *bad = MakeResult(dir2, 8, 4, 31, @[]);
    NSError *err = nil;
    CHECK(![v loadResult:bad error:&err], "bad size accepted");
    CHECK(err && err.localizedDescription.length, "no error reported");
    CHECK([v.accessibilityValue isEqual:before], "the view changed after a failed load");
    [v display];   // must not crash
    NSMutableDictionary *noPath = [good mutableCopy];
    noPath[@"spectrogram"] = @{@"cols": @8, @"rows": @4};
    CHECK(![v loadResult:noPath error:nil], "result without a path accepted");
}

static int CountMoves(CGPathRef p) {
    __block int n = 0;
    CGPathApplyWithBlock(p, ^(const CGPathElement *e) { if (e->type == kCGPathElementMoveToPoint) n++; });
    return n;
}

static void testPitchGapsAtZero(void) {
    NSString *dir = TempDir();
    OVAnalyzerView *v = [[OVAnalyzerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    NSDictionary *r = MakeResult(dir, 8, 4, 32, @[@120, @130, @0, @140, @150, @0, @0, @160]);
    CHECK([v loadResult:r error:nil], "load failed");
    CGPathRef p = [v copyPitchPath];
    CHECK(p != NULL, "no path");
    if (p) { CHECK(CountMoves(p) == 3, "expected 3 runs, got %d", CountMoves(p)); CGPathRelease(p); }
    OVAnalyzerView *e = [[OVAnalyzerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    NSDictionary *none = MakeResult(dir, 8, 4, 32, @[@0, @0, @0]);
    [e loadResult:none error:nil];
    CHECK([e copyPitchPath] == NULL, "all-zero pitch must give no path");
}

static void testThemeChangeRedraws(void) {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 200) styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered defer:NO];
    OVAnalyzerView *v = [[OVAnalyzerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    [w.contentView addSubview:v];
    NSString *saved = OVTheme.paletteId;
    [OVTheme setPaletteId:@"applio"];
    double a[3]; Rgb(LUT(255, YES), a);
    v.needsDisplay = NO;
    [OVTheme setPaletteId:@"emerald"];   // posts OVThemeDidChangeNotification
    CHECK(v.needsDisplay, "needsDisplay not set after the theme changed");
    double b[3]; Rgb(LUT(255, YES), b);
    CHECK(fabs(a[0] - b[0]) + fabs(a[1] - b[1]) + fabs(a[2] - b[2]) > 0.01, "LUT(255) did not change between applio and emerald");
    [OVTheme setPaletteId:saved];
}

static void testAccessibilitySummary(void) {
    OVAnalyzerView *v = [[OVAnalyzerView alloc] initWithFrame:NSMakeRect(0, 0, 400, 200)];
    CHECK(((NSString *)v.accessibilityValue).length == 0, "value must be empty before loading");
    NSDictionary *r = MakeResult(TempDir(), 8, 4, 32, @[@120, @130, @0, @140]);
    [v loadResult:r error:nil];
    v.position = 0.3;
    NSString *s = v.accessibilityValue;
    CHECK(s.length > 0 && [s containsString:@"0:00"] && [s containsString:@"150"], "summary: %s", s.UTF8String);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSProcessInfo.processInfo.processName];
        testLUTEndsContrast();
        testImageSizeAndPixels();
        testLoadRejectsBadSize();
        testPitchGapsAtZero();
        testThemeChangeRedraws();
        testAccessibilitySummary();
        printf(gFails ? "%d FAILED\n" : "all passed\n", gFails);
    }
    return gFails ? 1 : 0;
}
