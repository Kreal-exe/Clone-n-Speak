// deps: OVNetwork.m OVPrivacyCatalog.m OVWorker.m OVRuntime.m OVPaths.m OVModels.m OVDownloader.m OVLocale.m OVStore.m OVMemory.m
#import <Foundation/Foundation.h>
#import "OVNetwork.h"
#import "OVWorker.h"

static int gFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(void) {
    @autoreleasepool {
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        [d removeObjectForKey:@"offlineMode"];
        for (OVNetFeature f = OVNetEdgeTTS; f <= OVNetPluginNetwork; f++) [OVNetwork revokeConsentFor:f];

        // default: online, optional features need consent, model downloads are always allowed
        ASSERT(!OVNetwork.offline);
        ASSERT([OVNetwork decisionFor:OVNetEdgeTTS] == OVNetNeedsConsent);
        ASSERT([OVNetwork decisionFor:OVNetModelDownload] == OVNetAllowed);

        // consent persists and is revocable
        ASSERT(![OVNetwork hasConsentFor:OVNetYouTube]);
        __block BOOL got = NO;
        [d setBool:YES forKey:@"netConsent.youtube"];
        ASSERT([OVNetwork hasConsentFor:OVNetYouTube]);
        ASSERT([OVNetwork decisionFor:OVNetYouTube] == OVNetAllowed);
        [OVNetwork requestFeature:OVNetYouTube window:nil completion:^(BOOL ok) { got = ok; }];
        ASSERT(got);                                   // already agreed: no sheet, immediate yes
        ASSERT([OVNetwork decisionFor:OVNetBridge] == OVNetNeedsConsent);   // one consent does not cover the others

        // flipping offline: notification, blocked decisions, model downloads still allowed, consent kept
        __block int notes = 0;
        id tok = [NSNotificationCenter.defaultCenter addObserverForName:OVNetworkModeDidChangeNotification object:nil queue:nil
                                                             usingBlock:^(NSNotification *n) { notes++; }];
        [OVNetwork setOffline:YES];
        ASSERT(OVNetwork.offline && notes == 1);
        ASSERT([OVNetwork decisionFor:OVNetYouTube] == OVNetBlockedOffline);
        ASSERT([OVNetwork decisionFor:OVNetEdgeTTS] == OVNetBlockedOffline);
        ASSERT([OVNetwork decisionFor:OVNetModelDownload] == OVNetBlockedOffline);
        ASSERT([[OVNetwork blockedMessageFor:OVNetEdgeTTS] containsString:@"Settings"]);
        [OVNetwork setOffline:YES];
        ASSERT(notes == 1);                            // no change, no notification
        [OVNetwork setOffline:NO];
        ASSERT(!OVNetwork.offline && notes == 2);
        ASSERT([OVNetwork decisionFor:OVNetYouTube] == OVNetAllowed);

        [OVNetwork revokeConsentFor:OVNetYouTube];
        ASSERT([OVNetwork decisionFor:OVNetYouTube] == OVNetNeedsConsent);

        // identifiers
        ASSERT([[OVNetwork identifierFor:OVNetPluginNetwork] isEqualToString:@"plugin_network"]);
        ASSERT([[OVNetwork identifierFor:OVNetModelDownload] isEqualToString:@"model_download"]);

        // the engine is not running here: a mode flip has nothing to restart and must not crash
        ASSERT(!OVWorker.shared.running);

        [NSNotificationCenter.defaultCenter removeObserver:tok];
        [d removeObjectForKey:@"offlineMode"];
    }
    if (gFailures) { fprintf(stderr, "%d failure(s)\n", gFailures); return 1; }
    return 0;
}
