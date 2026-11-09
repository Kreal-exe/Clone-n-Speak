#import <Foundation/Foundation.h>
#import "OVJobs.h"

NS_ASSUME_NONNULL_BEGIN

/// Writable side of OVJob: for OVJobStore and OVJobs only.
@interface OVJob ()
@property (readwrite, copy) NSString *identifier, *kind, *title, *origin, *status, *folder;
@property (readwrite) OVJobState state;  @property (readwrite) OVJobLane lane;
@property (readwrite, copy) NSDate *created;  @property (readwrite, nullable, copy) NSDate *started, *finished;
@property (readwrite) double progress;
@property (readwrite, nullable, copy) NSString *error, *retryOf;
@property (readwrite, copy) NSDictionary *request;
@property (readwrite, nullable, copy) NSDictionary *result;
@property (readwrite, copy) NSArray<NSString *> *outputs;
@property (readwrite) BOOL retryable;
+ (nullable OVJob *)jobFromDictionary:(NSDictionary *)d folder:(NSString *)folder;
- (NSDictionary *)dictionary;
@end

NSString *OVJobStateName(OVJobState s);

/// Foundation-only persistence of jobs: <root>/<id>/{job.json, log.txt, work/}.
@interface OVJobStore : NSObject
- (instancetype)initWithRoot:(NSString *)root;
@property (readonly, copy) NSString *root;
/// The error text of a job found Running/Queued at launch (the app sets a localized one).
@property (copy) NSString *interruptedMessage;
/// Number of job.json files written (for tests).
@property (readonly) NSUInteger writeCount;
+ (BOOL)isValidIdentifier:(NSString *)identifier;
+ (NSString *)newIdentifier;
/// Every readable record, newest first. Corrupt ones are skipped; Queued/Running become Interrupted and their work/ is removed.
- (NSArray<OVJob *> *)loadAll;
/// Atomic write (files 0600, folders 0700).
- (void)save:(OVJob *)job;
/// Same, but at most once a second per job; the latest state is written after the pause (progress, status).
- (void)saveThrottled:(OVJob *)job;
- (void)appendLog:(NSString *)line toJob:(OVJob *)job;
- (void)closeLogOfJob:(OVJob *)job;
/// Deletes the finished jobs beyond the newest 200 and those older than 30 days; active jobs stay. Returns the removed ones.
- (NSArray<OVJob *> *)pruneJobs:(NSArray<OVJob *> *)jobs;
- (void)removeFolderOfJob:(OVJob *)job;
- (void)removeWorkOfJob:(OVJob *)job;
/// Secrets (keys named token, key, password, secret, authorization, hf_token…) replaced by ***; the result is JSON-safe.
+ (id)redact:(id)value;
/// The folders the app may delete in: Support, Outputs, the temporary directory. Set by OVJobs from OVPaths.
@property (class, copy) NSArray<NSString *> *appDataRoots;
/// True if the real path (symlinks resolved, even for a file that does not exist yet) is inside one of appDataRoots.
+ (BOOL)isInsideAppData:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
