// Renders the app icon (1024×1024 PNG): usage make_icon <out.png>
#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) return 1;
        const CGFloat S = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

        // macOS icon grid: 824pt body with soft shadow
        NSRect body = NSMakeRect(100, 100, 824, 824);
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 yRadius:185];
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        sh.shadowBlurRadius = 28;
        sh.shadowOffset = NSMakeSize(0, -12);
        [NSGraphicsContext saveGraphicsState];
        [sh set];
        [[NSColor colorWithSRGBRed:0.05 green:0.22 blue:0.62 alpha:1] setFill];
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];

        NSGradient *g = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:0.16 green:0.45 blue:0.98 alpha:1]
                                                      endingColor:[NSColor colorWithSRGBRed:0.04 green:0.19 blue:0.55 alpha:1]];
        [g drawInBezierPath:shape angle:-90];

        // waveform bars: white → Ukrainian yellow
        CGFloat heights[] = {150, 290, 470, 600, 420, 540, 330, 200};
        int n = sizeof(heights) / sizeof(heights[0]);
        CGFloat barW = 58, gap = 30;
        CGFloat total = n * barW + (n - 1) * gap;
        CGFloat x = S / 2 - total / 2;
        NSGradient *bars = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithSRGBRed:1 green:0.84 blue:0 alpha:1]
                                                         endingColor:[NSColor colorWithWhite:1 alpha:1]];
        for (int i = 0; i < n; i++) {
            NSRect r = NSMakeRect(x, S / 2 - heights[i] / 2, barW, heights[i]);
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:barW / 2 yRadius:barW / 2];
            [bars drawInBezierPath:p angle:90];
            x += barW + gap;
        }

        // subtle top gloss
        [NSGraphicsContext saveGraphicsState];
        [shape addClip];
        NSGradient *gloss = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.14]
                                                          endingColor:[NSColor colorWithWhite:1 alpha:0]];
        [gloss drawInRect:NSMakeRect(100, 512, 824, 412) angle:-90];
        [NSGraphicsContext restoreGraphicsState];

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:@(argv[1]) atomically:YES] ? 0 : 1;
    }
}
