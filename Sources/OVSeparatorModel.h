/* State of the music-removal engine and the requests the Separation page sends (task 6.17). Foundation only. */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVSeparatorState) {
    OVSeparatorNeedsEngine,   // onnxruntime missing -> "download"
    OVSeparatorNeedsModel,    // onnxruntime there, model missing or half-downloaded -> "download model"
    OVSeparatorReady          // both -> "ready"
};

extern NSString *const OVSeparatorOnnxSpec;   // @"onnxruntime==1.31.1": the one pinned spec the page installs

@interface OVSeparatorModel : NSObject
/// Pure: engine + model flags -> state.
+ (OVSeparatorState)stateForOnnxruntime:(BOOL)onnx modelReady:(BOOL)model;
/// "download" | "download model" | "ready".
+ (NSString *)nameOfState:(OVSeparatorState)state;
/// The model counts as installed only as the final file with the exact size; a ".part" never does.
+ (BOOL)modelInstalledInDirectory:(NSString *)dir file:(NSString *)file size:(long long)size;

/// Filled from sep_status (onnxruntime, model_ready, model.license, model.license_url).
@property (nonatomic) BOOL onnxruntime, modelReady;
@property (nonatomic, copy, nullable) NSString *license, *licenseURL;
@property (nonatomic, readonly) OVSeparatorState state;
- (void)applyStatus:(NSDictionary *)status;

/// The license has to be on screen before the model is downloaded: the page calls -markLicenseShown when it shows it.
@property (nonatomic, readonly) BOOL licenseShown;
- (void)markLicenseShown;
/// NO until the license was shown (the first press of "Download engine" only shows it).
@property (nonatomic, readonly) BOOL canDownloadModel;

/// Requests for OVWorker / OVJobs. `dir` is OVPaths separationModels.
+ (NSDictionary *)statusRequestWithDirectory:(NSString *)dir;
+ (NSDictionary *)installModelRequestWithDirectory:(NSString *)dir;
+ (NSDictionary *)vocalsRequestWithAudio:(NSString *)audio out:(NSString *)out stem:(NSString *)stem directory:(NSString *)dir;
/// Whether an error text means "the engine or model is not installed" (worker code engine_missing).
+ (BOOL)isEngineMissingMessage:(NSString *)message;
/// YES when the Mac may be slow at this (less than 12 GB).
+ (BOOL)slowOnMemoryGB:(double)gb;
@end

NS_ASSUME_NONNULL_END
