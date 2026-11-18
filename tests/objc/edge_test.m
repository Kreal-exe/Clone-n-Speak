// deps: OVEdgeTTS.m OVAPI.m OVAPICore.m OVAPIPage.m OVAnalyzerView.m OVAudioIO.m OVBatch.m OVBatchEnv.m OVBatchSheet.m OVBlenderPage.m OVBridge.m OVConvertPage.m OVDesign.m OVDownloader.m OVEffectsView.m OVEngines.m OVExport.m OVGalleryPage.m OVJobStore.m OVJobs.m OVJobsPage.m OVJobsWorker.m OVKeychain.m OVLocale.m OVLogPage.m OVMemory.m OVModels.m OVModelsPage.m OVNativeAccent.m OVNetwork.m OVPageRegistry.m OVPaths.m OVPlaceholderPage.m OVPlayerBar.m OVPlugins.m OVPluginsPage.m OVPresets.m OVPrivacyCatalog.m OVPrivacyPage.m OVProKit.m OVProRunPlan.m OVRealtimePage.m OVRuntime.m OVSeparatorModel.m OVSeparatorPage.m OVSettingsPage.m OVSetupPage.m OVStore.m OVSynthPage.m OVTheme.m OVToolsModel.m OVToolsPage.m OVTrainSheet.m OVTrainingPage.m OVUI.m OVVoiceCheck.m OVVoicesPage.m OVWaveformView.m OVWorker.m
// The pure helpers of the Edge card: signed rate/pitch strings and the voice list. (The card pulls in the page kit, hence the long deps.)
#import <Foundation/Foundation.h>
#import "OVEdgeTTS.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s\n", __func__, __LINE__, #cond); } } while (0)

static NSArray *sample(void) {
    return @[@{@"ShortName": @"uk-UA-OstapNeural", @"Locale": @"uk-UA", @"Gender": @"Male", @"FriendlyName": @"Microsoft Ostap Online (Natural) - Ukrainian (Ukraine)"},
             @{@"ShortName": @"en-US-AriaNeural", @"Locale": @"en-US", @"Gender": @"Female", @"FriendlyName": @"Microsoft Aria Online (Natural) - English (United States)"},
             @{@"ShortName": @"en-GB-RyanNeural", @"Locale": @"en-GB", @"Gender": @"Male", @"FriendlyName": @"Microsoft Ryan"},
             @{@"ShortName": @"", @"Locale": @"de-DE"}];
}

static void testSignedStrings(void) {
    ASSERT([[OVEdgeTTS rateString:0] isEqualToString:@"+0%"]);
    ASSERT([[OVEdgeTTS rateString:10] isEqualToString:@"+10%"]);
    ASSERT([[OVEdgeTTS rateString:-25] isEqualToString:@"-25%"]);
    ASSERT([[OVEdgeTTS rateString:500] isEqualToString:@"+100%"]);
    ASSERT([[OVEdgeTTS rateString:-500] isEqualToString:@"-50%"]);
    ASSERT([[OVEdgeTTS pitchString:0] isEqualToString:@"+0Hz"]);
    ASSERT([[OVEdgeTTS pitchString:5] isEqualToString:@"+5Hz"]);
    ASSERT([[OVEdgeTTS pitchString:-80] isEqualToString:@"-50Hz"]);
}

static void testVoiceLists(void) {
    NSArray *langs = [OVEdgeTTS languagesOf:sample()];
    ASSERT([langs isEqualToArray:(@[@"de", @"en", @"uk"])]);
    NSArray *en = [OVEdgeTTS voices:sample() forLanguage:@"en"];
    ASSERT(en.count == 2);
    ASSERT([en[0][@"ShortName"] isEqualToString:@"en-GB-RyanNeural"]);   // sorted by locale
    ASSERT([[OVEdgeTTS voices:sample() forLanguage:@"de"] count] == 0);   // no ShortName: not a voice
    ASSERT([[OVEdgeTTS voices:sample() forLanguage:@"UK"] count] == 1);
}

static void testCache(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"edge-test-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"voices.json"];
    ASSERT([OVEdgeTTS readVoiceCache:path] == nil);
    [[NSJSONSerialization dataWithJSONObject:@{@"fetched": @1, @"voices": sample()} options:0 error:nil] writeToFile:path atomically:YES];
    ASSERT([OVEdgeTTS readVoiceCache:path].count == 4);
    [@"not json" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ASSERT([OVEdgeTTS readVoiceCache:path] == nil);
    [[NSJSONSerialization dataWithJSONObject:@{@"voices": @[@"x"]} options:0 error:nil] writeToFile:path atomically:YES];
    ASSERT([OVEdgeTTS readVoiceCache:path] == nil);
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

int main(void) {
    @autoreleasepool {
        testSignedStrings();
        testVoiceLists();
        testCache();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("edge_test OK\n");
    return 0;
}
