// deps: OVStore.m OVPaths.m OVModels.m OVDownloader.m OVRuntime.m OVLocale.m OVMemory.m OVWorker.m OVNetwork.m OVJobs.m OVJobStore.m OVPrivacyCatalog.m
#import <Foundation/Foundation.h>
#import "OVStore.h"
#import "OVPaths.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s  -- %s\n", __FILE__, __LINE__, #cond, [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]); } } while (0)

static NSString *Touch(NSString *name) {
    NSString *p = [[OVPaths outputs] stringByAppendingPathComponent:name];
    [@"x" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return p;
}

static OVGeneration *Find(NSString *path) {
    for (OVGeneration *g in [OVHistory shared].all) if ([g.path isEqualToString:path]) return g;
    return nil;
}

/// A meta.plist from before 2.0 has none of the new keys: the entry loads, without an original and without a copy.
static void testOldMetaStillLoads(void) {
    NSString *wav = Touch(@"old take.wav");
    NSDictionary *meta = @{@"text": @"Hello", @"voice": @"Anna", @"date": NSDate.date, @"seconds": @1.5, @"elapsed": @2};
    [meta writeToFile:[wav.stringByDeletingPathExtension stringByAppendingPathExtension:@"plist"] atomically:YES];
    [[OVHistory shared] reload];
    OVGeneration *g = Find(wav);
    ASSERT(g != nil);
    ASSERT(g.originalPath == nil);
    ASSERT(g.exportedPath == nil);
    ASSERT([g.formatId isEqualToString:@"wav"], "%@", g.formatId);
    ASSERT([g.deliveryPath isEqualToString:wav]);
    ASSERT([g.text isEqualToString:@"Hello"]);
}

/// The dry file and the exported copy survive a reload; the dry WAV is not a history entry of its own.
static void testRecordKeepsDryPath(void) {
    NSString *wav = Touch(@"fx take.wav"), *dry = Touch(@"fx take.dry.wav"), *mp3 = Touch(@"fx take.mp3");
    [[OVHistory shared] record:wav text:@"With effects" voice:nil
                        result:@{@"seconds": @2, @"elapsed": @3, @"dry_path": dry, @"exported_path": mp3, @"format": @"mp3"}];
    OVGeneration *g = Find(wav);
    ASSERT(g != nil);
    ASSERT([g.originalPath isEqualToString:dry], "%@", g.originalPath);
    ASSERT([g.exportedPath isEqualToString:mp3]);
    ASSERT([g.formatId isEqualToString:@"mp3"]);
    ASSERT([g.deliveryPath isEqualToString:mp3]);
    ASSERT(Find(dry) == nil, "the .dry.wav must not be listed");

    // a dry file deleted in Finder is no longer offered
    [NSFileManager.defaultManager removeItemAtPath:dry error:nil];
    [[OVHistory shared] reload];
    ASSERT(Find(wav).originalPath == nil);
    ASSERT([Find(wav).exportedPath isEqualToString:mp3]);
}

int main(void) {
    @autoreleasepool {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        setenv("OV_DATA_DIR", tmp.fileSystemRepresentation, 1);
        [OVPaths ensure];
        testOldMetaStillLoads();
        testRecordKeepsDryPath();
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("historymeta_test: ok\n");
    return 0;
}
