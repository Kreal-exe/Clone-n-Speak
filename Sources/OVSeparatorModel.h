/* State of the music-removal engine and the request dictionaries the Separation page sends (task 6.17). Foundation only. */
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

/// YES after the first sep_status answer (applyStatus:). Before that nothing may be installed: the license is unknown.
@property (nonatomic, readonly) BOOL statusKnown;
/// The license has to be on screen before anything is downloaded: the page calls -markLicenseShown when it shows it.
/// It counts only when there is a license text to show; without one it stays NO.
@property (nonatomic, readonly) BOOL licenseShown;
- (void)markLicenseShown;
/// YES only once the status is known and the license was shown. Gates the engine and the model download alike.
@property (nonatomic, readonly) BOOL canDownloadModel;

/// Requests for OVWorker / OVJobs. `dir` is OVPaths separationModels.
+ (NSDictionary *)statusRequestWithDirectory:(NSString *)dir;
+ (NSDictionary *)installModelRequestWithDirectory:(NSString *)dir;
+ (NSDictionary *)vocalsRequestWithAudio:(NSString *)audio out:(NSString *)out stem:(NSString *)stem directory:(NSString *)dir;
/// Whether a worker error code means "the engine or model is not installed" (engine_missing).
+ (BOOL)isEngineMissingCode:(nullable NSString *)code;
/// YES when the Mac may be slow at this (less than 12 GB).
+ (BOOL)slowOnMemoryGB:(double)gb;
@end

NS_ASSUME_NONNULL_END
