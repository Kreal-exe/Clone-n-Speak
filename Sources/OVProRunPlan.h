#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the pre-flight of a pro run needs from the app. Injected, so the order of the steps can be tested.
@protocol OVProRunHost <NSObject>
- (double)physicalMemoryGB;
/// A Mac with less than 16 GB: "this may run out of memory". YES = go on.
- (BOOL)confirmLowMemory;
/// Frees OmniVoice and Whisper (the main engine process).
- (void)unloadMainModels;
/// Memory macOS can hand out right now, bytes.
- (unsigned long long)availableBytes;
/// What unloadMainModels would give back (the main engine's footprint), bytes; 0 when nothing is loaded.
- (unsigned long long)reclaimableBytes;
@optional
/// Seconds to wait after unloadMainModels before the memory is read for real (the process needs a moment to exit).
- (NSTimeInterval)settleDelay;
@required
/// Not enough free memory: shows the numbers. YES = run anyway.
- (BOOL)askLowFreeNeed:(unsigned long long)need available:(unsigned long long)avail;
/// Offline mode / first-use consent of a network feature. May answer later (a sheet).
- (void)requestNetwork:(void (^)(BOOL allowed))done;
/// Hands the request to the job manager. reduced = the lighter variant (training with batch size 2).
- (void)submitReducedBatch:(BOOL)reduced;
@end

typedef NS_ENUM(NSInteger, OVProRunOutcome) { OVProRunSubmitted, OVProRunDeclined };

/// The strict order of a pro run: 1 network (if the feature needs it), 2 the 16 GB confirmation, 3 unload the main
/// models, 4 the memory check, 5 submit. A refusal at step 1 or 2 leaves the models loaded. The memory question is
/// asked before the unload too, counting what the unload will free (available + reclaimable), so that a "no" there
/// leaves them loaded as well; after the unload the real free memory is checked once more (silently when the user
/// already agreed).
@interface OVProRunPlan : NSObject
/// Free memory must reach peak × 1.15.
+ (unsigned long long)needForPeak:(unsigned long long)peak;
/// peakBytes 0 = no memory check. reducedPeakBytes > 0: a lighter variant (training with batch 2) that is tried when
/// the full one does not fit, before the user is asked.
+ (instancetype)planWithPeakBytes:(unsigned long long)peak reducedPeakBytes:(unsigned long long)reduced
                     needsNetwork:(BOOL)net heavy:(BOOL)heavy;
@property (readonly) BOOL needsNetwork;
/// Network-lane features (Edge, YouTube, downloads) do not compete for memory: heavy = NO skips steps 2 to 4.
@property (readonly) BOOL heavy;
/// A light job (checking or importing a model file) skips the confirmation and the unload but still asks when even
/// its small peak does not fit.
@property BOOL memoryCheckOnly;
/// Whether the user already agreed to run on little free memory (the job re-checks silently then).
@property BOOL lowFreeAccepted;

- (void)executeWithHost:(id<OVProRunHost>)host completion:(void (^)(OVProRunOutcome outcome, BOOL reducedBatch))done;

/// Steps 3 and 4 again, for a job that starts later (from the queue or from the API). Synchronous. NO + error when the
/// user (or, with lowFreeAccepted, nobody) declines. reduced is set when the lighter variant is the one that fits.
- (BOOL)prepareToStartWithHost:(id<OVProRunHost>)host reduced:(BOOL *)reduced;
@end

NS_ASSUME_NONNULL_END
