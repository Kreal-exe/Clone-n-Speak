#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Post with object = page id (@"setup", @"synth", @"voices", @"models", @"settings", @"log").
extern NSNotificationName const OVNavigateNotification;
extern NSNotificationName const OVPlayerDidChangeNotification;

void OVNavigate(NSString *page);
/// Whether the engine and a TTS model are both ready.
BOOL OVEverythingReady(void);

/// Shared audio player for previews and generations.
@interface OVPlayer : NSObject
+ (instancetype)shared;
@property (readonly, nullable) NSString *currentPath;   // loaded file (playing or paused)
@property (readonly) BOOL playing;
@property (readonly) NSTimeInterval currentTime, duration;
- (void)toggle:(NSString *)path;   // play ⇄ pause for the same file, switch otherwise
- (void)play:(NSString *)path;
- (void)pauseOrResume;
- (void)seek:(NSTimeInterval)t;
- (void)stop;
@end

@interface OVSetupPage : NSViewController @end
@interface OVSynthPage : NSViewController
- (void)synthesize:(nullable id)sender;
@end
@interface OVVoicesPage : NSViewController @end
@interface OVModelsPage : NSViewController @end
@interface OVSettingsPage : NSViewController @end
@interface OVLogPage : NSViewController @end
/// Stand-in for pages that are not built yet; the content container sets `pageId` after creating it.
@interface OVPlaceholderPage : NSViewController
@property (nonatomic, copy, nullable) NSString *pageId;
@end
/// Pro-engine pages (16 GB tier); stubs until their own tasks land.
@interface OVConvertPage : NSViewController @end
@interface OVRealtimePage : NSViewController @end
@interface OVTrainingPage : NSViewController @end
@interface OVJobsPage : NSViewController @end
@interface OVBlenderPage : NSViewController @end
/// Developer-only page with every OVDesign component (not in the sidebar; OVNavigate(@"gallery") or -OVStartPage gallery).
@interface OVGalleryPage : NSViewController @end

NS_ASSUME_NONNULL_END
