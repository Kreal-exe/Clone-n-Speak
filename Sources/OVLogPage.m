#import "OVPages.h"
#import "OVDesign.h"
#import "OVPaths.h"
#import "OVLocale.h"

@interface OVLogPage ()
@property NSTextView *text;
@end

@implementation OVLogPage
- (void)loadView {
    NSTextView *tv = nil;
    NSScrollView *sv = OVLogView(&tv);
    self.text = tv;
    self.text.string = OVLogText();
    self.text.textColor = OVColor(OVRoleText);
    NSButton *copy = OVGhostButton(L(@"Copy all"), @"doc.on.doc", self, @selector(copyAll:));
    NSButton *folder = OVGhostButton(L(@"Logs folder"), @"folder", self, @selector(openLogs:));
    NSView *header = OVPageHeader(L(@"Log"), L(@"What the app and the engine report while they work."), OVHStack(@[copy, folder], 8));
    NSView *card = OVCard(sv, 8);
    [card setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    [card.heightAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    NSStackView *page = OVVStack(@[header, card], 16);
    page.edgeInsets = NSEdgeInsetsMake(24, 28, 28, 28);
    OVFillWidth(page.arrangedSubviews, page);
    NSView *root = [NSView new];
    [root addSubview:page];
    OVPin(page, root, NSEdgeInsetsZero);
    self.view = root;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(line:) name:OVLogBufferNotification object:nil];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewDidAppear { [super viewDidAppear]; [self.text scrollToEndOfDocument:nil]; }
- (void)line:(NSNotification *)n {
    NSTextStorage *ts = self.text.textStorage;
    BOOL atEnd = NSMaxY(self.text.visibleRect) >= NSMaxY(self.text.bounds) - 20;
    [ts appendAttributedString:[[NSAttributedString alloc] initWithString:[n.userInfo[@"line"] stringByAppendingString:@"\n"]
                                                               attributes:@{NSFontAttributeName: self.text.font,
                                                                            NSForegroundColorAttributeName: OVColor(OVRoleText)}]];
    if (ts.length > 300000) [ts deleteCharactersInRange:NSMakeRange(0, ts.length - 200000)];
    if (atEnd) [self.text scrollToEndOfDocument:nil];
}
- (void)copyAll:(id)s {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.text.string forType:NSPasteboardTypeString];
}
- (void)openLogs:(id)s { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:[OVPaths logs]]]; }
@end
