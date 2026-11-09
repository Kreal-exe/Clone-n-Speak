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
@end

NS_ASSUME_NONNULL_END
