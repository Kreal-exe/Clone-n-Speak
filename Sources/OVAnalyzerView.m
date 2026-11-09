#import "OVAnalyzerView.h"
#import "OVDesign.h"
#import "OVLocale.h"

NSErrorDomain const OVAnalyzerErrorDomain = @"OVAnalyzerError";

#pragma mark - Color lookup

typedef struct { uint8_t r, g, b; } RGB8;

static NSMutableDictionary<NSString *, NSData *> *gLUTs;   // "palette|dark" -> 256 x RGB8
static NSMutableDictionary<NSString *, NSArray<NSColor *> *> *gLUTColors;

static void ResolveRGB(OVRole role, NSAppearance *ap, CGFloat out[4]) {
    __block NSColor *c = nil;
    [ap performAsCurrentDrawingAppearance:^{ c = [OVColor(role) colorUsingColorSpace:NSColorSpace.sRGBColorSpace]; }];
    out[0] = c.redComponent; out[1] = c.greenComponent; out[2] = c.blueComponent; out[3] = c.alphaComponent;
}

static void BuildLUT(BOOL dark, NSData **bytes, NSArray<NSColor *> **colors) {
    @synchronized (NSApplication.class) {
        NSString *key = [NSString stringWithFormat:@"%@|%d", OVTheme.paletteId, dark];
        if (!gLUTs) {
            gLUTs = [NSMutableDictionary dictionary];
            gLUTColors = [NSMutableDictionary dictionary];
            [NSNotificationCenter.defaultCenter addObserverForName:OVThemeDidChangeNotification object:nil queue:nil
                                                        usingBlock:^(NSNotification *n) {
                @synchronized (NSApplication.class) { [gLUTs removeAllObjects]; [gLUTColors removeAllObjects]; }
            }];
        }
        if (gLUTs[key]) { *bytes = gLUTs[key]; *colors = gLUTColors[key]; return; }
        NSAppearance *ap = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        CGFloat bg[4], soft[4], acc[4], txt[4];
        ResolveRGB(OVRoleBackground, ap, bg); ResolveRGB(OVRoleAccentSoft, ap, soft);
        ResolveRGB(OVRoleAccent, ap, acc); ResolveRGB(OVRoleText, ap, txt);
        // accentSoft is usually translucent: flatten it over the background.
        for (int i = 0; i < 3; i++) soft[i] = soft[i] * soft[3] + bg[i] * (1 - soft[3]);
        const CGFloat *stops[4] = {bg, soft, acc, txt};
        NSMutableData *d = [NSMutableData dataWithLength:256 * sizeof(RGB8)];
        RGB8 *p = d.mutableBytes;
        NSMutableArray *cs = [NSMutableArray arrayWithCapacity:256];
        for (int v = 0; v < 256; v++) {
            CGFloat pos = v / 255.0 * 3;
            int s = MIN((int)floor(pos), 2);
            CGFloat f = pos - s;
            CGFloat ch[3];
            for (int i = 0; i < 3; i++) ch[i] = stops[s][i] + (stops[s + 1][i] - stops[s][i]) * f;
            p[v] = (RGB8){(uint8_t)lround(ch[0] * 255), (uint8_t)lround(ch[1] * 255), (uint8_t)lround(ch[2] * 255)};
            [cs addObject:[NSColor colorWithSRGBRed:p[v].r / 255.0 green:p[v].g / 255.0 blue:p[v].b / 255.0 alpha:1]];
        }
        gLUTs[key] = d; gLUTColors[key] = cs;
        *bytes = d; *colors = cs;
    }
}

