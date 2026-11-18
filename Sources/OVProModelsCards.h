#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// "Voice models (RVC)" card of the Models page: the installed voice models (info, reveal, rename, delete), a Hugging Face
/// search, a link field and an import drop zone. Downloads and imports run as OVJobs through OVProRun.
NSView *OVRvcModelsCard(void);

/// "Pro engines" card of the Models page: every engine component with its state, size and license and the buttons
/// Install / Finish installing / Repair / Remove, the yt-dlp version with Update, and the Python environment layout.
NSView *OVProEnginesCard(void);

NS_ASSUME_NONNULL_END
