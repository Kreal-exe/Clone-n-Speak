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

/// "Advanced"-style block that folds its content (height animation 0.3 s, instant under Reduce Motion).
@interface OVDisclosure : NSView
+ (instancetype)disclosureWithTitle:(NSString *)t subtitle:(nullable NSString *)s symbol:(nullable NSString *)sym content:(NSView *)c;
@property (nonatomic) BOOL expanded;
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;
@end

/// Segmented switch: radio group of radio buttons; ←/→ change the selection and send the action.
@interface OVSegmented : NSControl
+ (instancetype)segmentedWithItems:(NSArray<NSArray<NSString *> *> *)items;   // @[@[title, symbolOrEmpty]]
@property (nonatomic) NSInteger selectedIndex;
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
NSView *OVBadge(NSString *text, OVRole tone);   // OVRoleMuted | OVRoleOK | OVRoleWarn | OVRoleErr
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

NS_ASSUME_NONNULL_END
