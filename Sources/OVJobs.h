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

// Threading: OVJobs and OVJob are main-thread only (also their notifications and callbacks). OVJobContext is the
// only thread-safe object; runners may call it from any thread.
// Secrets rule: job.json, request.json, the log and the notifications never hold a secret. Keys of the request named
// token, key, password, secret, authorization (hf_token, api_key, …) are replaced by *** before anything is written.
// The original request stays in memory (runnerRequest) and is used by runners and by retry: within the session.
// After a relaunch a retry of a job whose request had redacted fields is refused ("enter it again").

@interface OVJob : NSObject
@property (readonly, copy) NSString *identifier;     // yyyyMMdd-HHmmss-<6hex>, sortable; the format is fixed (the API checks it)
@property (readonly, copy) NSString *kind, *title, *origin;
@property (readonly) OVJobState state;  @property (readonly) OVJobLane lane;
@property (readonly, copy) NSDate *created;  @property (readonly, nullable, copy) NSDate *started, *finished;
@property (readonly) double progress;                 // 0…1, <0 = indeterminate
@property (readonly, copy) NSString *status;          // the last status line
@property (readonly, nullable, copy) NSString *error; // says what to do about it
/// Machine-readable code of a Failed job ("engine_missing", …), persisted in job.json; nil in other states and for failures without one.
@property (readonly, nullable, copy) NSString *errorCode;
@property (readonly, copy) NSDictionary *request;     // JSON-safe, secrets replaced by ***; this is what is persisted and shown
/// What a runner must use: the original request, kept in memory only for this session (secrets intact). After a
/// relaunch it is the redacted request, so a runner never gets "***" unless the job was loaded from disk.
@property (readonly, copy) NSDictionary *runnerRequest;
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
@optional
/// Immediate and synchronous SIGKILL-style end, used when the app quits and cannot wait for stop to finish.
- (void)kill:(OVJob *)job;
@end

@interface OVJobContext : NSObject                    // thread-safe
@property (readonly) BOOL stopRequested;
/// Temporary files go here only: deleted as a whole on every outcome (unless an output lives inside it).
@property (readonly, copy) NSString *workDirectory;
- (void)setStatus:(NSString *)s;  - (void)setProgress:(double)p;  - (void)log:(NSString *)line;
/// A file to delete on Stopped/Failed. Only regular files qualify, inside the job's work/ folder, the Outputs folder or
/// <tmp>/clonenspeak-<jobId>/; never under jobs/ (other jobs) or voices/. Anything else is ignored (and logged).
- (void)registerPartialPath:(NSString *)path;
/// Fail with stopRequested set ends as Stopped; succeed always ends as Succeeded.
- (void)succeedWithResult:(nullable NSDictionary *)result outputs:(NSArray<NSString *> *)finalPaths;
- (void)failWithError:(NSString *)message;
/// Same, with the machine-readable error code of the worker (for instance "engine_missing"). A Failed job then has
/// errorCode == code; result stays nil (a result belongs to successful jobs only). Stopped jobs get no code.
- (void)failWithError:(NSString *)message code:(nullable NSString *)code;
@end

typedef id<OVJobRunner> _Nonnull (^OVJobRunnerFactory)(OVJob *job);

@class OVJobStore;
@interface OVJobs : NSObject
+ (instancetype)shared;                               // root: <support>/jobs
+ (instancetype)jobsWithRoot:(NSString *)root;        // for tests
@property (readonly) NSArray<OVJob *> *all;           // newest first
@property (readonly) NSUInteger activeCount;
@property (readonly) OVJobStore *store;
/// Registers a kind. Registering the same kind again replaces it (logged). onSuccess is the shared post-processing (for instance the history entry), called on main for any origin.
- (void)registerKind:(NSString *)kind lane:(OVJobLane)lane retryable:(BOOL)retryable
               title:(NSString *(^)(NSDictionary *request))title
             factory:(OVJobRunnerFactory)factory
           onSuccess:(nullable void (^)(OVJob *job))onSuccess;
/// nil + error if the kind is not registered or the queue is full (origin api/bridge: at most 8 active).
- (nullable OVJob *)submitKind:(NSString *)kind request:(NSDictionary *)request origin:(NSString *)origin
                       onFinish:(nullable void (^)(OVJob *job))onFinish error:(NSString *_Nullable *_Nullable)error;
- (void)stop:(OVJob *)job;                            // Queued → Stopped at once; Running → the runner's stop
- (nullable OVJob *)retry:(OVJob *)job;               // same kind + request, new id, retryOf = the old one; nil if !retryable
/// Same, with the reason on nil (for instance a request whose secrets are gone after a relaunch).
- (nullable OVJob *)retry:(OVJob *)job error:(NSString *_Nullable *_Nullable)error;
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
/// Seconds beforeStart may take before the job fails. Default 120.
@property double beforeStartTimeout;
@end
/// The process runs in its own group; stdout is JSON lines like worker.py's:
///   {"event":"status","msg":…} {"event":"progress","value":0…1} {"event":"log","line":…} {"event":"partial","path":…}
///   {"event":"result","data":{…,"outputs":[paths]}} {"event":"error","msg":…}; stderr goes to log.txt.
/// stop: SIGTERM to the group, SIGKILL after killGrace. Exit code ≠ 0 without a result event → Failed "Exit code N".
OVJobRunnerFactory OVProcessRunnerFactory(OVProcessSpec *_Nonnull (^specFor)(OVJob *job));

NS_ASSUME_NONNULL_END
