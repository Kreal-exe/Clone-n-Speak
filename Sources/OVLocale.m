#import "OVLocale.h"
#import <NaturalLanguage/NaturalLanguage.h>

NSString *const OVAppName = @"Clone'n'Speak";
NSNotificationName const OVUILanguageDidChangeNotification = @"OVUILanguageDidChange";
NSNotificationName const OVSpeechLanguageDidChangeNotification = @"OVSpeechLanguageDidChange";

// Two-letter codes OmniVoice knows (omnivoice.utils.lang_map); the model also accepts 500+ ISO 639-3 codes.
static NSString *const kCodes =
    @"ab af am an as az ba be bg bn bo br bs ca cs cv cy da de dv el en eo es et eu fa ff fi fr fy ga gl gn gu gv ha he "
    @"hi hr ht hu hy hz ia id ig ik is it ja jv ka kj kk km kn ko ks kw ky lb lg ln lo lt lv mi mk ml mn mr ms mt my nb "
    @"ng nl nn no ny oc om os pa pl ps pt rm ro ru rw sa sc sd si sk sl sn so sq sr sv sw ta te tg th ti tk tn tr tt tw "
    @"ug uk ur uz vi wo xh yi yo zh zu";

static NSDictionary *gStrings;
static NSString *gStringsLang;

NSString *L(NSString *english) {
    NSString *lang = [OVLocale uiLanguage];
    if ([lang isEqualToString:@"en"]) return english;
    if (![gStringsLang isEqualToString:lang]) {
        NSString *path = [NSBundle.mainBundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:nil forLocalization:lang];
        gStrings = path ? [NSDictionary dictionaryWithContentsOfFile:path] : @{};
        gStringsLang = lang;
    }
    NSString *t = gStrings[english];
    return t.length ? t : english;
}

@implementation OVLocale

+ (NSString *)uiLanguageSetting {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"uiLanguage"] ?: @"system";
}

+ (void)setUILanguageSetting:(NSString *)value {
    [NSUserDefaults.standardUserDefaults setObject:value forKey:@"uiLanguage"];
    [NSNotificationCenter.defaultCenter postNotificationName:OVUILanguageDidChangeNotification object:nil];
}

+ (NSString *)uiLanguage {
    NSString *s = [self uiLanguageSetting];
    if ([s isEqualToString:@"en"] || [s isEqualToString:@"ru"]) return s;
    // Russian UI for people whose Mac is set to Russian / Ukrainian / Belarusian / Kazakh, English otherwise
    for (NSString *pref in NSLocale.preferredLanguages) {
        NSString *code = [pref componentsSeparatedByString:@"-"].firstObject;
        if ([@[@"ru", @"uk", @"be", @"kk"] containsObject:code]) return @"ru";
        if ([code isEqualToString:@"en"]) return @"en";
    }
    return @"en";
}

#pragma mark Speech languages

+ (NSArray<NSString *> *)pinnedSpeechLanguages { return @[@"uk", @"en", @"ru"]; }

+ (NSArray<NSString *> *)speechLanguages {
    NSArray *codes = [kCodes componentsSeparatedByString:@" "];
    return [codes sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[self nameForLanguage:a] localizedCaseInsensitiveCompare:[self nameForLanguage:b]];
    }];
}

+ (NSString *)nameForLanguage:(NSString *)code {
    NSLocale *ui = [NSLocale localeWithLocaleIdentifier:[self uiLanguage]];
    NSString *name = [ui localizedStringForLanguageCode:code];
    if (!name.length) return code;
    return [[name substringToIndex:1].uppercaseString stringByAppendingString:[name substringFromIndex:1]];
}

+ (NSString *)detectLanguage:(NSString *)text {
    if (text.length < 3) return nil;
    NLLanguageRecognizer *r = [NLLanguageRecognizer new];
    [r processString:text.length > 2000 ? [text substringToIndex:2000] : text];
    NSDictionary<NLLanguage, NSNumber *> *hyp = [r languageHypothesesWithMaximum:3];
    NSString *best = nil;
    double bestP = 0;
    NSSet *supported = [NSSet setWithArray:[kCodes componentsSeparatedByString:@" "]];
    for (NLLanguage lang in hyp) {
        NSString *code = [lang componentsSeparatedByString:@"-"].firstObject; // zh-Hans → zh
        if ([code isEqualToString:@"nb"] || [code isEqualToString:@"nn"]) code = @"no";
        if ([supported containsObject:code] && hyp[lang].doubleValue > bestP) { best = code; bestP = hyp[lang].doubleValue; }
    }
    return bestP >= 0.5 ? best : nil;
}

+ (NSString *)speechLanguageSetting {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"language"] ?: @"auto";
}

+ (NSString *)speechLanguageForText:(NSString *)text {
    NSString *s = [self speechLanguageSetting];
    if (s.length && ![s isEqualToString:@"auto"]) return s;
    return [self detectLanguage:text] ?: @"uk";
}

#pragma mark Theme

+ (NSString *)themeSetting { return [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"system"; }

+ (void)setThemeSetting:(NSString *)value {
    [NSUserDefaults.standardUserDefaults setObject:value forKey:@"theme"];
    [self applyTheme];
}

+ (void)applyTheme {
    NSString *t = [self themeSetting];
    NSApp.appearance = [t isEqualToString:@"light"] ? [NSAppearance appearanceNamed:NSAppearanceNameAqua] :
                       [t isEqualToString:@"dark"] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua] : nil;
}

+ (BOOL)isDark {
    NSAppearance *a = NSApp.effectiveAppearance;
    return [a bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
}
@end
