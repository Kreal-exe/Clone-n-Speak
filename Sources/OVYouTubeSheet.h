#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Client-side mirror of cns_ytdl.parse_url: one video on www.youtube.com / music.youtube.com (/watch?v=ID) or youtu.be/ID,
/// https only, no credentials, port 443 or none. YES = acceptable (canonical = the link the engine will fetch, the
/// same one cns_ytdl builds); NO = the reason, in words the user can act on (nothing starts then).
BOOL OVYouTubeCheckURL(NSString *_Nullable url, NSString *_Nullable *_Nullable canonical, NSString *_Nullable *_Nullable reason);

/// Import of one YouTube video's audio as a WAV, as a sheet: the link (checked here by the same rules as in the engine, with the
/// reason when it is refused), two required confirmations (rights to the recording, the speaker's agreement), the Offline mode and
/// network-consent gates, the ffmpeg notice, progress, Stop and "Update yt-dlp". The download is the `yt_import` pro job.
@interface OVYouTubeSheet : NSWindowController
/// `dir`: where the WAV is written (nil = the Outputs folder). `done` runs once, on main: the file, or nil when the user
/// cancelled or the download was stopped (a failure keeps the sheet open with the reason until the user cancels).
+ (void)presentOnWindow:(NSWindow *)w destinationDirectory:(nullable NSString *)dir completion:(void (^)(NSURL *_Nullable file))done;
@end

NS_ASSUME_NONNULL_END
