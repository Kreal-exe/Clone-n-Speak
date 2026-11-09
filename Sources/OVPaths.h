#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// All on-disk locations used by the app. Models live in the Hugging Face cache (see OVModels).
@interface OVPaths : NSObject
+ (NSString *)support;        // ~/Library/Application Support/Clone'n'Speak
+ (NSString *)runtime;        // …/runtime
+ (NSString *)ownVenv;        // …/runtime/.venv
+ (NSString *)ownPython;      // …/runtime/.venv/bin/python
+ (NSString *)binDir;         // …/runtime/bin (downloaded uv lives here)
+ (NSString *)accent;       // …/accent (optional: Seed-VC for native-accent speech)
+ (NSString *)models;         // …/models (legacy: moved into the HF cache on first run)
+ (NSString *)separationModels; // …/models/separation (music-removal ONNX model, downloaded on demand)
+ (NSString *)voices;         // …/voices
+ (NSString *)logs;           // …/logs
+ (NSString *)workerScript;   // …/runtime/worker.py
+ (NSString *)outputs;        // ~/Music/Clone'n'Speak
+ (NSString *)jobs;           // …/jobs (the task manager's records)
+ (NSString *)engines;       // …/engines (pro engines, downloaded on demand)
+ (NSString *)proEngine;     // …/engines/pro (Python 3.11 env for the 16 GB tier)
+ (NSString *)edgeEngine;    // …/engines/edge (Edge TTS venv)
+ (NSString *)rvc;           // …/rvc
+ (NSString *)rvcModels;     // …/rvc/models (voice models: .pth + .index)
+ (NSString *)rvcTraining;   // …/rvc/training (experiment workspaces)
+ (NSString *)rvcDatasets;   // …/rvc/datasets
+ (void)ensure;

/// Folders of the previous version (OmniVoice UA).
+ (NSString *)legacySupport;
+ (NSString *)legacyPython;
/// One-time move of voices, settings and recordings from OmniVoice UA.
+ (void)migrateFromLegacy;

@end

NSString *OVFormatBytes(long long bytes);
NSString *OVFormatDuration(double seconds);

NS_ASSUME_NONNULL_END
