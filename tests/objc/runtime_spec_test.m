// deps: OVNetwork.m OVPrivacyCatalog.m OVWorker.m OVRuntime.m OVPaths.m OVModels.m OVDownloader.m OVLocale.m OVStore.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVRuntime.h"

static int gFailures = 0;
#define ASSERT(cond) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    @autoreleasepool {
        // pinned specs are fine
        ASSERT(OVIsValidPackageSpec(@"onnxruntime==1.31.1"));
        ASSERT(OVIsValidPackageSpec(@"my-pkg_2.x==2.0.0rc1+cpu"));
        // anything that could be an option, a URL, a path or a range is refused
        NSArray *bad = @[@"--index-url=https://evil.example/simple", @"-e", @"--extra-index-url=x", @"-rfile.txt",
                         @"onnxruntime", @"onnxruntime>=1.0", @"onnxruntime==", @"==1.0", @"a==1.0 --index-url=x",
                         @"a==1.0\n--index-url=x", @"https://evil.example/p.whl", @"./local.whl", @"/tmp/x.whl",
                         @"git+https://x/y.git", @"a @ https://x/y.whl", @"a==1.0;python_version>'3'", @"", @" a==1.0"];
        for (NSString *s in bad) ASSERT(!OVIsValidPackageSpec(s));
        ASSERT(!OVIsValidPackageSpec(nil));
        ASSERT(!OVIsValidPackageSpec((NSString *)@42));

        // installOptionalPackages answers invalid input at once, without starting anything
        __block NSString *err = nil;
        __block int calls = 0;
        [OVRuntime.shared installOptionalPackages:@[@"--index-url=https://evil.example/simple"] title:@"t" progress:nil
                                             done:^(NSString *e) { err = e; calls++; }];
        ASSERT(calls == 1 && err.length > 0);
        err = nil;
        [OVRuntime.shared installOptionalPackages:@[@"onnxruntime==1.31.1", @"-e"] title:@"t" progress:nil
                                             done:^(NSString *e) { err = e; calls++; }];
        ASSERT(calls == 2 && err.length > 0);
        [OVRuntime.shared installOptionalPackages:@[] title:@"t" progress:nil done:^(NSString *e) { err = e; calls++; }];
        ASSERT(calls == 3 && err.length > 0);
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("ok\n");
    return 0;
}
