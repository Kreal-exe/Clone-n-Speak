#import "OVNetwork.h"
#import "OVWorker.h"
#import "OVLocale.h"
#import "OVPrivacyCatalog.h"

NSNotificationName const OVNetworkModeDidChangeNotification = @"OVNetworkModeDidChange";

static NSString *const kOffline = @"offlineMode";

@implementation OVNetwork

+ (BOOL)offline { return [NSUserDefaults.standardUserDefaults boolForKey:kOffline]; }

+ (void)setOffline:(BOOL)offline {
    if (offline == self.offline) return;
    [NSUserDefaults.standardUserDefaults setBool:offline forKey:kOffline];
    [self reconcileWorker];
    [NSNotificationCenter.defaultCenter postNotificationName:OVNetworkModeDidChangeNotification object:nil];
}

/// The engine's environment (OV_OFFLINE, HF_HUB_OFFLINE) is fixed at launch. When the mode differs from the one it
/// started with, it is shut down as soon as it is idle (right now, or when the running job ends); the next request starts it afresh.
+ (void)reconcileWorker {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:OVWorkerDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) { [OVNetwork reconcileWorker]; }];
    });
    OVWorker *w = OVWorker.shared;
    if (w.running && !w.busy && w.startedOffline != self.offline) [w shutdown];
}

+ (NSString *)identifierFor:(OVNetFeature)f {
    switch (f) {
        case OVNetEdgeTTS: return @"edge_tts";
        case OVNetYouTube: return @"youtube";
        case OVNetBridge: return @"bridge";
        case OVNetModelDownload: return @"model_download";
        case OVNetPluginNetwork: return @"plugin_network";
    }
}

+ (NSString *)consentKey:(OVNetFeature)f { return [@"netConsent." stringByAppendingString:[self identifierFor:f]]; }
+ (BOOL)hasConsentFor:(OVNetFeature)f { return [NSUserDefaults.standardUserDefaults boolForKey:[self consentKey:f]]; }
+ (void)grantConsentFor:(OVNetFeature)f { [NSUserDefaults.standardUserDefaults setBool:YES forKey:[self consentKey:f]]; }
+ (void)revokeConsentFor:(OVNetFeature)f { [NSUserDefaults.standardUserDefaults removeObjectForKey:[self consentKey:f]]; }

+ (OVNetDecision)decisionFor:(OVNetFeature)f {
    if (f == OVNetModelDownload) return OVNetAllowed;
    if (self.offline) return OVNetBlockedOffline;
    return [self hasConsentFor:f] ? OVNetAllowed : OVNetNeedsConsent;
}

+ (NSString *)blockedMessageFor:(OVNetFeature)f {
    return [NSString stringWithFormat:L(@"Offline mode is on. Turn it off in Settings to use %@."), [OVPrivacyCatalog entryForFeature:[self identifierFor:f]][@"title"]];
}

+ (void)requestFeature:(OVNetFeature)f window:(NSWindow *)w completion:(void (^)(BOOL))completion {
    switch ([self decisionFor:f]) {
        case OVNetAllowed: completion(YES); return;
        case OVNetBlockedOffline: {
            NSAlert *a = [NSAlert new];
            a.messageText = L(@"Offline mode is on");
            a.informativeText = [self blockedMessageFor:f];
            [a addButtonWithTitle:L(@"Open Settings")];
            [a addButtonWithTitle:L(@"Cancel")];
            [self run:a on:w done:^(NSModalResponse r) {
                if (r == NSAlertFirstButtonReturn) {
                    [NSUserDefaults.standardUserDefaults setObject:@"general" forKey:@"settingsTab"];
                    [NSApp sendAction:NSSelectorFromString(@"showSettings:") to:nil from:nil];
                }
                completion(NO);
            }];
            return;
        }
        case OVNetNeedsConsent: {
            NSDictionary *c = [OVPrivacyCatalog entryForFeature:[self identifierFor:f]];
            NSAlert *a = [NSAlert new];
            a.messageText = [NSString stringWithFormat:L(@"Use %@?"), c[@"title"]];
            a.informativeText = [NSString stringWithFormat:L(@"This sends %@ to %@. Nothing is sent until you agree, and you can turn it off with Offline mode in Settings."),
                                 c[@"sends"], c[@"destination"]];
            [a addButtonWithTitle:L(@"Allow")];
            [a addButtonWithTitle:L(@"Not now")];
            [self run:a on:w done:^(NSModalResponse r) {
                BOOL ok = r == NSAlertFirstButtonReturn;
                if (ok) [NSUserDefaults.standardUserDefaults setBool:YES forKey:[self consentKey:f]];
                completion(ok);
            }];
            return;
        }
    }
}

+ (void)run:(NSAlert *)a on:(NSWindow *)w done:(void (^)(NSModalResponse))done {
    NSWindow *host = w ?: NSApp.keyWindow;
    if (host) [a beginSheetModalForWindow:host completionHandler:done];
    else done([a runModal]);
}

@end
