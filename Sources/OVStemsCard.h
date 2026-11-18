#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVStemsKind) { OVStemsKindVocals, OVStemsKindStems, OVStemsKindDereverb };

/// One separation model as the card shows it. The list mirrors cns_stems_catalog.CATALOG (id, license, verified,
/// measured peak); a Python test keeps the two in step.
@interface OVStemsModelInfo : NSObject
@property (readonly, copy) NSString *identifier;      // the catalog id sent as `model`
@property (readonly, copy) NSString *title;            // localized
@property (readonly) OVStemsKind kind;
@property (readonly, copy) NSString *license;          // SPDX id, or @"unverified"
@property (readonly) BOOL verified;
@property (readonly) double peakGB;                    // measured peak memory of a run
@property (readonly) double speed;                     // run time as a multiple of the recording's length (measured)
@property (readonly, copy) NSString *componentId;      // stems-<id>, the weights component of OVEngines
@property (readonly, copy) NSString *licenseNote;      // short, honest caption (localized)
@property (readonly) unsigned long long fallbackBytes; // download size until the engine status is known
+ (NSArray<OVStemsModelInfo *> *)all;
+ (nullable OVStemsModelInfo *)modelWithId:(NSString *)identifier;
/// "Download 67 MB · ≈ 0.4× the length · Needs about 7.2 GB". bytes 0 = the built-in size.
- (NSString *)summaryWithDownloadBytes:(unsigned long long)bytes;
/// Estimated run time in seconds for a recording of `seconds`.
- (NSTimeInterval)estimateForSeconds:(NSTimeInterval)seconds;
@end

@interface OVStemsRequests : NSObject
/// The `stems` job request. output: 0 all stems, 1 vocals, 2 instrumental (a reverb model always gives both parts).
+ (NSDictionary *)requestWithInput:(NSString *)input model:(OVStemsModelInfo *)model output:(NSInteger)output
                            format:(NSString *)format name:(nullable NSString *)name;
/// 'song_vocals.wav' / 'song_vocals (2).flac' gives @"vocals"; nil for any other file name.
+ (nullable NSString *)stemForOutputPath:(NSString *)path;
+ (NSString *)titleForStem:(NSString *)stem;
/// Recordings longer than this get a "will take about N min" warning.
+ (NSTimeInterval)longInputSeconds;
@end

/// The full stem separation card (Separation page, pro). `host` is the window for sheets (nil = the card's own window);
/// `preselectedPath` is loaded as the input when given.
NSView *OVStemsCard(NSWindow *_Nullable host, NSString *_Nullable preselectedPath);

NS_ASSUME_NONNULL_END
