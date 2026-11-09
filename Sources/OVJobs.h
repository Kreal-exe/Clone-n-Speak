#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on every change of a job or of the list. object: the OVJob, or nil. A change of state is posted at once,
/// progress and status changes at most four times a second.
extern NSNotificationName const OVJobsDidChangeNotification;

typedef NS_ENUM(NSInteger, OVJobState) { OVJobQueued, OVJobRunning, OVJobSucceeded, OVJobFailed, OVJobStopped, OVJobInterrupted };
typedef NS_ENUM(NSInteger, OVJobLane) {
    OVJobLaneCompute,   // OVWorker and the pro engines: one task at a time (memory), FIFO
    OVJobLaneNetwork    // downloads/installs: one at a time, in parallel with compute
};

// Kinds are plain strings and open-ended.
extern NSString *const OVJobKindSynth, *const OVJobKindBatch, *const OVJobKindConvert, *const OVJobKindTrain,
                       *const OVJobKindSeparate, *const OVJobKindInstall, *const OVJobKindDownload, *const OVJobKindPlugin;
// origin: @"app" | @"api" | @"bridge:<deviceId>" | @"plugin:<id>"

@class OVJobContext;

@interface OVJob : NSObject
@property (readonly, copy) NSString *identifier;     // yyyyMMdd-HHmmss-<6hex>, sortable; the format is fixed (the API checks it)
@property (readonly, copy) NSString *kind, *title, *origin;
@property (readonly) OVJobState state;  @property (readonly) OVJobLane lane;
@property (readonly, copy) NSDate *created;  @property (readonly, nullable, copy) NSDate *started, *finished;
@property (readonly) double progress;                 // 0…1, <0 = indeterminate
@property (readonly, copy) NSString *status;          // the last status line
@property (readonly, nullable, copy) NSString *error; // says what to do about it
@property (readonly, copy) NSDictionary *request;     // JSON-safe, secrets replaced by ***
@property (readonly, nullable, copy) NSDictionary *result;  // JSON-safe result (path, seconds, …); in memory and in job.json
@property (readonly, copy) NSArray<NSString *> *outputs;   // absolute paths of the finished files
@property (readonly, nullable, copy) NSString *retryOf;
@property (readonly, copy) NSString *folder, *logPath, *workDirectory;  // jobs/<id>/, log.txt, work/
@property (readonly) BOOL active, retryable;          // active = Queued|Running
- (NSString *)logText;                                // the tail of the log, at most 256 KB
@end

@protocol OVJobRunner <NSObject>                      // one instance per run
/// Must end with exactly one succeed/fail on the context.
- (void)start:(OVJob *)job context:(OVJobContext *)ctx;
/// Asynchronous; the runner then still calls fail/succeed, and the manager decides on Stopped.
- (void)stop:(OVJob *)job;
@end

@interface OVJobContext : NSObject                    // thread-safe
@property (readonly) BOOL stopRequested;
/// Temporary files go here only: deleted as a whole on every outcome (unless an output lives inside it).
@property (readonly, copy) NSString *workDirectory;
- (void)setStatus:(NSString *)s;  - (void)setProgress:(double)p;  - (void)log:(NSString *)line;
/// A file to delete on Stopped/Failed. Accepted only inside Support, Outputs or the temporary directory.
- (void)registerPartialPath:(NSString *)path;
/// Fail with stopRequested set ends as Stopped; succeed always ends as Succeeded.
- (void)succeedWithResult:(nullable NSDictionary *)result outputs:(NSArray<NSString *> *)finalPaths;
- (void)failWithError:(NSString *)message;
@end

typedef id<OVJobRunner> _Nonnull (^OVJobRunnerFactory)(OVJob *job);

@class OVJobStore;
@interface OVJobs : NSObject
+ (instancetype)shared;                               // root: <support>/jobs
+ (instancetype)jobsWithRoot:(NSString *)root;        // for tests
@property (readonly) NSArray<OVJob *> *all;           // newest first
@property (readonly) NSUInteger activeCount;
@property (readonly) OVJobStore *store;
/// Registers a kind. onSuccess is the shared post-processing (for instance the history entry), called on main for any origin.
- (void)registerKind:(NSString *)kind lane:(OVJobLane)lane retryable:(BOOL)retryable
               title:(NSString *(^)(NSDictionary *request))title
             factory:(OVJobRunnerFactory)factory
           onSuccess:(nullable void (^)(OVJob *job))onSuccess;
/// nil + error if the kind is not registered or the queue is full (origin api/bridge: at most 8 active).
- (nullable OVJob *)submitKind:(NSString *)kind request:(NSDictionary *)request origin:(NSString *)origin
                       onFinish:(nullable void (^)(OVJob *job))onFinish error:(NSString *_Nullable *_Nullable)error;
- (void)stop:(OVJob *)job;                            // Queued → Stopped at once; Running → the runner's stop
- (nullable OVJob *)retry:(OVJob *)job;               // same kind + request, new id, retryOf = the old one; nil if !retryable
- (void)remove:(OVJob *)job;  - (void)clearFinished;  // finished jobs only; they delete the job folder
- (nullable OVJob *)jobWithId:(NSString *)identifier;
/// For quitting: everything Stopped, work/ folders deleted. Spins the main run loop up to `timeout` seconds.
- (void)stopAllAndWait:(NSTimeInterval)timeout;
@end

@interface OVJobs (Builtin)
/// App kinds (synth, clone, train, install) on the shared manager. Defined in OVJobsWorker.m (app target only).
+ (void)registerBuiltinKinds;
@end

// Standard runners
/// request is sent to OVWorker as it is (keys starting with "_" are app-side notes and are dropped); waits while
/// OVWorker.busy (direct calls of the pages); stop → [OVWorker stop]. Defined in OVJobsWorker.m.
OVJobRunnerFactory OVWorkerRunnerFactory(void);

@interface OVProcessSpec : NSObject
@property (copy) NSString *executable; @property (copy) NSArray<NSString *> *arguments;
@property (copy) NSDictionary<NSString *, NSString *> *environment;   // exactly this, nothing inherited
@property (copy, nullable) NSString *currentDirectory; @property (copy, nullable) NSData *stdinData;
/// Files to delete when the job ends Stopped/Failed (same rule as registerPartialPath:).
@property (copy, nullable) NSArray<NSString *> *partialPaths;
/// Seconds between SIGTERM and SIGKILL on stop. Default 3.
@property double killGrace;
@property (copy, nullable) void (^beforeStart)(void (^proceed)(BOOL ok, NSString *_Nullable error));  // unload OmniVoice, check memory
@end
/// The process runs in its own group; stdout is JSON lines like worker.py's:
///   {"event":"status","msg":…} {"event":"progress","value":0…1} {"event":"log","line":…} {"event":"partial","path":…}
///   {"event":"result","data":{…,"outputs":[paths]}} {"event":"error","msg":…}; stderr goes to log.txt.
/// stop: SIGTERM to the group, SIGKILL after killGrace. Exit code ≠ 0 without a result event → Failed "Exit code N".
OVJobRunnerFactory OVProcessRunnerFactory(OVProcessSpec *_Nonnull (^specFor)(OVJob *job));

NS_ASSUME_NONNULL_END
