#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const OVVoicesDidChangeNotification;
extern NSNotificationName const OVHistoryDidChangeNotification;

#pragma mark - Voices

/// A cloned voice: folder with meta.plist, reference.wav and prompt.pt.
@interface OVVoice : NSObject
@property (copy) NSString *identifier, *folder, *name, *refText;
@property (nullable, copy) NSString *language;   // language spoken in the sample (e.g. "uk"); nil = unknown
@property BOOL languageAuto;                      // the language is detected from the sample, not picked by hand
@property (copy) NSDate *created;
@property double seconds;
@property (readonly) NSString *referencePath, *promptPath;
@property (readonly) BOOL ready;
/// {prompt, audio, ref_text} for the worker (it re-encodes the sample if the prompt is missing).
@property (readonly) NSDictionary *workerSpec;
/// Same, for speech in `language`: when it differs from the sample's language (and accent removal is on),
/// the worker is told where to keep the prompt it adapts to that language.
- (NSDictionary *)workerSpecForLanguage:(nullable NSString *)language;
/// Whether speech in `language` goes through accent removal.
- (BOOL)adaptsToLanguage:(nullable NSString *)language;
/// Languages this voice has already learned to pronounce (adapted-<code>.npz in its folder).
@property (readonly) NSArray<NSString *> *adaptedLanguages;
- (NSString *)adaptedSamplePath:(NSString *)language;
- (void)forgetAdaptations;
- (void)save;
@end

@interface OVVoices : NSObject
+ (instancetype)shared;
@property (readonly) NSArray<OVVoice *> *all;
- (void)reload;
- (OVVoice *)createNamed:(NSString *)name;
- (void)remove:(OVVoice *)v;
- (nullable OVVoice *)voiceWithId:(NSString *)identifier;
@end

#pragma mark - Generations

@interface OVGeneration : NSObject
@property (copy) NSString *path, *text, *voiceName;
@property (nullable, copy) NSString *voiceId;
@property (copy) NSDate *date;
@property double seconds, elapsed;
@property double clarity;                       // 0…1 from auto-improve, <0 = not measured
@property double likeness;                      // 0…1 voice likeness to the sample (ECAPA), <0 = not measured
@property (copy) NSArray<NSDictionary *> *problems;  // phrases that stayed unclear
@end

@interface OVHistory : NSObject
+ (instancetype)shared;
@property (readonly) NSArray<OVGeneration *> *all;
- (void)reload;
- (NSString *)newOutputPathForText:(NSString *)text;
- (void)record:(NSString *)path text:(NSString *)text voice:(nullable OVVoice *)voice result:(NSDictionary *)result;
- (void)remove:(OVGeneration *)g;
@end

#pragma mark - Audio helpers

/// Converts any audio file AVFoundation can read into 24 kHz mono 16-bit WAV.
BOOL OVConvertToWav(NSString *src, NSString *dst, double *_Nullable seconds, NSError **error);
double OVAudioDuration(NSString *path);

#pragma mark - Settings

@interface OVSettings : NSObject
+ (void)registerDefaults;
/// Model spec sent to the worker (path, lora, bits).
+ (nullable NSDictionary *)modelSpec;
/// Generation params sent with synth (expert values from Settings + the voice style of the Speech page).
+ (NSDictionary *)generationParams;
/// Voice style presets: @[@{@"id", @"emoji", @"title", values…}], the first one is neutral.
+ (NSArray<NSDictionary *> *)moods;
+ (void)applyMood:(NSString *)identifier;
/// Whether any style control is away from neutral.
+ (BOOL)styleIsNeutral;
/// Remove the accent of the sample's language when speaking another one.
+ (BOOL)adaptAccent;
+ (NSString *)language; // a language code or "auto"
/// Auto-improve options sent with synth (asr path is added by the caller).
+ (NSDictionary *)improveParams;
+ (double)physicalMemoryGB;
/// Precision for the voice model / Whisper right now (fixed in settings or chosen from free memory).
+ (NSInteger)ttsBits;
+ (NSInteger)asrBits;
/// Keep only one model in memory at a time and drop Whisper right after use (default on ≤12 GB Macs).
+ (BOOL)lowMemory;
@end

NS_ASSUME_NONNULL_END
