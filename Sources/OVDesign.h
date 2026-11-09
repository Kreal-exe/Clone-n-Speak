#import <Cocoa/Cocoa.h>
#import "OVUI.h"
#import "OVTheme.h"

NS_ASSUME_NONNULL_BEGIN

/// A view with a flat fill, a 1px border and rounded corners, all from dynamic colors resolved at draw time.
@interface OVBoxView : NSView
+ (instancetype)boxWithFill:(nullable NSColor *)fill border:(nullable NSColor *)border radius:(CGFloat)radius;
@property (nonatomic, nullable) NSColor *fillColor, *borderColor;
@property (nonatomic) CGFloat radius, borderWidth;
@end

/// Card header: step number (0 = none), SF Symbol, title, accessory (badge or ghost button) on the right.
NSView *OVCardHeader(NSInteger step, NSString *_Nullable symbol, NSString *title, NSView *_Nullable accessory);
/// A card with a header, an optional muted subtitle and `content`.
NSView *OVStepCard(NSInteger step, NSString *_Nullable symbol, NSString *title, NSString *_Nullable subtitle, NSView *content);

/// Like OVStepCard, with an accessory (badge or ghost button) on the right of the header and no subtitle. Content spacing 16.
NSView *OVStepCardWithAccessory(NSInteger step, NSString *_Nullable symbol, NSString *title, NSView *_Nullable accessory, NSView *content);
/// A vertical stack (spacing `spacing`) whose arranged views all fill its width.
NSStackView *OVFillStack(NSArray<NSView *> *views, CGFloat spacing);
/// A popup is a button to OVFieldBlock/OVColumns, which keep it at its natural width: this wraps it in a stack that fills.
NSView *OVFillPopup(NSView *popup);

/// "Advanced"-style block that folds its content (height animation 0.3 s, instant under Reduce Motion).
@interface OVDisclosure : NSView
+ (instancetype)disclosureWithTitle:(NSString *)t subtitle:(nullable NSString *)s symbol:(nullable NSString *)sym content:(NSView *)c;
@property (nonatomic) BOOL expanded;
@property (nonatomic, copy, nullable) NSString *subtitle;   // muted line under the title; can change while the page is shown
@property (nonatomic, copy, nullable) void (^onToggle)(BOOL expanded);   // after the user folded or unfolded it (not for setExpanded:)
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
@end

/// Segmented switch: radio group of radio buttons; ←/→ change the selection and send the action.
@interface OVSegmented : NSControl
/// @[@[title, symbolOrEmpty]] or @[@[title, symbol, label]]. The optional 3rd element is the segment's accessibilityLabel and toolTip
/// (for icon-only segments: pass an empty title).
+ (instancetype)segmentedWithItems:(NSArray<NSArray<NSString *> *> *)items;
@property (nonatomic) NSInteger selectedIndex;   // -1 = nothing selected
@end

/// Slider that uses OVSliderCell.
@interface OVSlider : NSSlider
@end
/// 6px track, accent fill, 16px knob with a ring in the background color.
@interface OVSliderCell : NSSliderCell
@end

/// Flat pill button: CTA fill (ghost = transparent with a 1px border). OVPrimaryButton and OVGhostButton build on it.
NSButton *OVPillButtonMake(NSString *title, NSString *_Nullable symbol, id _Nullable target, SEL _Nullable action, BOOL ghost);
NSButton *OVGhostButton(NSString *title, NSString *_Nullable symbol, id _Nullable target, SEL _Nullable action);
/// Sets the height of a pill button (default 36; with or without an icon the height is the same). Other buttons get a constraint.
NSButton *OVButtonHeight(NSButton *b, CGFloat height);
/// Compact pill for list rows: 13 pt semibold text, 30 pt high.
NSButton *OVSmallPill(NSButton *b);
NSView *OVBadge(NSString *text, OVRole tone);   // OVRoleMuted | OVRoleAccent | OVRoleOK | OVRoleWarn | OVRoleErr
NSView *OVCompactBadge(NSString *text, OVRole tone);  // smaller OVBadge for dense rows
NSView *OVProBadgeCompact(void);                // same, smaller: sidebar rows
NSView *OVProBadge(void);                       // "16 GB", warn tone, tooltip says why
/// On a Mac with less than 16 GB: an alert that memory may run out; YES = go on. Otherwise YES without asking.
BOOL OVConfirmProRun(NSWindow *_Nullable w);

