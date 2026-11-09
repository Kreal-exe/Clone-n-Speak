#import <Cocoa/Cocoa.h>

/// Posted after the palette changes. Colors are dynamic, so listeners only need to redraw.
extern NSNotificationName const OVThemeDidChangeNotification;

typedef NS_ENUM(NSInteger, OVRole) {
    OVRoleBackground, OVRoleSurface, OVRoleField, OVRoleBorder, OVRoleText, OVRoleMuted,
    OVRoleAccent, OVRoleAccentSoft, OVRoleCTA, OVRoleCTAText, OVRoleGhostBorder, OVRoleLog,
    OVRoleOK, OVRoleWarn, OVRoleErr, OVRoleFocus
};

/// Dynamic color: light or dark by the effective appearance, from the current palette.
NSColor *OVColor(OVRole role);

@interface OVTheme : NSObject
+ (NSArray<NSDictionary *> *)palettes;      // @[@{@"id", @"title"}]
+ (NSString *)paletteId;                    // NSUserDefaults "OVPalette", default "applio"
+ (void)setPaletteId:(NSString *)pid;       // saves and posts OVThemeDidChangeNotification
/// @[background, surface, accent, cta] of any palette in the light or dark variant: plain sRGB colors, not dynamic. Empty for an unknown id.
+ (NSArray<NSColor *> *)swatchesForPalette:(NSString *)pid dark:(BOOL)dark;
@end
