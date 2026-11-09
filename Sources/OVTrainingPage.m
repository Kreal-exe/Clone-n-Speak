// Stub: replaced entirely by its own task (7.x). Keeps the registry off OVPlaceholderPage.
#import "OVPages.h"
#import "OVDesign.h"
#import "OVLocale.h"

@implementation OVTrainingPage
- (void)loadView {
    self.view = OVPageScroll(@[OVPageHeader(L(@"Training"), nil, OVProBadge())]);
}
@end
