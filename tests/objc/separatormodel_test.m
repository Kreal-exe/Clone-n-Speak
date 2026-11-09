// deps: OVSeparatorModel.m
#import <Foundation/Foundation.h>
#import "OVSeparatorModel.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d  ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSString *Name(BOOL onnx, BOOL model) {
    return [OVSeparatorModel nameOfState:[OVSeparatorModel stateForOnnxruntime:onnx modelReady:model]];
}

static void testStateMachine(void) {
    CHECK([Name(NO, NO) isEqualToString:@"download"], "no ORT");
    CHECK([Name(NO, YES) isEqualToString:@"download"], "no ORT even with a model");
    CHECK([Name(YES, NO) isEqualToString:@"download model"], "ORT, no model");
    CHECK([Name(YES, YES) isEqualToString:@"ready"], "both");

    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sep-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSData dataWithBytes:"0123456789" length:10];
    // interrupted install: only the .part
    [d writeToFile:[dir stringByAppendingPathComponent:@"M.onnx.part"] atomically:YES];
    BOOL ready = [OVSeparatorModel modelInstalledInDirectory:dir file:@"M.onnx" size:10];
    CHECK(!ready, ".part is not a model");
    CHECK([Name(YES, ready) isEqualToString:@"download model"], "interrupted -> download model again");
    // truncated final file
    [[d subdataWithRange:NSMakeRange(0, 5)] writeToFile:[dir stringByAppendingPathComponent:@"M.onnx"] atomically:YES];
    CHECK(![OVSeparatorModel modelInstalledInDirectory:dir file:@"M.onnx" size:10], "wrong size");
    [d writeToFile:[dir stringByAppendingPathComponent:@"M.onnx"] atomically:YES];
    CHECK([OVSeparatorModel modelInstalledInDirectory:dir file:@"M.onnx" size:10], "exact size");
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];

    OVSeparatorModel *m = [OVSeparatorModel new];
    [m applyStatus:@{@"onnxruntime": @YES, @"model_ready": @NO, @"model": @{@"license": @"L", @"license_url": @"https://x"}}];
    CHECK(m.state == OVSeparatorNeedsModel && [m.license isEqual:@"L"] && [m.licenseURL isEqual:@"https://x"], "applyStatus");
}

static void testLicenseShownBeforeDownload(void) {
    OVSeparatorModel *m = [OVSeparatorModel new];
    CHECK(!m.licenseShown && !m.canDownloadModel, "license not shown yet -> no download");
    [m markLicenseShown];
    CHECK(!m.licenseShown && !m.canDownloadModel, "no status, no license text: marking does nothing");
    [m applyStatus:@{@"onnxruntime": @NO, @"model_ready": @NO}];
    [m markLicenseShown];
    CHECK(m.statusKnown && !m.licenseShown && !m.canDownloadModel, "status without a license text: still blocked");
    [m applyStatus:@{@"onnxruntime": @NO, @"model_ready": @NO, @"model": @{@"license": @"L"}}];
    CHECK(m.statusKnown && !m.canDownloadModel, "license known but not yet shown: blocked (engine path too)");
    [m markLicenseShown];
    CHECK(m.licenseShown && m.canDownloadModel && m.state == OVSeparatorNeedsEngine, "shown -> download allowed");
}

static void testRequestShape(void) {
    NSDictionary *r = [OVSeparatorModel vocalsRequestWithAudio:@"/a.wav" out:@"/o.wav" stem:@"music" directory:@"/d"];
    NSDictionary *want = @{@"cmd": @"sep_vocals", @"audio": @"/a.wav", @"out": @"/o.wav", @"stem": @"music", @"dir": @"/d"};
    CHECK([r isEqualToDictionary:want], "sep_vocals request");
    CHECK([[OVSeparatorModel installModelRequestWithDirectory:@"/d"] isEqualToDictionary:(@{@"cmd": @"sep_install_model", @"dir": @"/d"})], "install");
    CHECK([[OVSeparatorModel statusRequestWithDirectory:@"/d"] isEqualToDictionary:(@{@"cmd": @"sep_status", @"dir": @"/d"})], "status");
    CHECK([OVSeparatorOnnxSpec isEqual:@"onnxruntime==1.31.1"], "spec");
    CHECK([OVSeparatorModel isEngineMissingCode:@"engine_missing"], "engine missing code");
    CHECK(![OVSeparatorModel isEngineMissingCode:@"bad_param"] && ![OVSeparatorModel isEngineMissingCode:nil], "other codes");
    CHECK([OVSeparatorModel slowOnMemoryGB:8] && ![OVSeparatorModel slowOnMemoryGB:16] && ![OVSeparatorModel slowOnMemoryGB:12], "memory warning");
}

int main(void) {
    @autoreleasepool {
        testStateMachine(); testLicenseShownBeforeDownload(); testRequestShape();
        printf(failures ? "%d failures\n" : "OK\n", failures);
    }
    return failures ? 1 : 0;
}
