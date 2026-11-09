#import "OVPageRegistry.h"
#import "OVPages.h"
#import "OVLocale.h"

@implementation OVPageRegistry

static NSDictionary *P(NSString *pid, NSString *title, NSString *symbol, Class cls, BOOL pro) {
    return @{@"id": pid, @"title": title, @"symbol": symbol, @"class": cls, @"pro": @(pro)};
}

+ (NSArray<NSDictionary *> *)groups {
    Class ph = OVPlaceholderPage.class;
    return @[
        @{@"title": L(@"VOICE"), @"pages": @[
            P(@"synth", L(@"Speech"), @"waveform", OVSynthPage.class, NO),
            P(@"voices", L(@"Voices"), @"person.wave.2", OVVoicesPage.class, NO),
            P(@"convert", L(@"Convert"), @"arrow.triangle.2.circlepath", OVConvertPage.class, YES),
            P(@"realtime", L(@"Realtime"), @"dot.radiowaves.left.and.right", OVRealtimePage.class, YES)]},
        @{@"title": L(@"MODELS & TRAINING"), @"pages": @[
            P(@"models", L(@"Models"), @"shippingbox", OVModelsPage.class, NO),
            P(@"training", L(@"Training"), @"graduationcap", OVTrainingPage.class, YES),
            P(@"blender", L(@"Voice Blender"), @"square.stack.3d.up", OVBlenderPage.class, YES)]},
        @{@"title": L(@"TOOLS"), @"pages": @[
            P(@"tools", L(@"Audio Tools"), @"slider.horizontal.3", ph, NO),
            P(@"separator", L(@"Separation"), @"waveform.path.ecg", ph, NO)]},
        @{@"title": L(@"SYSTEM"), @"pages": @[
            P(@"jobs", L(@"Jobs"), @"clock.arrow.circlepath", OVJobsPage.class, NO),
            P(@"api", L(@"API & Bridge"), @"chevron.left.forwardslash.chevron.right", ph, NO),
            P(@"plugins", L(@"Plugins"), @"puzzlepiece.extension", ph, YES),
            P(@"privacy", L(@"Data & Privacy"), @"hand.raised", ph, NO),
            P(@"settings", L(@"Settings"), @"gearshape", OVSettingsPage.class, NO),
            P(@"setup", L(@"Setup"), @"checklist", OVSetupPage.class, NO)]},
    ];
}

+ (NSArray<NSDictionary *> *)hiddenPages {
    return @[P(@"log", L(@"Log"), @"text.alignleft", OVLogPage.class, NO),
             P(@"gallery", @"Gallery", @"square.grid.2x2", OVGalleryPage.class, NO)];  // developer page, not translated
}

+ (NSDictionary *)entryForPage:(NSString *)pageId {
    for (NSDictionary *g in [self groups])
        for (NSDictionary *p in g[@"pages"]) if ([p[@"id"] isEqualToString:pageId]) return p;
    for (NSDictionary *p in [self hiddenPages]) if ([p[@"id"] isEqualToString:pageId]) return p;
    return nil;
}

+ (NSArray<NSString *> *)allPageIds {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *g in [self groups]) for (NSDictionary *p in g[@"pages"]) [ids addObject:p[@"id"]];
    for (NSDictionary *p in [self hiddenPages]) [ids addObject:p[@"id"]];
    return ids;
}

+ (Class)classForPage:(NSString *)pageId { return [self entryForPage:pageId][@"class"]; }
@end