static BOOL CurrentIsDark(void) {
    NSAppearance *a = NSAppearance.currentDrawingAppearance ?: NSApp.effectiveAppearance;
    return [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}

NSColor *OVSpectrogramColor(uint8_t v) {
    NSData *b; NSArray<NSColor *> *c;
    BuildLUT(CurrentIsDark(), &b, &c);
    return c[v];
}

CGImageRef OVSpectrogramImage(NSData *u8, NSInteger cols, NSInteger rows, BOOL dark) {
    if (cols <= 0 || rows <= 0 || (NSInteger)u8.length != cols * rows) return NULL;
    NSData *lut; NSArray *unused;
    BuildLUT(dark, &lut, &unused);
    const RGB8 *map = lut.bytes;
    const uint8_t *src = u8.bytes;
    NSMutableData *px = [NSMutableData dataWithLength:(NSUInteger)(cols * rows * 4)];
    uint8_t *dst = px.mutableBytes;
    for (NSInteger r = 0; r < rows; r++) {
        uint8_t *line = dst + (rows - 1 - r) * cols * 4;   // data row 0 (lowest frequency) goes to the bottom
        for (NSInteger c = 0; c < cols; c++) {
            RGB8 k = map[src[r * cols + c]];
            line[c * 4] = k.r; line[c * 4 + 1] = k.g; line[c * 4 + 2] = k.b; line[c * 4 + 3] = 255;
        }
    }
    CGDataProviderRef prov = CGDataProviderCreateWithCFData((__bridge CFDataRef)px);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef img = CGImageCreate(cols, rows, 8, 32, cols * 4, cs, kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                   prov, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(prov);
    return img;
}

#pragma mark - View

static NSString *ClockString(NSTimeInterval t) {
    int s = (int)MAX(0, floor(t + 0.0005));
    return s >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60]
                     : [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

static NSString *DbString(int db) { return [NSString stringWithFormat:@"%@%d", db < 0 ? @"−" : @"", abs(db)]; }

static const CGFloat kLeft = 48, kBottom = 22, kTop = 6, kRight = 8;

@implementation OVAnalyzerView {
    NSData *_u8;
    NSInteger _cols, _rows;
    NSArray<NSNumber *> *_rowHz, *_f0, *_centroid;
    double _colS, _f0Hop, _centroidHop, _dbFloor, _dbCeil, _seconds;
    NSNumber *_median;
    CGImageRef _image;
    BOOL _imageDark;
    NSString *_imagePalette;
    CGPoint _hover;
    BOOL _hovering;
}

- (instancetype)initWithFrame:(NSRect)f {
    if ((self = [super initWithFrame:f])) {
        _showsPitch = YES;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(themeChanged:) name:OVThemeDidChangeNotification object:nil];
        [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
            options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
              owner:self userInfo:nil]];
        self.accessibilityRole = NSAccessibilityImageRole;
        self.accessibilityLabel = L(@"Spectrogram");
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_image) CGImageRelease(_image);
}

- (BOOL)isAccessibilityElement { return YES; }

- (void)themeChanged:(NSNotification *)n { [self dropImage]; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { [self dropImage]; self.needsDisplay = YES; }
- (void)dropImage { if (_image) { CGImageRelease(_image); _image = NULL; } }

- (void)setShowsPitch:(BOOL)v { _showsPitch = v; self.needsDisplay = YES; }
- (void)setShowsCentroid:(BOOL)v { _showsCentroid = v; self.needsDisplay = YES; }
- (void)setPosition:(NSTimeInterval)p {
    NSInteger oldCol = _u8 ? [self columnForTime:_position] : -1;
    NSRect r = [self plotRect];
    CGFloat oldX = [self xForTime:_position inRect:r];
    _position = p;
    if (_u8 && [self columnForTime:p] == oldCol) return;   // the playhead stays in the same column: nothing to redraw or announce
    CGFloat newX = [self xForTime:p inRect:r];
    [self setNeedsDisplayInRect:NSMakeRect(oldX - 2, NSMinY(r), 4, r.size.height)];
    [self setNeedsDisplayInRect:NSMakeRect(newX - 2, NSMinY(r), 4, r.size.height)];
    NSAccessibilityPostNotification(self, NSAccessibilityValueChangedNotification);
}

#pragma mark Keyboard and VoiceOver seek

- (BOOL)acceptsFirstResponder { return _u8 != nil; }
- (BOOL)needsPanelToBecomeKey { return NO; }
- (NSRect)focusRingMaskBounds { return [self plotRect]; }
- (void)drawFocusRingMask { NSRectFill([self plotRect]); }
- (void)nudge:(double)dt {
    if (!_u8 || !self.onSeek) return;
    self.onSeek(MIN(MAX(_position + dt, 0), [self duration]));
}
- (BOOL)accessibilityPerformIncrement { [self nudge:1]; return _u8 != nil; }
- (BOOL)accessibilityPerformDecrement { [self nudge:-1]; return _u8 != nil; }
- (void)keyDown:(NSEvent *)e {
    NSString *k = e.charactersIgnoringModifiers;
    if (!k.length) { [super keyDown:e]; return; }
    unichar c = [k characterAtIndex:0];
    if (c == NSRightArrowFunctionKey) [self nudge:1];
    else if (c == NSLeftArrowFunctionKey) [self nudge:-1];
    else [super keyDown:e];
}

#pragma mark Loading

static NSError *Err(NSString *why) {
    return [NSError errorWithDomain:OVAnalyzerErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: why}];
}

- (BOOL)loadResult:(NSDictionary *)result error:(NSError **)error {
    NSDictionary *sp = [result[@"spectrogram"] isKindOfClass:NSDictionary.class] ? result[@"spectrogram"] : nil;
    NSString *path = [sp[@"path"] isKindOfClass:NSString.class] ? sp[@"path"] : nil;
    NSInteger cols = [sp[@"cols"] integerValue], rows = [sp[@"rows"] integerValue];
    NSArray *rowHz = [sp[@"row_hz"] isKindOfClass:NSArray.class] ? sp[@"row_hz"] : nil;
    if (!path || cols <= 0 || rows <= 0 || rowHz.count != (NSUInteger)rows) {
        if (error) *error = Err(L(@"The analysis result is incomplete."));
        return NO;
    }
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || (NSInteger)data.length != cols * rows) {
        if (error) *error = Err(L(@"The spectrogram file is missing or has the wrong size."));
        return NO;
    }
    _u8 = data; _cols = cols; _rows = rows; _rowHz = rowHz;
    _colS = [sp[@"col_s"] doubleValue];
    _dbFloor = sp[@"db_floor"] ? [sp[@"db_floor"] doubleValue] : -90;
    _dbCeil = sp[@"db_ceil"] ? [sp[@"db_ceil"] doubleValue] : 0;
    _seconds = [result[@"seconds"] doubleValue];
    if (_seconds <= 0) _seconds = _colS * cols;
    NSDictionary *f0 = [result[@"f0"] isKindOfClass:NSDictionary.class] ? result[@"f0"] : nil;
    _f0 = [f0[@"values"] isKindOfClass:NSArray.class] ? f0[@"values"] : @[];
    _f0Hop = [f0[@"hop_s"] doubleValue];
    _median = [f0[@"median_hz"] isKindOfClass:NSNumber.class] ? f0[@"median_hz"] : nil;
    NSDictionary *ce = [result[@"centroid"] isKindOfClass:NSDictionary.class] ? result[@"centroid"] : nil;
    _centroid = [ce[@"values_hz"] isKindOfClass:NSArray.class] ? ce[@"values_hz"] : @[];
    _centroidHop = [ce[@"hop_s"] doubleValue];
    [self dropImage];
    self.needsDisplay = YES;
    return YES;
}

