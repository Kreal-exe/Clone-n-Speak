// deps: OVNetwork.m OVPrivacyCatalog.m OVWorker.m OVRuntime.m OVPaths.m OVModels.m OVDownloader.m OVLocale.m OVStore.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVModels.h"

static int gFailures = 0;
#define ASSERT(...) do { if (!(__VA_ARGS__)) { gFailures++; fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #__VA_ARGS__); } } while (0)

int main(void) {
    @autoreleasepool {
        // precedence: Settings folder, HF_HUB_CACHE, HF_HOME/hub, the default
        ASSERT([[OVModels hubCacheWithOverride:nil environment:@{} home:@"/Users/x"] isEqual:@"/Users/x/.cache/huggingface/hub"]);
        ASSERT([[OVModels hubCacheWithOverride:@"" environment:@{} home:@"/Users/x"] isEqual:@"/Users/x/.cache/huggingface/hub"]);
        ASSERT([[OVModels hubCacheWithOverride:nil environment:@{@"HF_HOME": @"/h"} home:@"/Users/x"] isEqual:@"/h/hub"]);
        ASSERT([[OVModels hubCacheWithOverride:nil environment:@{@"HF_HOME": @"/h", @"HF_HUB_CACHE": @"/c"} home:@"/Users/x"] isEqual:@"/c"]);
        ASSERT([[OVModels hubCacheWithOverride:@"/Volumes/980PRO/.cache/huggingface/hub" environment:@{@"HF_HUB_CACHE": @"/c"} home:@"/Users/x"]
                isEqual:@"/Volumes/980PRO/.cache/huggingface/hub"]);

        // a folder on a volume that is not mounted
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSString *vols = [tmp stringByAppendingPathComponent:@"Volumes"];
        [NSFileManager.defaultManager createDirectoryAtPath:[vols stringByAppendingPathComponent:@"Here"] withIntermediateDirectories:YES attributes:nil error:nil];
        ASSERT([[OVModels disconnectedVolumeForFolder:[vols stringByAppendingPathComponent:@"Gone/.cache/hub"] volumesRoot:vols] isEqual:@"Gone"]);
        ASSERT([OVModels disconnectedVolumeForFolder:[vols stringByAppendingPathComponent:@"Here/.cache/hub"] volumesRoot:vols] == nil);
        ASSERT([OVModels disconnectedVolumeForFolder:@"/Users/x/.cache/hub" volumesRoot:vols] == nil);
        ASSERT([OVModels disconnectedVolumeForFolder:vols volumesRoot:vols] == nil);
        ASSERT([OVModels disconnectedVolumeForFolder:[vols stringByAppendingString:@"2/Gone/x"] volumesRoot:vols] == nil);   // not below the root

        // free space: a folder that does not exist yet asks its nearest existing parent
        ASSERT([OVModels freeBytesForFolder:[tmp stringByAppendingPathComponent:@"a/b/c"]] > 0);
        ASSERT([OVModels freeBytesForFolder:@"/definitely/not/here/at/all"] > 0);   // "/" exists

        // only https endpoints are used
        ASSERT([OVModels endpointIsSecure:@"https://huggingface.co"]);
        ASSERT([OVModels endpointIsSecure:@" https://hf-mirror.com/ "]);
        ASSERT(![OVModels endpointIsSecure:@"http://127.0.0.1:1"]);
        ASSERT(![OVModels endpointIsSecure:@"huggingface.co"]);
        ASSERT(![OVModels endpointIsSecure:@"https://"]);
        ASSERT(![OVModels endpointIsSecure:@""]);
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    printf("model folder: ok\n");
    return 0;
}
