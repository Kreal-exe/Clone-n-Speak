// deps: OVPrivacyCatalog.m OVNetwork.m OVWorker.m OVRuntime.m OVPaths.m OVModels.m OVDownloader.m OVLocale.m OVStore.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVPrivacyCatalog.h"

static int failures = 0;
static void Check(BOOL ok, NSString *what) { if (!ok) { failures++; fprintf(stderr, "FAIL: %s\n", what.UTF8String); } }

int main(void) {
    @autoreleasepool {
        NSString *home = @"/Users/someone";
        NSString *ok = @"/Users/someone/Library/Application Support/Clone'n'Speak";
        Check([OVPrivacyCatalog refusalForDataRoot:ok home:home override:nil isSymlink:NO] == nil, @"normal support folder is allowed");
        Check([OVPrivacyCatalog refusalForDataRoot:@"" home:home override:nil isSymlink:NO] != nil, @"empty refused");
        Check([OVPrivacyCatalog refusalForDataRoot:@"/" home:home override:nil isSymlink:NO] != nil, @"/ refused");
        Check([OVPrivacyCatalog refusalForDataRoot:home home:home override:nil isSymlink:NO] != nil, @"home refused");
        Check([OVPrivacyCatalog refusalForDataRoot:@"/Users/someone/Documents/x" home:home override:nil isSymlink:NO] != nil, @"outside Application Support refused");
        Check([OVPrivacyCatalog refusalForDataRoot:@"/Users/someone/Library/Application Support" home:home override:nil isSymlink:NO] != nil, @"Application Support itself refused");
        Check([OVPrivacyCatalog refusalForDataRoot:ok home:home override:nil isSymlink:YES] != nil, @"symlink refused");
        Check([OVPrivacyCatalog refusalForDataRoot:@"/Users/someone/Library/Application Support/../Documents" home:home override:nil isSymlink:NO] != nil, @"dot-dot escape refused");
        NSString *t = @"/tmp/cns-test-data";
        Check([OVPrivacyCatalog refusalForDataRoot:t home:home override:t isSymlink:NO] == nil, @"OV_DATA_DIR under /tmp allowed");
        Check([OVPrivacyCatalog refusalForDataRoot:t home:home override:nil isSymlink:NO] != nil, @"/tmp without the override refused");
        Check([OVPrivacyCatalog refusalForDataRoot:@"/Users/someone/Desktop" home:home override:@"/Users/someone/Desktop" isSymlink:NO] != nil, @"override outside temp refused");
    }
    return failures ? 1 : 0;
}
