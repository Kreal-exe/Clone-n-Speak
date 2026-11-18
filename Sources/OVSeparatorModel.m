#import "OVSeparatorModel.h"

NSString *const OVSeparatorOnnxSpec = @"onnxruntime==1.31.1";

@implementation OVSeparatorModel

+ (OVSeparatorState)stateForOnnxruntime:(BOOL)onnx modelReady:(BOOL)model {
    if (!onnx) return OVSeparatorNeedsEngine;
    return model ? OVSeparatorReady : OVSeparatorNeedsModel;
}

+ (NSString *)nameOfState:(OVSeparatorState)state {
    switch (state) {
        case OVSeparatorNeedsEngine: return @"download";
        case OVSeparatorNeedsModel: return @"download model";
        case OVSeparatorReady: return @"ready";
    }
    return @"download";
}

+ (BOOL)modelInstalledInDirectory:(NSString *)dir file:(NSString *)file size:(long long)size {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:file] error:nil];
    return a && [a[NSFileSize] longLongValue] == size;
}

- (OVSeparatorState)state { return [OVSeparatorModel stateForOnnxruntime:self.onnxruntime modelReady:self.modelReady]; }

- (void)applyStatus:(NSDictionary *)s {
    _statusKnown = YES;
    self.onnxruntime = [s[@"onnxruntime"] boolValue];
    self.modelReady = [s[@"model_ready"] boolValue];
    NSDictionary *m = [s[@"model"] isKindOfClass:NSDictionary.class] ? s[@"model"] : nil;
    if ([m[@"license"] isKindOfClass:NSString.class]) self.license = m[@"license"];
    if ([m[@"license_url"] isKindOfClass:NSString.class]) self.licenseURL = m[@"license_url"];
}

- (void)markLicenseShown { if (self.license.length) _licenseShown = YES; }
- (BOOL)canDownloadModel { return self.statusKnown && self.licenseShown; }

+ (NSDictionary *)statusRequestWithDirectory:(NSString *)dir { return @{@"cmd": @"sep_status", @"dir": dir}; }
+ (NSDictionary *)installModelRequestWithDirectory:(NSString *)dir { return @{@"cmd": @"sep_install_model", @"dir": dir}; }
+ (NSDictionary *)vocalsRequestWithAudio:(NSString *)audio out:(NSString *)out stem:(NSString *)stem directory:(NSString *)dir {
    return @{@"cmd": @"sep_vocals", @"audio": audio, @"out": out, @"stem": stem, @"dir": dir};
}

+ (BOOL)isEngineMissingCode:(NSString *)code { return [code isEqualToString:@"engine_missing"]; }
+ (BOOL)slowOnMemoryGB:(double)gb { return gb < 12; }
@end
