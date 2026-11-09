#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// 75.4 → "1:15"; 3725 → "1:02:05"; negative or NaN → "0:00". Seconds are floored (59.99 → "0:59").
NSString *OVFormatTime(NSTimeInterval t);
/// Scrubber position for a click at `x` in a track `width` wide: 0…1, clamped.
double OVScrubberValueForX(CGFloat x, CGFloat width);

/// What OVPlayerBar needs from the shared OVPlayer (which conforms without changes); tests substitute their own.
@protocol OVPlaying <NSObject>
@property (readonly, nullable) NSString *currentPath;
@property (readonly) BOOL playing;
@property (readonly) NSTimeInterval currentTime, duration;
- (void)play:(NSString *)path;
- (void)pauseOrResume;
- (void)seek:(NSTimeInterval)t;
- (void)stop;
@end

/// [play] 0:12 ━━●━━━ 0:34 [Original | Result]. Drives the shared OVPlayer (or `player`).
@interface OVPlayerBar : NSView
@property (nonatomic, copy, nullable) NSString *path;           // the result (B)
@property (nonatomic, copy, nullable) NSString *originalPath;   // set → the Original / Result switch (A/B) is shown
@property (nonatomic, readonly) BOOL showsABSwitch;             // originalPath != nil
@property (nonatomic, readonly) BOOL originalSelected;
/// Substitute for the shared OVPlayer; nil = OVPlayer.shared.
@property (nonatomic, weak, nullable) id<OVPlaying> player;
/// The scrubber (slider role, value "0:12 of 0:34", ←/→ ±1 s).
@property (nonatomic, readonly) NSView *scrubber;
/// A/B: selects the side; when one of the two files is loaded, the other one takes over at the same time in seconds
/// and in the same play/pause state.
- (void)selectOriginal:(BOOL)original;
- (void)stopIfPlayingThis;
/// Re-reads the player now (also runs on OVPlayerDidChangeNotification and on a timer while playing).
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
