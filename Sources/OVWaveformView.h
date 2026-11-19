#import <Cocoa/Cocoa.h>
#import "OVTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// Waveform with problem regions and a playhead. Core Graphics; colors are OVColor roles resolved at draw time,
/// the view redraws on OVThemeDidChangeNotification. Click/drag seeks; ←/→ seek by 1 s, Shift by 5 s.
@interface OVWaveformView : NSView
/// [[min, max], …] in -1…1, as returned by analyze_audio; any count (resampled to the width).
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *peaks;
/// {start, end, kind, severity}: clipping = OVRoleErr, noise / hum = OVRoleWarn, pause / low_level = hatching in OVRoleMuted.
@property (nonatomic, copy) NSArray<NSDictionary *> *regions;
@property (nonatomic) NSTimeInterval duration, position;
@property (nonatomic, copy, nullable) void (^onSeek)(NSTimeInterval t);
@property (nonatomic, copy, nullable) void (^onRegionHover)(NSDictionary *_Nullable region);

/// Optional trim selection. Enabled: the parts outside [trimStart, trimEnd] are dimmed and two handles (grab area 12 pt)
/// move the edges; a click elsewhere still seeks. Keys: `[` sets the start and `]` the end at the playhead.
/// VoiceOver sees "Trim start" / "Trim end" as adjustable (0.1 s per step). The kept part is never shorter than OVTrimMinKeep.
@property (nonatomic) BOOL trimEnabled;
/// Seconds. Setters clamp (start < end, kept part >= OVTrimMinKeep, inside 0…duration); a change of `duration` re-clamps.
@property (nonatomic) NSTimeInterval trimStart, trimEnd;
/// Called when the user (mouse, keys, VoiceOver) moves a handle, not for changes made in code.
@property (nonatomic, copy, nullable) void (^onTrimChange)(NSTimeInterval start, NSTimeInterval end);
/// Sets both edges at once, clamped.
- (void)setTrimStart:(NSTimeInterval)start end:(NSTimeInterval)end;
@end

NS_ASSUME_NONNULL_END