#pragma mark Geometry

- (NSRect)plotRect {
    NSRect b = self.bounds;
    return NSMakeRect(kLeft, kBottom, MAX(1, b.size.width - kLeft - kRight), MAX(1, b.size.height - kBottom - kTop));
}

- (double)duration { return _seconds > 0 ? _seconds : 1; }

/// Fractional row (0 ... rows) of a frequency, by interpolating row_hz.
- (double)rowForHz:(double)hz {
    NSInteger n = _rows;
    if (n < 2) return 0.5;
    double first = [_rowHz[0] doubleValue], last = [_rowHz[n - 1] doubleValue];
    if (hz <= first) return 0.5;
    if (hz >= last) return n - 0.5;
    NSInteger lo = 0, hi = n - 1;
    while (hi - lo > 1) { NSInteger m = (lo + hi) / 2; if ([_rowHz[m] doubleValue] <= hz) lo = m; else hi = m; }
    double a = [_rowHz[lo] doubleValue], b = [_rowHz[hi] doubleValue];
    return lo + 0.5 + (b > a ? (hz - a) / (b - a) : 0);
}

- (CGFloat)yForHz:(double)hz inRect:(NSRect)r { return NSMinY(r) + [self rowForHz:hz] / _rows * r.size.height; }
- (CGFloat)xForTime:(double)t inRect:(NSRect)r { return NSMinX(r) + MIN(MAX(t / [self duration], 0), 1) * r.size.width; }

