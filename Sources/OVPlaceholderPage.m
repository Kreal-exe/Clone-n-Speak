// Development stand-in for pages that are not built yet. None may remain at release (checked in stage 5).
#import "OVPages.h"
#import "OVPageRegistry.h"
#import "OVDesign.h"
#import "OVUI.h"
#import "OVLocale.h"

@implementation OVPlaceholderPage
- (void)loadView {
    NSView *root = [NSView new];
    self.view = root;
    [self rebuild];
}
- (void)setPageId:(NSString *)pageId {
    _pageId = [pageId copy];
    if (self.isViewLoaded) [self rebuild];
}
- (void)rebuild {
    for (NSView *v in [self.view.subviews copy]) [v removeFromSuperview];
    NSDictionary *e = self.pageId ? [OVPageRegistry entryForPage:self.pageId] : nil;
    NSView *state = OVEmptyState(e[@"symbol"] ?: @"hammer", e[@"title"] ?: L(@"Page"), L(@"This page is not built yet."), @[]);
    state.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:state];
    [NSLayoutConstraint activateConstraints:@[
        [state.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [state.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [state.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-48],
    ]];
}
@end
