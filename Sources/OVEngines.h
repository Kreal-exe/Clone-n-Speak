#import <Foundation/Foundation.h>
#import "OVJobs.h"
#import "OVProRunPlan.h"

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVEnginesDidChangeNotification;
extern NSString *const OVEnginePro;    // @"pro": the shared environment with PyTorch (the name sub-plan D 8.8 asks for)
extern NSString *const OVEngineEdge;   // @"edge"

typedef NS_ENUM(NSInteger, OVEngineState) { OVEngineNotInstalled, OVEngineInstalling, OVEnginePartial, OVEngineReady, OVEngineBroken };

@interface OVEngineComponent : NSObject
@property (readonly, copy) NSString *identifier, *title, *license;
@property (readonly) OVEngineState state;
@property (readonly) unsigned long long downloadBytes, diskBytes;
@property (readonly) BOOL optional;
@end

/// Job kinds of the pro engines (they never collide with the kinds of sub-plan D: synth, train, install, …).
extern NSString *const OVProKindConvert, *const OVProKindRvcImport, *const OVProKindRvcInfo, *const OVProKindRvcFetch,
                       *const OVProKindRvcBlend, *const OVProKindRvcTrain, *const OVProKindRvcReview, *const OVProKindRealtime,
                       *const OVProKindStems, *const OVProKindYouTube, *const OVProKindEdge, *const OVProKindEngineInstall,
                       *const OVProKindEngineWeights, *const OVProKindEngineUpdate;

/// Manager of the pro engines (RVC, Seed-VC, stems, Edge, yt-dlp): the state of every component, installs and
/// removals, and the processes of the pro job kinds. The application knows nothing about torch: everything goes
/// through cns_engines.py (status) and the job manager.
@interface OVEngines : NSObject
+ (instancetype)shared;
/// For tests: another engines folder, another job manager, a main-runtime python (nil = the app's).
+ (instancetype)enginesWithRoot:(NSString *)root jobs:(OVJobs *)jobs mainPython:(nullable NSString *)python;

/// Python of an engine environment: nil until it is Ready (and the interpreter is on disk). Takes OVEnginePro /
/// OVEngineEdge and the logical names rvc|seedvc|realtime|stems|ytdlp|plugins (with layout split: the environment
/// that engine lives in).
+ (nullable NSString *)pythonForEngine:(NSString *)name;
- (nullable NSString *)pythonForEngine:(NSString *)name;
/// The copy of a bundled script in the runtime folder (<runtime>/<script>); copied from the app when it is missing
/// or differs.
+ (NSString *)scriptPath:(NSString *)script;

@property (readonly, copy) NSString *root;                    // <support>/engines
@property (readonly, copy) NSArray<OVEngineComponent *> *components;
@property (readonly, copy) NSString *layout;                  // shared | split
@property (readonly) BOOL proJobActive;                       // any compute-lane pro job is queued or running
/// Whom beforeStart asks (unload, memory); the app sets the live host, tests a fake. nil = no checks.
@property (nullable, strong) id<OVProRunHost> runHost;

- (nullable OVEngineComponent *)componentWithId:(NSString *)identifier;
/// Asynchronous: cns_engines.py status → components → OVEnginesDidChangeNotification.
- (void)refresh;
/// For tests and for the result of uninstall: takes a `status` result.
- (void)applyStatus:(NSDictionary *)status;
- (nullable OVJob *)install:(NSArray<NSString *> *)ids error:(NSString *_Nullable *_Nullable)error;
- (BOOL)uninstall:(NSArray<NSString *> *)ids error:(NSString *_Nullable *_Nullable)error;
- (nullable OVJob *)updateYtDlp:(NSString *_Nullable *_Nullable)error;
/// Peak memory of a run, bytes, from status.peak_gb (the built-in table until the first status).
/// option: pro_convert "seedvc"|"rvc"; rvc_train "batch2"; stems the model id (roformer / mdx families).
- (unsigned long long)peakBytesForKind:(NSString *)kind option:(nullable NSString *)option;
/// The option a request implies for peakBytesForKind:option:.
+ (nullable NSString *)peakOptionForKind:(NSString *)kind request:(NSDictionary *)request;

#pragma mark Kinds (data-driven: later tasks add entries to the table in OVEngines.m)
/// @[@{@"kind", @"lane" (NSNumber OVJobLane), @"retryable", @"heavy" (compute lane: unload + memory), @"net" (OVNetFeature or -1)}]
+ (NSArray<NSDictionary *> *)kindTable;
+ (nullable NSDictionary *)infoForKind:(NSString *)kind;
/// Name of the engine (see pythonForEngine:) a run of this kind needs; nil for kinds that run in the main runtime.
+ (nullable NSString *)engineNameForKind:(NSString *)kind request:(NSDictionary *)request;
/// The process of a job of a pro kind: python of the environment, `-s script command`, the environment dictionary,
/// stdin = the request + work_dir / outputs_dir / job_id / root, sandbox-exec without network for kinds that need none.
- (nullable OVProcessSpec *)specForKind:(NSString *)kind job:(OVJob *)job;
@end

/// Connects to a Unix socket whose path may be longer than the 104 bytes AF_UNIX allows (the realtime engine binds from
/// inside the folder): the working directory is changed for the connect() and restored. Returns the descriptor or -1.
int OVEnginesConnectSocket(NSString *path);

NS_ASSUME_NONNULL_END