- (CGPathRef)copyCurve:(NSArray<NSNumber *> *)v hop:(double)hop {
    if (!_u8 || !v.count || hop <= 0) return NULL;
    NSRect r = [self plotRect];
    CGMutablePathRef path = CGPathCreateMutable();
    BOOL pen = NO;
    for (NSUInteger i = 0; i < v.count; i++) {
        double hz = v[i].doubleValue;
        if (hz <= 0 || !isfinite(hz)) { pen = NO; continue; }   // no voice: lift the pen
        CGPoint p = CGPointMake([self xForTime:i * hop inRect:r], [self yForHz:hz inRect:r]);
        if (!pen) { CGPathMoveToPoint(path, NULL, p.x, p.y); pen = YES; } else CGPathAddLineToPoint(path, NULL, p.x, p.y);
    }
    if (CGPathIsEmpty(path)) { CGPathRelease(path); return NULL; }
    return path;
}

- (CGPathRef)copyPitchPath { return [self copyCurve:_f0 hop:_f0Hop]; }

#pragma mark Reading values

- (NSInteger)columnForTime:(double)t {
    return MIN(MAX((NSInteger)floor(t / [self duration] * _cols), 0), _cols - 1);
}

- (int)dbAtRow:(NSInteger)r column:(NSInteger)c {
    return (int)lround(_dbFloor + ((const uint8_t *)_u8.bytes)[r * _cols + c] / 255.0 * (_dbCeil - _dbFloor));
}

- (id)accessibilityValue {
    if (!_u8) return @"";
    NSInteger c = [self columnForTime:_position], best = 0;
    const uint8_t *p = _u8.bytes;
    for (NSInteger r = 1; r < _rows; r++) if (p[r * _cols + c] > p[best * _cols + c]) best = r;
    NSString *s = [NSString stringWithFormat:L(@"%1$@ · %2$.1f kHz · %3$@ dB"), ClockString(_position),
                   [_rowHz[best] doubleValue] / 1000, DbString([self dbAtRow:best column:c])];
    if (_median) s = [s stringByAppendingFormat:@". %@", [NSString stringWithFormat:L(@"Median pitch %d Hz"), (int)lround(_median.doubleValue)]];
    return s;
}

#pragma mark Mouse

- (double)timeAtPoint:(NSPoint)p {
    NSRect r = [self plotRect];
    return MIN(MAX((p.x - NSMinX(r)) / r.size.width, 0), 1) * [self duration];
}
- (void)mouseDown:(NSEvent *)e { [self seekTo:e]; }
- (void)mouseDragged:(NSEvent *)e { [self seekTo:e]; }
- (void)seekTo:(NSEvent *)e {
    if (!_u8) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _hover = p; _hovering = YES;
    if (self.onSeek) self.onSeek([self timeAtPoint:p]);
    self.needsDisplay = YES;
}
- (void)mouseMoved:(NSEvent *)e { _hover = [self convertPoint:e.locationInWindow fromView:nil]; _hovering = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { _hovering = NO; self.needsDisplay = YES; }

#pragma mark Drawing

- (void)strokeCurve:(NSArray<NSNumber *> *)v hop:(double)hop color:(NSColor *)c dashed:(BOOL)dashed ctx:(CGContextRef)ctx {
    CGPathRef path = [self copyCurve:v hop:hop];
    if (!path) return;
    CGContextSaveGState(ctx);
    CGContextSetLineJoin(ctx, kCGLineJoinRound);
    CGContextSetLineCap(ctx, kCGLineCapRound);
    // A solid background-colored halo keeps the curve readable where its color equals the spectrogram's bright stop.
    [OVColor(OVRoleBackground) setStroke];
    CGContextSetLineWidth(ctx, 4);
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    [c setStroke];
    CGContextSetLineWidth(ctx, 1.5);
    if (dashed) { CGFloat d[2] = {4, 3}; CGContextSetLineDash(ctx, 0, d, 2); }
    CGContextAddPath(ctx, path);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);
    CGPathRelease(path);
}

- (void)drawLabel:(NSString *)s at:(NSPoint)p align:(CGFloat)align {
    NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
                        NSForegroundColorAttributeName: OVColor(OVRoleMuted)};
    NSSize sz = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(p.x - sz.width * align, p.y) withAttributes:a];
}

