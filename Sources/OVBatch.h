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

/// Registers the "batch" kind (Compute lane, retryable) on the shared manager. Call once at start-up (main.m, task 6.19).
void OVBatchRegister(void);

/// Same on a given manager (tests). `synthFactory` nil = the OVWorker synth.
void OVBatchRegisterOn(OVJobs *jobs, id<OVBatchSynth> _Nullable (^_Nullable synthFactory)(void));

/// Request: {"items":[{"index","text","name"}], "voice": id|null, "language": "auto"|code, "style": {…}, "preset": id|null,
///  "format": "wav"|…, "quality": n (-1 = default), "chain": […] (only with a preset), "outDir": path, "skipExisting": false}.
/// JSON-safe. `name` is the file name from batch_plan; its extension is replaced by the chosen format's.
NSDictionary *OVBatchRequest(NSArray<NSDictionary *> *items, OVVoice *_Nullable v, NSString *language,
                             OVPreset *_Nullable preset, NSString *outDir);

/// Job result: {"done": n, "failed": n, "skipped": n, "outputs": […], "errors": [{"index","error"}]}.

NS_ASSUME_NONNULL_END
