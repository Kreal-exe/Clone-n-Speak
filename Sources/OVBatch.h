#import <Foundation/Foundation.h>
#import "OVJobs.h"

NS_ASSUME_NONNULL_BEGIN

@class OVVoice, OVPreset;

/// Synthesis of one item. The app uses OVWorker (the model stays loaded between items); tests replace it.
@protocol OVBatchSynth <NSObject>
/// `req` is a complete worker "synth" request ("out" is the WAV master to write). `done` runs on the main thread:
/// data (with "path") or an error text. Progress is 0…1 within the item.
- (void)synthesize:(NSDictionary *)req progress:(void (^)(double))progress
              done:(void (^)(NSDictionary *_Nullable data, NSString *_Nullable error))done;
/// Ends a synthesis in progress (its `done` then answers with an error).
- (void)stop;
@end

/// Everything the runner needs from the app, behind one typed interface (the app implements it in OVBatchEnv.m, tests stub it).
@protocol OVBatchEnvironment <NSObject>
- (nullable NSDictionary *)modelSpec;
- (NSDictionary *)generationParams;
/// nil when the voice does not exist (any more) or is not ready.
- (nullable NSDictionary *)voiceSpecForId:(NSString *)voiceId language:(nullable NSString *)language;
- (nullable NSString *)identifierOfVoice:(OVVoice *)voice;
/// {identifier, style, formatId, quality, chain} of a preset; keys may be missing.
- (NSDictionary *)presetFields:(OVPreset *)preset;
/// The Outputs folder: only files written there are added to the Speech history (nil = never).
- (nullable NSString *)historyFolder;
- (void)recordHistoryPath:(NSString *)path text:(NSString *)text voiceId:(nullable NSString *)voiceId result:(NSDictionary *)result;
/// A new synthesizer for one job.
- (id<OVBatchSynth>)makeSynth;
@end

/// Registers the "batch" kind (Compute lane, retryable) on the shared manager with the app environment.
/// Call once at start-up (main.m, task 6.19). Defined in OVBatchEnv.m.
void OVBatchRegister(void);

/// Same on a given manager with a given environment (tests). The environment is also what OVBatchRequest reads.
void OVBatchRegisterOn(OVJobs *jobs, id<OVBatchEnvironment> env);

/// Request: {"items":[{"index","text","name"}], "voice": id|null, "language": "auto"|code, "style": {…}, "preset": id|null,
///  "format": "wav"|… (absent: the caller picks; the runner defaults to wav), "quality": n (-1 = default), "chain": […] (only with a preset), "outDir": path, "skipExisting": false}.
/// JSON-safe. `name` is the file name from batch_plan; its extension is replaced by the chosen format's.
NSDictionary *OVBatchRequest(NSArray<NSDictionary *> *items, OVVoice *_Nullable v, NSString *language,
                             OVPreset *_Nullable preset, NSString *outDir);

/// Job result: {"done": n, "failed": n, "skipped": n, "outputs": […], "errors": [{"index","error"}]}.

NS_ASSUME_NONNULL_END
