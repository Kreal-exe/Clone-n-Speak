// deps: OVStemsCard.m OVDesign.m OVUI.m OVTheme.m OVLocale.m OVPaths.m OVPlayerBar.m OVWaveformView.m OVTrim.m OVAudioIO.m OVJobs.m OVJobStore.m OVEngines.m OVProKit.m OVProRunPlan.m OVNetwork.m OVPrivacyCatalog.m OVRuntime.m OVWorker.m OVModels.m OVDownloader.m OVStore.m OVMemory.m
// The pure parts of the full separation card: model table, request shape, result names, estimates. Exit status 1 on a failure.
#import <Cocoa/Cocoa.h>
#import "OVStemsCard.h"

static int gFailures = 0;
#define ASSERT(cond) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s\n", __func__, __LINE__, #cond); } } while (0)

static void testModelTable(void) {
    NSArray<OVStemsModelInfo *> *all = OVStemsModelInfo.all;
    ASSERT(all.count == 4);
    ASSERT([all.firstObject.identifier isEqual:@"kim-vocal-2"]);   // the default: fast
    OVStemsModelInfo *kim = [OVStemsModelInfo modelWithId:@"kim-vocal-2"], *bs = [OVStemsModelInfo modelWithId:@"bs-roformer"];
    OVStemsModelInfo *dm = [OVStemsModelInfo modelWithId:@"htdemucs"], *dr = [OVStemsModelInfo modelWithId:@"dereverb-anvuew"];
    ASSERT(kim && bs && dm && dr && ![OVStemsModelInfo modelWithId:@"nope"]);
    // measured peaks, not the table's old 6.5
    ASSERT(kim.peakGB == 7.2 && bs.peakGB == 6.6 && dm.peakGB == 2.3);
    ASSERT([dm.license isEqual:@"MIT"] && dm.verified && dm.licenseNote.length == 0);
    for (OVStemsModelInfo *m in @[kim, bs, dr]) {
        ASSERT(!m.verified && [m.license isEqual:@"unverified"]);
        ASSERT([m.licenseNote.lowercaseString containsString:@"unverified"] || m.licenseNote.length > 20);
    }
    ASSERT([kim.componentId isEqual:@"stems-kim-vocal-2"]);
}

static void testSummary(void) {
    OVStemsModelInfo *kim = [OVStemsModelInfo modelWithId:@"kim-vocal-2"];
    NSString *s = [kim summaryWithDownloadBytes:0];
    ASSERT([s containsString:@"7.2 GB"] && [s containsString:@"0.4×"] && [s containsString:@"Download"]);
    ASSERT(fabs([kim estimateForSeconds:600] - 240) < 1e-6);
    ASSERT(fabs([[OVStemsModelInfo modelWithId:@"bs-roformer"] estimateForSeconds:600] - 600) < 1e-6);
}

static void testRequests(void) {
    OVStemsModelInfo *kim = [OVStemsModelInfo modelWithId:@"kim-vocal-2"], *dr = [OVStemsModelInfo modelWithId:@"dereverb-anvuew"];
    NSDictionary *r = [OVStemsRequests requestWithInput:@"/t/a.wav" model:kim output:0 format:@"wav" name:@"a.mp3"];
    ASSERT([r[@"model"] isEqual:@"kim-vocal-2"] && [r[@"stems"] isEqual:@"all"] && [r[@"output_format"] isEqual:@"wav"]);
    ASSERT([r[@"input"] isEqual:@"/t/a.wav"] && [r[@"_name"] isEqual:@"a.mp3"]);
    ASSERT(r[@"id"] == nil);   // `id` is the worker's request number, never ours
    ASSERT([[OVStemsRequests requestWithInput:@"/t/a.wav" model:kim output:1 format:@"flac" name:nil][@"stems"] isEqual:@"vocals"]);
    NSDictionary *f = [OVStemsRequests requestWithInput:@"/t/a.wav" model:kim output:2 format:@"FLAC" name:nil];
    ASSERT([f[@"stems"] isEqual:@"instrumental"] && [f[@"output_format"] isEqual:@"flac"] && f[@"_name"] == nil);
    ASSERT([[OVStemsRequests requestWithInput:@"/t/a.wav" model:kim output:9 format:@"mp3" name:nil][@"output_format"] isEqual:@"wav"]);
    // a reverb model has no vocals/instrumental: it always asks for both parts
    ASSERT([[OVStemsRequests requestWithInput:@"/t/a.wav" model:dr output:1 format:@"wav" name:nil][@"stems"] isEqual:@"all"]);
}

static void testOutputNames(void) {
    ASSERT([[OVStemsRequests stemForOutputPath:@"/o/song_vocals.wav"] isEqual:@"vocals"]);
    ASSERT([[OVStemsRequests stemForOutputPath:@"/o/my_song_instrumental (2).flac"] isEqual:@"instrumental"]);
    ASSERT([[OVStemsRequests stemForOutputPath:@"/o/a_b_drums.wav"] isEqual:@"drums"]);
    ASSERT([[OVStemsRequests stemForOutputPath:@"/o/x_dry.wav"] isEqual:@"dry"]);
    ASSERT([OVStemsRequests stemForOutputPath:@"/o/song.wav"] == nil);
    ASSERT([OVStemsRequests stemForOutputPath:@"/o/song_vocals_final.wav"] == nil);
    ASSERT([OVStemsRequests longInputSeconds] == 600);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        testModelTable(); testSummary(); testRequests(); testOutputNames();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("PASS stems_card\n");
    return 0;
}
