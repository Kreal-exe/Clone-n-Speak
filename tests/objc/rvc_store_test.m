// deps: OVRvcStore.m OVRvcSearch.m OVLocale.m OVPaths.m OVNetwork.m OVDownloader.m OVPrivacyCatalog.m OVModels.m OVStore.m OVRuntime.m OVWorker.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVRvcStore.h"
#import "OVRvcSearch.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", __func__, __LINE__, #cond); \
    fprintf(stderr, "%s\n", [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]); } } while (0)

static NSString *tempRoot(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"rvcstore-test-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

/// A model folder as cns_rvc.py import writes it.
static NSString *makeModel(NSString *root, NSString *ident, NSString *name, BOOL index, NSDictionary *info) {
    NSString *dir = [root stringByAppendingPathComponent:ident];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData dataWithBytes:"PKpth-bytes" length:11] writeToFile:[dir stringByAppendingPathComponent:@"voice.pth"] atomically:YES];
    if (index) [[NSData dataWithBytes:"IxF2" length:4] writeToFile:[dir stringByAppendingPathComponent:@"voice.index"] atomically:YES];
    NSDictionary *meta = @{@"id": ident, @"name": name, @"sha256": @"abcdef0123456789", @"source_url": [NSNull null],
                           @"imported_at": @1, @"info": info ?: @{@"version": @"v2", @"sample_rate": @40000, @"f0": @YES, @"epochs": @300,
                                                                   @"size_bytes": @11, @"sha256": @"abcdef0123456789", @"has_index": @(index)}};
    [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToFile:[dir stringByAppendingPathComponent:@"meta.json"] atomically:YES];
    return dir;
}

