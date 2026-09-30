#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVEngineKind) { OVEngineTTS, OVEngineASR };

/// Unified-memory bookkeeping: what is free, what the engine holds, which precision fits.
@interface OVMemory : NSObject
/// Memory macOS can hand out right now (free + inactive + purgeable + speculative pages), bytes.
+ (unsigned long long)availableBytes;
/// Physical footprint of a process (what Activity Monitor calls "Memory"), bytes; 0 if unknown.
+ (unsigned long long)footprintOfPID:(pid_t)pid;
/// Best precision (16, 8 or 4 bits) that fits into `budget` bytes for the given model.
+ (NSInteger)bitsFor:(OVEngineKind)kind budget:(unsigned long long)budget;
/// Rough peak memory of a model at a precision, bytes (used for the choice and the UI).
+ (unsigned long long)needFor:(OVEngineKind)kind bits:(NSInteger)bits;
+ (NSString *)format:(unsigned long long)bytes;   // "2.7 GB"
@end

NS_ASSUME_NONNULL_END
