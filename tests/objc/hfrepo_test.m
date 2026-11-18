// deps: OVNetwork.m OVWorker.m OVRuntime.m OVPaths.m OVModels.m OVDownloader.m OVLocale.m OVStore.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVModels.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __func__, __LINE__, #cond); } } while (0)

static void spin(BOOL *flag) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!*flag && [end timeIntervalSinceNow] > 0) [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

static void fake(NSArray *files) {
    OVModels.shared.jsonFetcher = ^(NSURL *u, NSDictionary *h, void (^done)(id, NSError *)) {
        NSMutableArray *sib = [NSMutableArray array];
        for (NSString *f in files) [sib addObject:@{@"rfilename": f}];
        done(@{@"id": @"user/lora-ua", @"siblings": sib}, nil);
    };
}

static void testParse(void) {
    NSDictionary *t = @{
        @"user/lora-ua": @"user/lora-ua",
        @"  user/lora-ua \n": @"user/lora-ua",
        @"https://huggingface.co/user/lora-ua": @"user/lora-ua",
        @"https://huggingface.co/user/lora-ua/tree/main": @"user/lora-ua",
        @"huggingface.co/user/lora-ua/blob/main/adapter_config.json": @"user/lora-ua",
        @"https://huggingface.co/user/lora-ua/resolve/main/adapter_model.safetensors?download=true": @"user/lora-ua",
        @"hf.co/user/lora-ua/": @"user/lora-ua",
        @"https://example.com/user/x": [NSNull null],
        @"user": [NSNull null],
        @"../etc/passwd": [NSNull null],
        @"user/repo with space": [NSNull null],
        @"https://huggingface.co/datasets/a/b": [NSNull null],
        @"https://huggingface.co/user": [NSNull null],
        @"": [NSNull null],
        @"a/..": [NSNull null],
    };
    for (NSString *in in t) {
        NSString *got = [OVModels repoFromHuggingFaceString:in];
        id want = t[in];
        BOOL ok = want == NSNull.null ? got == nil : [got isEqualToString:want];
        ASSERT(ok);
        if (!ok) fprintf(stderr, "  input [%s] got [%s]\n", in.UTF8String, got.UTF8String);
    }
    NSString *long200 = [@"user/" stringByAppendingString:[@"" stringByPaddingToLength:195 withString:@"a" startingAtIndex:0]];
    ASSERT([OVModels repoFromHuggingFaceString:long200] == nil);
}

static void testAddUsesLoRAKind(void) {
    fake(@[@"adapter_config.json", @"adapter_model.safetensors", @"README.md"]);
    NSUInteger before = [OVModels.shared modelsOfKind:OVModelLoRA].count;
    __block OVModel *m1 = nil; __block NSString *e1 = nil; __block BOOL done = NO;
    [OVModels.shared addLoRAFromString:@"https://huggingface.co/user/lora-ua/tree/main" completion:^(OVModel *m, NSString *e) { m1 = m; e1 = e; done = YES; }];
    spin(&done);
    ASSERT(m1 && !e1 && m1.kind == OVModelLoRA && [m1.repo isEqualToString:@"user/lora-ua"] && m1.custom);
    ASSERT([OVModels.shared modelsOfKind:OVModelLoRA].count == before + 1);
    done = NO; __block OVModel *m2 = nil;
    [OVModels.shared addLoRAFromString:@"user/lora-ua" completion:^(OVModel *m, NSString *e) { m2 = m; done = YES; }];
    spin(&done);
    ASSERT(m2 == m1);
    ASSERT([OVModels.shared modelsOfKind:OVModelLoRA].count == before + 1);
    [OVModels.shared removeCustom:m1];
}

static void testApiMissingFilesError(void) {
    fake(@[@"config.json", @"model.safetensors"]);
    NSUInteger before = OVModels.shared.all.count;
    __block OVModel *m = nil; __block NSString *err = nil; __block BOOL done = NO;
    [OVModels.shared addLoRAFromString:@"other/full-model" completion:^(OVModel *mm, NSString *e) { m = mm; err = e; done = YES; }];
    spin(&done);
    ASSERT(done && !m && [err containsString:@"adapter_config.json"] && [err containsString:@"PEFT"]);
    ASSERT(OVModels.shared.all.count == before && ![OVModels.shared modelForRepo:@"other/full-model"]);
    // not a link at all: error without any request
    __block BOOL called = NO; done = NO;
    OVModels.shared.jsonFetcher = ^(NSURL *u, NSDictionary *h, void (^d)(id, NSError *)) { called = YES; d(nil, nil); };
    [OVModels.shared addLoRAFromString:@"nonsense" completion:^(OVModel *mm, NSString *e) { m = mm; err = e; done = YES; }];
    spin(&done);
    ASSERT(done && !m && err.length && !called);
}

int main(void) {
    @autoreleasepool {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"hfrepo-%d", getpid()]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("OV_DATA_DIR", dir.UTF8String, 1);
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"offlineMode"];
        testParse();
        testAddUsesLoRAKind();
        testApiMissingFilesError();
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("hfrepo_test: ok\n");
    return 0;
}
