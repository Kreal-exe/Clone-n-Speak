#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Colors
NSColor *OVCardColor(void);
NSColor *OVWindowColor(void);
NSColor *OVAccent(void);                 // brand blue of the app icon
NSColor *OVGreen(void);
NSGradient *OVBrandGradient(void);       // blue → violet: primary buttons, the app's own avatar
/// System font in the rounded design (titles).
NSFont *OVRoundedFont(CGFloat size, NSFontWeight weight);

// Text
NSTextField *OVLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *_Nullable color);
NSTextField *OVWrapLabel(NSString *text, CGFloat size, NSColor *_Nullable color);
NSTextField *OVTitle(NSString *text);
NSTextField *OVSectionTitle(NSString *text);
NSTextField *OVField(NSString *placeholder);

// Controls
NSButton *OVButton(NSString *title, id _Nullable target, SEL _Nullable action);
/// The one main action of a page: a gradient pill.
NSButton *OVPrimaryButton(NSString *title, id _Nullable target, SEL _Nullable action);
NSButton *OVIconButton(NSString *symbol, NSString *tooltip, id _Nullable target, SEL _Nullable action);
NSButton *OVCheckbox(NSString *title, NSString *defaultsKey);
NSImageView *OVSymbol(NSString *name, CGFloat size, NSColor *_Nullable tint);
NSProgressIndicator *OVProgressBar(void);
NSProgressIndicator *OVSpinner(void);

// Layout
NSStackView *OVHStack(NSArray<NSView *> *views, CGFloat spacing);
NSStackView *OVVStack(NSArray<NSView *> *views, CGFloat spacing);
NSView *OVSpacer(void);
/// Rounded card containing `content` with padding.
NSView *OVCard(NSView *content, CGFloat padding);
/// Vertical scroll view whose document is a top-aligned stack filling the width.
NSScrollView *OVScrollPage(NSStackView *content);
void OVPin(NSView *view, NSView *container, NSEdgeInsets insets);
void OVFillWidth(NSArray<NSView *> *views, NSStackView *stack);

/// Round badge with initials on a gradient picked from `name` (every voice gets its own colour).
@interface OVAvatar : NSView
+ (instancetype)avatarWithSize:(CGFloat)size;
/// nil name = the model's own voice ("AI" on the brand gradient).
- (void)setName:(nullable NSString *)name;
@end

/// A slider bound to a user-defaults key with a value label.
@interface OVSliderRow : NSStackView
+ (instancetype)rowWithTitle:(NSString *)title hint:(nullable NSString *)hint key:(NSString *)key
                         min:(double)min max:(double)max format:(NSString *)format integer:(BOOL)integer;
- (void)refresh;
@end

/// Popup bound to a user-defaults key: items are @[@[title, value], …].
NSPopUpButton *OVDefaultsPopup(NSArray<NSArray<NSString *> *> *items, NSString *key, id _Nullable target, SEL _Nullable action);

// Log buffer shared by all log views
NSString *OVLogText(void);
void OVLogAppend(NSString *line);
extern NSNotificationName const OVLogBufferNotification;

NS_ASSUME_NONNULL_END
