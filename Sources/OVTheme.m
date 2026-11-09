#import "OVTheme.h"

NSNotificationName const OVThemeDidChangeNotification = @"OVThemeDidChange";

static NSString *const kPaletteKey = @"OVPalette";
static NSString *const kDefaultPalette = @"applio";

static const char *const kRoleKeys[] = {
    "background", "surface", "field", "border", "text", "muted", "accent", "accentSoft",
    "cta", "ctaText", "ghostBorder", "log", "ok", "warn", "err", "focus"
};

/// "#rrggbb" or "#rrggbbaa" -> sRGB color; magenta marks a malformed value.
static NSColor *ColorFromHex(NSString *hex) {
    NSString *h = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    unsigned v = 0;
    if ((h.length != 6 && h.length != 8) || ![[NSScanner scannerWithString:h] scanHexInt:&v]) return NSColor.magentaColor;
    CGFloat a = 1;
    if (h.length == 8) { a = (v & 0xff) / 255.0; v >>= 8; }
    return [NSColor colorWithSRGBRed:((v >> 16) & 0xff) / 255.0 green:((v >> 8) & 0xff) / 255.0 blue:(v & 0xff) / 255.0 alpha:a];
}

static NSArray<NSDictionary *> *AllPalettes(void) {
    static NSArray *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"themes" ofType:@"json"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        all = [root[@"palettes"] isKindOfClass:NSArray.class] ? root[@"palettes"] : @[];
    });
    return all;
}

static NSDictionary *CurrentPalette(void) {
    NSString *pid = [OVTheme paletteId];
    NSArray *all = AllPalettes();
    for (NSDictionary *p in all) if ([p[@"id"] isEqualToString:pid]) return p;
    return all.firstObject;
}

NSColor *OVColor(OVRole role) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *a) {
        BOOL dark = [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
        NSString *hex = CurrentPalette()[dark ? @"dark" : @"light"][@(kRoleKeys[role])];
        return hex ? ColorFromHex(hex) : NSColor.magentaColor;
    }];
}

@implementation OVTheme

+ (NSArray<NSDictionary *> *)palettes {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *p in AllPalettes()) [out addObject:@{@"id": p[@"id"], @"title": p[@"title"]}];
    return out;
}

+ (NSString *)paletteId {
    return [NSUserDefaults.standardUserDefaults stringForKey:kPaletteKey] ?: kDefaultPalette;
}

+ (void)setPaletteId:(NSString *)pid {
    [NSUserDefaults.standardUserDefaults setObject:pid forKey:kPaletteKey];
    [NSNotificationCenter.defaultCenter postNotificationName:OVThemeDidChangeNotification object:nil];
}

@end