static void testScanReadsMetaAndSkipsBroken(void) {
    NSString *root = tempRoot();
    makeModel(root, @"alpha-11111111", @"Alpha", YES, nil);
    makeModel(root, @"beta-22222222", @"beta", NO, @{@"version": @"v1", @"sample_rate": @32000, @"f0": @NO});
    // broken: no meta.json, bad json, meta without a .pth, an import staging folder, a loose file
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@"nometa"] withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSData dataWithBytes:"x" length:1] writeToFile:[root stringByAppendingPathComponent:@"nometa/a.pth"] atomically:YES];
    NSString *bad = [root stringByAppendingPathComponent:@"badjson"];
    [NSFileManager.defaultManager createDirectoryAtPath:bad withIntermediateDirectories:YES attributes:nil error:nil];
    [@"{not json" writeToFile:[bad stringByAppendingPathComponent:@"meta.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *nopth = [root stringByAppendingPathComponent:@"nopth"];
    [NSFileManager.defaultManager createDirectoryAtPath:nopth withIntermediateDirectories:YES attributes:nil error:nil];
    [@"{\"name\":\"x\"}" writeToFile:[nopth stringByAppendingPathComponent:@"meta.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:[root stringByAppendingPathComponent:@".import-abc"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"x" writeToFile:[root stringByAppendingPathComponent:@"loose.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];

    OVRvcStore *s = [OVRvcStore storeWithRoot:root];
    ASSERT(s.models.count == 2, "got %lu", (unsigned long)s.models.count);
    ASSERT(s.skippedCount == 3, "skipped %lu", (unsigned long)s.skippedCount);
    OVRvcModel *a = s.models.firstObject;
    ASSERT([a.name isEqualToString:@"Alpha"] && [a.identifier isEqualToString:@"alpha-11111111"]);
    ASSERT([a.version isEqualToString:@"v2"] && a.sampleRate == 40000 && a.pitch && a.hasIndex && a.epochs == 300);
    ASSERT(a.sizeBytes == 15, "size %lld", a.sizeBytes);
    OVRvcModel *b = s.models.lastObject;
    ASSERT([b.version isEqualToString:@"v1"] && b.sampleRate == 32000 && !b.pitch && !b.hasIndex);
    ASSERT([[OVRvcStore kHzText:40000] isEqualToString:@"40 kHz"]);
    ASSERT([NSFileManager.defaultManager fileExistsAtPath:nopth], "a broken folder is never deleted");
    // an empty or missing folder is an empty list
    ASSERT([OVRvcStore storeWithRoot:[root stringByAppendingPathComponent:@"missing"]].models.count == 0);
    // an 80-character name stays whole in the model (the row truncates it in the middle)
    NSString *long80 = [@"" stringByPaddingToLength:80 withString:@"Voice" startingAtIndex:0];
    makeModel(root, @"long-33333333", long80, NO, nil);
    [s rescan];
    ASSERT(s.models.count == 3);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testRenameKeepsFilesAndUpdatesMeta(void) {
    NSString *root = tempRoot();
    NSString *dir = makeModel(root, @"alpha-11111111", @"Alpha", YES, nil);
    OVRvcStore *s = [OVRvcStore storeWithRoot:root];
    OVRvcModel *m = s.models.firstObject;
    NSData *pthBefore = [NSData dataWithContentsOfFile:m.pthPath];
    NSError *err = nil;
    NSString *final = [s renameModel:m to:@"  My voice \n" error:&err];
    ASSERT([final isEqualToString:@"My voice"], "%@ %@", final, err);
    ASSERT([NSFileManager.defaultManager fileExistsAtPath:dir], "the folder keeps its id");
    ASSERT([[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"voice.pth"]] isEqualToData:pthBefore]);
    ASSERT([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:@"voice.index"]]);
    NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.json"]] options:0 error:nil];
    ASSERT([meta[@"name"] isEqualToString:@"My voice"]);
    ASSERT([meta[@"sha256"] isEqualToString:@"abcdef0123456789"] && [meta[@"id"] isEqualToString:@"alpha-11111111"], "the checksum and id stay");
    ASSERT([meta[@"info"][@"version"] isEqualToString:@"v2"]);
    ASSERT([s.models.firstObject.name isEqualToString:@"My voice"]);
    ASSERT([s renameModel:s.models.firstObject to:@"   " error:&err] == nil && err != nil, "an empty name is refused");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testDeleteMovesToTrash(void) {
    NSString *root = tempRoot();
    NSString *dir = makeModel(root, @"alpha-11111111", @"Alpha", YES, nil);
    makeModel(root, @"beta-22222222", @"Beta", NO, nil);
    OVRvcStore *s = [OVRvcStore storeWithRoot:root];
    OVRvcModel *m = [s modelWithIdentifier:@"alpha-11111111"];
    NSError *err = nil;
    NSString *trashed = [s deleteModel:m error:&err];
    ASSERT(trashed.length > 0, "%@", err);
    ASSERT(![NSFileManager.defaultManager fileExistsAtPath:dir], "gone from the models folder");
    ASSERT([NSFileManager.defaultManager fileExistsAtPath:[trashed stringByAppendingPathComponent:@"meta.json"]], "recoverable from the Trash: %@", trashed);
    ASSERT(s.models.count == 1 && [s.models.firstObject.identifier isEqualToString:@"beta-22222222"]);
    if (trashed.length) [NSFileManager.defaultManager removeItemAtPath:trashed error:nil];
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testIdCollisionGetsSuffix(void) {
    NSString *root = tempRoot();
    makeModel(root, @"cat-aaaaaaaa", @"Cat", NO, nil);
    makeModel(root, @"cat-bbbbbbbb", @"Cat", NO, nil);    // another file, same name
    makeModel(root, @"cat-cccccccc", @"cat", NO, nil);    // case does not tell them apart either
    OVRvcStore *s = [OVRvcStore storeWithRoot:root];
    NSArray *names = [s.models valueForKey:@"name"];
    ASSERT(names.count == 3 && [[NSSet setWithArray:[names valueForKey:@"lowercaseString"]] count] == 3, "%@", names);
    ASSERT([names containsObject:@"Cat 2"] || [names containsObject:@"cat 2"], "%@", names);
    // renaming onto a name in use gets the suffix; the ids (folders) never change
    OVRvcModel *first = s.models.firstObject;
    NSString *other = s.models.lastObject.name;
    NSString *final = [s renameModel:first to:other error:nil];
    ASSERT(final && ![final.lowercaseString isEqualToString:other.lowercaseString], "%@ vs %@", final, other);
    NSArray *used = @[@"x", @"x 2"];
    ASSERT([[OVRvcStore uniqueName:@"x" amongNames:used] isEqualToString:@"x 3"]);
    ASSERT([[OVRvcStore uniqueName:@"y" amongNames:used] isEqualToString:@"y"]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

static void testSearchKeepsRepositoriesWithAVoiceFile(void) {
    NSArray *json = @[
        @{@"id": @"a/voice", @"downloads": @12, @"likes": @3, @"tags": @[@"rvc", @"license:mit"],
          @"siblings": @[@{@"rfilename": @"README.md"}, @{@"rfilename": @"weights/G_2333333.pth"}, @{@"rfilename": @"weights/voice.pth"},
                         @{@"rfilename": @"weights/trained_IVF_Flat.index"}, @{@"rfilename": @"weights/added_IVF_Flat.index"},
                         @{@"rfilename": @"other/x.index"}]},
        @{@"id": @"b/nolicense", @"tags": @[@"rvc"], @"siblings": @[@{@"rfilename": @"model.pth"}]},
        @{@"id": @"c/docs", @"tags": @[], @"siblings": @[@{@"rfilename": @"README.md"}]},
        @{@"id": @"d/checkpointsonly", @"siblings": @[@{@"rfilename": @"D_1000.pth"}, @{@"rfilename": @"G_1000.pth"}]},
        @{@"nope": @1}, @"garbage"];
    NSArray<OVRvcSearchResult *> *r = [OVRvcSearch resultsFromJSON:json];
    ASSERT(r.count == 2, "%lu", (unsigned long)r.count);
    ASSERT([r[0].repo isEqualToString:@"a/voice"] && [r[0].license isEqualToString:@"mit"] && r[0].downloads == 12);
    ASSERT([r[0].pthFile isEqualToString:@"weights/voice.pth"], "training checkpoints are not voices: %@", r[0].pthFile);
    ASSERT([r[0].indexFile isEqualToString:@"weights/added_IVF_Flat.index"], "%@", r[0].indexFile);
    ASSERT(r[1].license == nil && r[1].indexFile == nil, "no license tag means not stated");
    ASSERT([OVRvcSearch resultsFromJSON:@{@"error": @"x"}].count == 0);
}

static void testSearchURLAndLinks(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"hfEndpoint"];
    NSURL *u = [OVRvcSearch searchURLForQuery:@" rvc v2 & more "];
    ASSERT([u.absoluteString isEqualToString:@"https://huggingface.co/api/models?search=rvc%20v2%20%26%20more&limit=20&full=true"], "%@", u);
    ASSERT([OVRvcSearch searchURLForQuery:@"  "] == nil);
    [NSUserDefaults.standardUserDefaults setObject:@"http://insecure.example" forKey:@"hfEndpoint"];
    ASSERT([OVRvcSearch searchURLForQuery:@"rvc"] == nil && [OVRvcSearch endpoint] == nil, "a token must not go over http");
    [NSUserDefaults.standardUserDefaults setObject:@"https://mirror.example/" forKey:@"hfEndpoint"];
    ASSERT([[OVRvcSearch downloadURLForRepo:@"a/b" file:@"w/x y.pth"].absoluteString isEqualToString:@"https://mirror.example/a/b/resolve/main/w/x%20y.pth"]);
    ASSERT([OVRvcSearch downloadURLForRepo:@"a/b" file:@"../x.pth"] == nil);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"hfEndpoint"];

    NSString *err = nil;
    ASSERT([[OVRvcSearch fetchLinkFromText:@"https://huggingface.co/a/b/blob/main/m.pth" error:&err] isEqualToString:@"https://huggingface.co/a/b/resolve/main/m.pth"], "blob -> resolve");
    ASSERT([OVRvcSearch fetchLinkFromText:@"http://example.com/m.pth" error:&err] == nil && err.length, "http refused");
    ASSERT([OVRvcSearch fetchLinkFromText:@"https://drive.google.com/file/d/1/view" error:&err] == nil && [err containsString:@"Drive"], "%@", err);
    ASSERT([OVRvcSearch fetchLinkFromText:@"https://example.com/readme.html" error:&err] == nil);
    ASSERT([OVRvcSearch fetchLinkFromText:@"not a link" error:&err] == nil);
    ASSERT([OVRvcSearch fetchLinkFromText:@"https://example.com/v.zip?download=1" error:&err] != nil);
}

int main(void) {
    @autoreleasepool {
        testScanReadsMetaAndSkipsBroken();
        testRenameKeepsFilesAndUpdatesMeta();
        testDeleteMovesToTrash();
        testIdCollisionGetsSuffix();
        testSearchKeepsRepositoriesWithAVoiceFile();
        testSearchURLAndLinks();
    }
    printf(gFailures ? "FAILED %d\n" : "ok\n", gFailures);
    return gFailures ? 1 : 0;
}
