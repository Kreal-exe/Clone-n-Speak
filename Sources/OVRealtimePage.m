// Stub: replaced entirely by its own task (7.x). Keeps the registry off OVPlaceholderPage.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVLocale.h"

@implementation OVRealtimePage
- (void)loadView {
    self.view = OVPageScroll(@[OVPageHeader(L(@"Realtime"), nil, OVProBadge())]);
}
@end