/// Dashed drop target; click opens a file panel. `onFiles` is stored by the zone: capture self weakly in it. `exts` are lowercase extensions without the dot.
@interface OVDropZone : NSView
+ (instancetype)zoneWithTitle:(NSString *)t hint:(nullable NSString *)h types:(NSArray<NSString *> *)exts
                      onFiles:(void (^)(NSArray<NSURL *> *))cb;
@end

NSView *OVEmptyState(NSString *symbol, NSString *title, NSString *_Nullable text, NSArray<NSButton *> *buttons);
/// Round 32px play button; set `.image` to swap the glyph (e.g. pause.fill).
NSButton *OVPlayButton(id _Nullable target, SEL _Nullable action);
NSScrollView *OVLogView(NSTextView *_Nullable *_Nullable outText);

#pragma mark - Page-level helpers

/// `role` with `alpha` (multiplied into the palette color's own alpha); stays dynamic, resolves at draw time.
NSColor *OVColorAlpha(OVRole role, CGFloat alpha);
/// Walks every window: redraws, re-applies text/tint colors and scroll backgrounds. Runs on OVThemeDidChangeNotification (see +load of OVBoxView).
void OVRepaintAll(void);

/// Page title (28 bold, tracking -0.025em), optional muted 14 pt subtitle, optional accessory (button/badge) on the right; 4 pt below.
NSView *OVPageHeader(NSString *title, NSString *_Nullable subtitle, NSView *_Nullable accessory);
/// Same, with `wrapSubtitle` = the subtitle wraps over several lines inside the column instead of staying on one.
NSView *OVPageHeaderWrapped(NSString *title, NSString *_Nullable subtitle, NSView *_Nullable accessory, BOOL wrapSubtitle);
/// Changes the title of a header made by OVPageHeader (keeps the 28 bold look and tracking; the tooltip shows the full title).
void OVPageHeaderSetTitle(NSView *header, NSString *title);
/// The standard page: OVVStack spacing 16, insets (24, 28, 28, 28), every view fills the width, inside OVScrollPage.
NSScrollView *OVPageScroll(NSArray<NSView *> *views);
/// Field label (14 semibold), the control (fills the width unless it is a button/switch/segmented), muted 13 pt hint below.
NSView *OVFieldBlock(NSString *label, NSString *_Nullable hint, NSView *control);
/// A checkbox (or radio) with its muted 13 pt hint indented by 24 below it.
NSView *OVCheckRow(NSButton *check, NSString *_Nullable hint);
/// Equal-width columns, each at least 260 pt; when the width cannot fit them they stack vertically. Top-aligned.
NSView *OVColumns(NSArray<NSView *> *cols, CGFloat gap);
/// Round radio button drawn by hand. Exclusive by itself: clicking (or Space/Return) turns on this button and turns off its siblings
/// in the same superview that have the same target and action.
NSButton *OVRadioButton(NSString *title, id _Nullable target, SEL _Nullable action);
/// Wraps NSScrollView.scrollableTextView in a field-colored box (text, caret and typing color come from OVRoleText) (1px border, radius 10, OVRoleFocus border while the text view has focus).
NSView *OVTextArea(NSScrollView *textScroll, CGFloat minHeight);

/// Buttons (or any views) in a row that wraps onto further lines when it is too narrow. Height follows the wrapping.
@interface OVFlowRow : NSView
@property (nonatomic, readonly) NSArray<NSView *> *items;
@property (nonatomic) BOOL centered;   // every line centered instead of left-aligned
- (void)setItems:(NSArray<NSView *> *)items;
@end

/// Quality bar: 6 pt track (field color), fill turns from error to warning to OK at 45 and 70. Resolves colors while drawing.
@interface OVMeterBar : NSView
@property (nonatomic) double doubleValue;   // 0...100
@end

/// Secure text field in the look of OVField (field fill, 1px border, radius 10, OVRoleFocus border while editing), 34 pt high.
NSSecureTextField *OVSecureField(NSString *_Nullable placeholder);

/// 36 x 20 switch: on = OVRoleCTA track with an OVRoleCTAText knob. Space/Return toggle it and send the action.
@interface OVSwitch : NSControl
@property (nonatomic) BOOL on;
@end

/// Table row: selection is an OVRoleAccentSoft plate (radius 8, inset 4), hover is an OVRoleField plate; no system blue.
@interface OVTableRowView : NSTableRowView
@property (nonatomic) BOOL hovered;   // follows the mouse; settable for static previews
@end

NS_ASSUME_NONNULL_END
