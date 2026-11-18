/* Logic of the Audio Tools page (task 6.16): worker request dictionaries, the long-file rule, how a picked file reaches the worker,
   the format list. Foundation only, so it is tested without the page. */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OVToolsMode) { OVToolsModeEffects, OVToolsModeFormant, OVToolsModeCleanup, OVToolsModeConvert };

/// Longest file the tools take: 20 minutes (the same limit as cns_core.MAX_SECONDS).
extern const NSTimeInterval OVToolsMaxSeconds;
/// The DeepFilterNet attenuation limit slider (dB).
extern const double OVToolsDFNMinDB, OVToolsDFNMaxDB, OVToolsDFNDefaultDB;

/// Decoder of a non-WAV file into a WAV (OVDecodeAudio on the page; a stub in tests).
typedef BOOL (^OVToolsDecoder)(NSString *src, NSString *dstWav, NSError *_Nullable *_Nullable error);

@interface OVToolsModel : NSObject

#pragma mark Requests
/// {"cmd":"fx_apply","audio","out","chain"}: the chain without the effects that are off.
+ (NSDictionary *)effectsRequestWithAudio:(NSString *)audio out:(NSString *)out chain:(NSArray<NSDictionary *> *)chain;
/// YES when at least one effect of the chain is on.
+ (BOOL)chainHasActiveEffects:(NSArray<NSDictionary *> *)chain;
/// Formant ratio (1 = off) and/or pitch semitones (0 = off): the request dictionaries to run in order, the first reads `audio`,
/// the last writes `out`, the one between goes through `tmp`. Empty when both are neutral.
/// Pitch (pitch_apply, preserve_formants = keepCharacter) comes first, the formant ratio (formant_apply) second.
+ (NSArray<NSDictionary *> *)formantStepsWithAudio:(NSString *)audio out:(NSString *)out tmp:(NSString *)tmp
                                             ratio:(double)ratio semitones:(double)semitones keepCharacter:(BOOL)keep;
/// 12 * log2(ratio); 0 for a ratio that is not positive.
+ (double)semitonesForRatio:(double)ratio;
/// DeepFilterNet: not installed -> {"action":"download"}, nothing else; installed -> {"action":"run","request":{dfn_apply...}}.
+ (NSDictionary *)dfnPlanInstalled:(BOOL)installed audio:(NSString *)audio out:(NSString *)out strengthDB:(double)db;
/// "Light cleanup": the old spectral gate of the `enhance` command.
+ (NSDictionary *)lightCleanupRequestWithAudio:(NSString *)audio out:(NSString *)out;

#pragma mark Input
/// A longer file than 20 minutes -> the text for the warning (English, localize on the page); otherwise nil.
+ (nullable NSString *)longFileWarningForSeconds:(NSTimeInterval)seconds;
/// WAV files go to the worker as they are; everything else (MP3, M4A, video...) is decoded first.
+ (BOOL)needsDecodeForPath:(NSString *)path;
/// The path the worker may read: `path` itself for a WAV, otherwise a decoded copy in `workDir` made by `decoder`
/// (called before anything reaches the worker). nil + error when decoding fails.
+ (nullable NSString *)workerInputForPath:(NSString *)path workDir:(NSString *)workDir decoder:(OVToolsDecoder)decoder
                                    error:(NSError *_Nullable *_Nullable)error;

#pragma mark Formats
/// nil when the format of OVExport.formats is available, otherwise the reason (the format's own, or a default one).
+ (nullable NSString *)disabledReasonForFormat:(NSDictionary *)format;
/// Quality choices of a format id: @[@[title, @(value)]] (kbps for m4a/mp3, 0...10 for ogg); empty for lossless formats.
+ (NSArray<NSArray *> *)qualityChoicesForFormatId:(NSString *)formatId;
/// The default value among the choices (192 kbps, ogg 5), or -1 when there are no choices.
+ (NSInteger)defaultQualityForFormatId:(NSString *)formatId;
@end

NS_ASSUME_NONNULL_END
