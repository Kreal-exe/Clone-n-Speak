#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Edge voices on the Speech page: the "Engine" choice of the "Voice and style" card and the Edge block that replaces the
/// OmniVoice controls while Edge is chosen. The spoken text is sent to Microsoft; the block says so and asks OVNetwork
/// (Offline mode, first-use consent) before anything leaves the Mac. The work runs as jobs (the Edge job, then the convert job
/// when "Then change the voice" is on), so leaving the page does not stop it, and finished takes are written to the
/// Speech history by the runs themselves.
@interface OVEdgeTTS : NSObject
/// The "Engine" block: OmniVoice (on this Mac) | Edge TTS (online).
@property (readonly) NSView *engineBlock;
/// The Edge controls; hidden while OmniVoice is chosen.
@property (readonly) NSView *view;
@property (readonly) BOOL selected;                 // Edge is the chosen engine
/// A speech or voice change is queued or running.
@property (readonly) BOOL busy;
/// Why Speak cannot start now (engine missing, Offline mode, no voice), nil when it can. Only meaningful while selected.
@property (readonly, nullable, copy) NSString *problem;
/// Status line and progress (0…1, <0 = none) of the current run.
@property (readonly, copy) NSString *statusLine;
@property (readonly) double progress;
/// Called after any change the page shows: engine choice, readiness, status, progress.
@property (copy, nullable) void (^onChange)(void);
/// Called once per finished take with the WAV that is now in the history.
@property (copy, nullable) void (^onFinished)(NSString *path);

- (void)speak:(NSString *)text window:(nullable NSWindow *)window;
- (void)stop;
/// Re-reads the voice lists and models (the page calls it when it appears).
- (void)refresh;

#pragma mark Pure helpers (unit-tested)
/// "+10%" / "-25%": the signed percent the Edge voice wants, clamped to -50…+100.
+ (NSString *)rateString:(double)percent;
/// "+0Hz": the signed pitch, clamped to -50…+50.
+ (NSString *)pitchString:(double)hz;
/// The voices of one language code ("en"), sorted by name; each is @{ShortName, Locale, Gender, FriendlyName}.
+ (NSArray<NSDictionary *> *)voices:(NSArray<NSDictionary *> *)all forLanguage:(NSString *)language;
/// Sorted unique language codes of a voice list.
+ (NSArray<NSString *> *)languagesOf:(NSArray<NSDictionary *> *)all;
/// The voice list of the cache file (nil when missing or malformed).
+ (nullable NSArray<NSDictionary *> *)readVoiceCache:(NSString *)path;
@end

NS_ASSUME_NONNULL_END
