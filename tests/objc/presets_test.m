// deps: OVPresets.m OVPaths.m OVLocale.m
#import <Foundation/Foundation.h>
#import "OVPresets.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", __func__, __LINE__, #cond); \
    fprintf(stderr, "" __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static NSString *tempRoot(void) {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"presets-test-%u", arc4random()]];
}
static OVPreset *make(NSString *name) {
    OVPreset *p = [OVPreset new];
    p.name = name;
    p.style = @{@"speed": @1.1, @"emotion": @"calm"};
    p.chain = @[@{@"type": @"gain", @"on": @YES, @"params": @{@"db": @(-3.5)}},
                @{@"type": @"reverb", @"on": @NO, @"params": @{}}];
    p.formant = 1.25;
    return p;
}

static void testSaveLoadRenameDelete(void) {
    NSString *root = tempRoot();
    OVPresets *s = [OVPresets presetsWithRoot:root];
    ASSERT(s.all.count == 0);
    OVPreset *p = make(@"Warm: narrator/1");
    p.formatId = @"m4a"; p.quality = 192;
    OVPreset *saved = [s add:p];
    ASSERT(saved && saved.identifier.length > 0);
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
    ASSERT(files.count == 1);
    NSString *f = files.firstObject;
    ASSERT([f isEqualToString:[saved.identifier stringByAppendingString:@".json"]], "%s", f.UTF8String);
    ASSERT([f rangeOfString:@"/"].location == NSNotFound && [f rangeOfString:@":"].location == NSNotFound);

    OVPresets *s2 = [OVPresets presetsWithRoot:root];
    ASSERT(s2.all.count == 1);
    OVPreset *l = s2.all.firstObject;
    ASSERT([l.name isEqualToString:@"Warm: narrator/1"]);
    ASSERT([l.formatId isEqualToString:@"m4a"] && l.quality == 192);
    ASSERT(l.formant == 1.25 && l.chain.count == 2);
    ASSERT([l.chain[0][@"params"][@"db"] doubleValue] == -3.5);
    ASSERT([l.style[@"emotion"] isEqualToString:@"calm"]);

    ASSERT([s2 rename:l to:@"Zeta"]);
    OVPresets *s3 = [OVPresets presetsWithRoot:root];
    ASSERT([s3.all.firstObject.name isEqualToString:@"Zeta"]);
    ASSERT([s3.all.firstObject.identifier isEqualToString:saved.identifier]);

    [s3 remove:s3.all.firstObject];
    ASSERT(s3.all.count == 0);
    ASSERT([NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil].count == 0);
    ASSERT([OVPresets presetsWithRoot:root].all.count == 0);
}

static void testNoFormatStaysAbsent(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    OVPreset *p = [s add:make(@"No format")];
    ASSERT(p.formatId == nil);
    ASSERT(p.json[@"format"] == nil);
}

static void testRenameDuplicateNames(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    OVPreset *a = [s add:make(@"Same")], *b = [s add:make(@"Same")];
    ASSERT(a && b && ![a.identifier isEqualToString:b.identifier]);
    ASSERT(s.all.count == 2);
    ASSERT([s rename:b to:@"Same"]);
    ASSERT(![s rename:a to:@""]);
    ASSERT(![s rename:a to:@"   "]);
    ASSERT([a.name isEqualToString:@"Same"]);
    ASSERT([s add:make(@"")] == nil);
    ASSERT(s.all.count == 2);
}

static void testExportDataIsSortedJSON(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    OVPreset *p = make(@"Tëst \"q\"");
    p.formatId = @"mp3"; p.quality = -1;
    NSString *t = [[NSString alloc] initWithData:[s exportData:p] encoding:NSUTF8StringEncoding];
    ASSERT([t hasSuffix:@"}\n"] && ![t hasSuffix:@"\n\n"]);
    NSArray *top = @[@"\"chain\"", @"\"formant\"", @"\"format\"", @"\"name\"", @"\"style\"", @"\"version\""];
    NSUInteger last = 0;
    for (NSString *k in top) {
        NSRange r = [t rangeOfString:[@"\n  " stringByAppendingString:k]];
        ASSERT(r.location != NSNotFound && r.location >= last, "%s", k.UTF8String);
        last = r.location;
    }
    ASSERT([t containsString:@"\"quality\": null"]);
    ASSERT([t containsString:@"\"formant\": 1.25"]);
    ASSERT([t containsString:@"\"db\": -3.5"]);
    ASSERT([t containsString:@"\"params\": {}"]);
    ASSERT([t containsString:@"\"on\": false"]);
    ASSERT([t containsString:@"Tëst \\\"q\\\""]);
    ASSERT([t containsString:@"\"version\": 1\n"]);
    id back = [NSJSONSerialization JSONObjectWithData:[s exportData:p] options:0 error:nil];
    ASSERT([back isKindOfClass:NSDictionary.class]);
    p.formant = 1.0;
    ASSERT([[[NSString alloc] initWithData:[s exportData:p] encoding:NSUTF8StringEncoding] containsString:@"\"formant\": 1.0"]);
}

