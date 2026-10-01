#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVWorkerDidChangeNotification;        // started / busy / finished / status
extern NSNotificationName const OVWorkerMemoryDidChangeNotification;  // the once-a-second memory sample

typedef void (^OVWorkerStatus)(NSString *msg);
typedef void (^OVWorkerProgress)(double value);
typedef void (^OVWorkerResult)(NSDictionary *_Nullable data, NSString *_Nullable error);

/// Long-lived Python process running worker.py. One request at a time.
@interface OVWorker : NSObject
+ (instancetype)shared;
@property (readonly) BOOL running, busy;
@property (readonly, nullable) NSString *loadedModelPath;
@property (readonly, copy) NSString *lastStatus;
/// Memory reported by the engine (GB): what it holds now and its peak during the last task.
@property (readonly) double memoryActive, memoryPeak;
/// Live numbers, refreshed every second while the engine runs (bytes).
@property (readonly) unsigned long long engineFootprint, peakFootprint, availableMemory;
/// Memory the next model may use: what is free plus what the engine would release by swapping models.
@property (readonly) unsigned long long memoryBudget;
- (void)resetPeak;

- (void)request:(NSDictionary *)req
         status:(nullable OVWorkerStatus)status
       progress:(nullable OVWorkerProgress)progress
           done:(OVWorkerResult)done;
/// Kills the current job (and the process); its `done` gets "Stopped". The next request starts a fresh process.
- (void)stop;
- (void)shutdown;
@end

NS_ASSUME_NONNULL_END
