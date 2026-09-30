#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const OVAppName;                         // "Clone'n'Speak"
extern NSNotificationName const OVUILanguageDidChangeNotification;
extern NSNotificationName const OVSpeechLanguageDidChangeNotification;

/// Localized UI string. Keys are the English text; translations live in <lang>.lproj/Localizable.strings.
NSString *L(NSString *english);

@interface OVLocale : NSObject
/// Interface language actually in use: "en" or "ru".
+ (NSString *)uiLanguage;
/// User choice: "system", "en" or "ru". Posts OVUILanguageDidChangeNotification.
+ (NSString *)uiLanguageSetting;
+ (void)setUILanguageSetting:(NSString *)value;

// Speech languages (OmniVoice supports 600+; the two-letter ISO codes are listed in the UI)
+ (NSArray<NSString *> *)speechLanguages;          // sorted by localized name
+ (NSArray<NSString *> *)pinnedSpeechLanguages;    // shown first: uk, en, ru
+ (NSString *)nameForLanguage:(NSString *)code;    // in the UI language
/// Most likely language of `text` among the supported ones, or nil when unsure.
+ (nullable NSString *)detectLanguage:(NSString *)text;
/// The language setting: a code, or "auto".
+ (NSString *)speechLanguageSetting;
/// Language to synthesize `text` with (resolves "auto" by detection, falling back to Ukrainian).
+ (NSString *)speechLanguageForText:(NSString *)text;

// Appearance
+ (NSString *)themeSetting;                        // "system", "light", "dark"
+ (void)setThemeSetting:(NSString *)value;
+ (void)applyTheme;
+ (BOOL)isDark;
@end

NS_ASSUME_NONNULL_END