static void testImportOversizeRejected(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    __block BOOL workerCalled = NO, done = NO;
    s.validator = ^(NSDictionary *r, void (^d)(NSDictionary *, NSString *)) { workerCalled = YES; d(nil, nil); };
    NSMutableData *big = [NSMutableData dataWithLength:70000];
    memset(big.mutableBytes, ' ', 70000);
    [s importData:big completion:^(OVPreset *p, NSArray *w, NSString *e) {
        done = YES;
        ASSERT(p == nil && e.length > 0);
    }];
    ASSERT(done && !workerCalled);
}

static void testImportUsesValidator(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    s.validator = ^(NSDictionary *r, void (^d)(NSDictionary *, NSString *)) {
        ASSERT([r[@"cmd"] isEqualToString:@"preset_validate"] && [r[@"json"] isKindOfClass:NSString.class]);
        d(@{@"preset": @{@"version": @1, @"name": @"Imported", @"style": @{}, @"chain": @[]}, @"warnings": @[@"w1"]}, nil);
    };
    __block BOOL done = NO;
    [s importData:[@"{}" dataUsingEncoding:NSUTF8StringEncoding] completion:^(OVPreset *p, NSArray *w, NSString *e) {
        done = YES;
        ASSERT(p && [p.name isEqualToString:@"Imported"] && p.formatId == nil && p.formant == 1.0);
        ASSERT(w.count == 1 && e == nil);
    }];
    ASSERT(done);
    ASSERT(s.all.count == 0);   // importing does not add
    s.validator = ^(NSDictionary *r, void (^d)(NSDictionary *, NSString *)) { d(nil, @"bad"); };
    [s importData:[@"x" dataUsingEncoding:NSUTF8StringEncoding] completion:^(OVPreset *p, NSArray *w, NSString *e) {
        ASSERT(p == nil && [e isEqualToString:@"bad"]);
    }];
}

static void testCorruptFileSkipped(void) {
    NSString *root = tempRoot();
    OVPresets *s = [OVPresets presetsWithRoot:root];
    [s add:make(@"Good")];
    [@"{ not json" writeToFile:[root stringByAppendingPathComponent:@"bad-1.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"[1,2]" writeToFile:[root stringByAppendingPathComponent:@"bad-2.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{\"name\": \"\"}" writeToFile:[root stringByAppendingPathComponent:@"bad-3.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"{\"name\": \"x\"}" writeToFile:[root stringByAppendingPathComponent:@"..bad.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSMutableData *big = [NSMutableData dataWithLength:70000];
    memset(big.mutableBytes, ' ', 70000);
    [big writeToFile:[root stringByAppendingPathComponent:@"big.json"] atomically:YES];
    OVPresets *s2 = [OVPresets presetsWithRoot:root];
    ASSERT(s2.all.count == 1 && [s2.all.firstObject.name isEqualToString:@"Good"]);
}

static void testNotificationOnChange(void) {
    OVPresets *s = [OVPresets presetsWithRoot:tempRoot()];
    __block int n = 0;
    id tok = [NSNotificationCenter.defaultCenter addObserverForName:OVPresetsDidChangeNotification object:s queue:nil
                                                         usingBlock:^(NSNotification *x) { n++; }];
    OVPreset *p = [s add:make(@"A")];
    ASSERT(n == 1);
    [s rename:p to:@"B"];
    ASSERT(n == 2);
    [s rename:p to:@""];
    ASSERT(n == 2);
    [s remove:p];
    ASSERT(n == 3);
    [NSNotificationCenter.defaultCenter removeObserver:tok];
}

int main(void) {
    @autoreleasepool {
        testSaveLoadRenameDelete();
        testNoFormatStaysAbsent();
        testRenameDuplicateNames();
        testExportDataIsSortedJSON();
        testImportOversizeRejected();
        testImportUsesValidator();
        testCorruptFileSkipped();
        testNotificationOnChange();
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("presets_test: all passed\n");
    return 0;
}