- (void)drawRect:(NSRect)dirty {
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    NSRect r = [self plotRect];
    [OVColor(OVRoleField) setFill];
    NSRectFill(r);
    if (!_u8) { [OVColor(OVRoleBorder) setStroke]; NSFrameRect(r); return; }

    BOOL dark = CurrentIsDark();
    if (_image && (_imageDark != dark || ![_imagePalette isEqualToString:OVTheme.paletteId])) [self dropImage];
    if (!_image) { _image = OVSpectrogramImage(_u8, _cols, _rows, dark); _imageDark = dark; _imagePalette = OVTheme.paletteId; }
    if (_image) {
        CGContextSaveGState(ctx);
        CGContextClipToRect(ctx, r);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, r, _image);
        CGContextRestoreGState(ctx);
    }

    // Frequency grid and labels.
    double top = [_rowHz.lastObject doubleValue];
    for (NSNumber *f in @[@500, @1000, @2000, @4000, @8000]) {
        if (f.doubleValue > top) continue;
        CGFloat y = round([self yForHz:f.doubleValue inRect:r]) + 0.5;
        [OVColorAlpha(OVRoleText, 0.12) setStroke];
        CGContextSetLineWidth(ctx, 1);
        CGContextMoveToPoint(ctx, NSMinX(r), y); CGContextAddLineToPoint(ctx, NSMaxX(r), y); CGContextStrokePath(ctx);
        NSString *num = f.doubleValue < 1000 ? @"0.5" : [NSString stringWithFormat:@"%d", f.intValue / 1000];
        [self drawLabel:[NSString stringWithFormat:L(@"%@ kHz"), num] at:NSMakePoint(NSMinX(r) - 5, y - 6) align:1];
    }
    // Time labels under the picture.
    double dur = [self duration];
    int ticks = MAX(2, MIN(8, (int)(r.size.width / 90)));
    for (int i = 0; i <= ticks; i++) {
        double t = dur * i / ticks;
        [self drawLabel:ClockString(t) at:NSMakePoint([self xForTime:t inRect:r], 5) align:i == 0 ? 0 : (i == ticks ? 1 : 0.5)];
    }

    if (_showsCentroid) [self strokeCurve:_centroid hop:_centroidHop color:OVColor(OVRoleWarn) dashed:YES ctx:ctx];
    if (_showsPitch) [self strokeCurve:_f0 hop:_f0Hop color:OVColor(OVRoleOK) dashed:NO ctx:ctx];

    CGFloat px = round([self xForTime:_position inRect:r]) + 0.5;
    [OVColorAlpha(OVRoleText, 0.9) setStroke];
    CGContextSetLineWidth(ctx, 1);
    CGContextMoveToPoint(ctx, px, NSMinY(r)); CGContextAddLineToPoint(ctx, px, NSMaxY(r)); CGContextStrokePath(ctx);

    if (_hovering && NSPointInRect(_hover, r)) {
        double t = [self timeAtPoint:_hover];
        NSInteger row = MIN(MAX((NSInteger)((_hover.y - NSMinY(r)) / r.size.height * _rows), 0), _rows - 1);
        NSString *s = [NSString stringWithFormat:L(@"%1$@ · %2$.1f kHz · %3$@ dB"), ClockString(t),
                       [_rowHz[row] doubleValue] / 1000, DbString([self dbAtRow:row column:[self columnForTime:t]])];
        NSDictionary *a = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: OVColor(OVRoleText)};
        NSSize sz = [s sizeWithAttributes:a];
        NSRect box = NSMakeRect(MAX(NSMinX(r), MIN(_hover.x + 10, NSMaxX(r) - sz.width - 12)),
                                MAX(NSMinY(r), MIN(_hover.y + 10, NSMaxY(r) - sz.height - 8)), sz.width + 12, sz.height + 6);
        [OVColorAlpha(OVRoleBackground, 0.9) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:box xRadius:5 yRadius:5] fill];
        [s drawAtPoint:NSMakePoint(box.origin.x + 6, box.origin.y + 3) withAttributes:a];
    }
    [OVColor(OVRoleBorder) setStroke];
    NSFrameRect(r);
}

@end
