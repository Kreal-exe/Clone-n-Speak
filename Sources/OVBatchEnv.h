#import "OVBatch.h"

NS_ASSUME_NONNULL_BEGIN

/// The app's implementation of OVBatchEnvironment (OVWorker, OVSettings, OVVoices, OVHistory, OVPresets). App target only.
@interface OVBatchAppEnvironment : NSObject <OVBatchEnvironment>
/// Presets for the sheet's popup: @[@{@"title": name, @"preset": OVPreset}]; empty while presets are not in the build.
- (NSArray<NSDictionary *> *)presetChoices;
@end

NS_ASSUME_NONNULL_END
