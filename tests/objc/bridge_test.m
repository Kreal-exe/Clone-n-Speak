// deps: OVBridge.m OVAPI.m OVAPICore.m OVKeychain.m OVJobs.m OVJobStore.m OVStore.m OVModels.m OVRuntime.m OVExport.m OVPaths.m OVLocale.m OVPrivacyCatalog.m OVNetwork.m OVWorker.m OVDownloader.m OVMemory.m
// Bridge: tunnel address parsing, SHA-256, helper integrity (a wrong hash deletes the download), the devices file
// (hashes only), no autostart. Starting a real tunnel needs the network and is checked by hand.
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import "OVBridge.h"
#import "OVNetwork.h"

static int gFailures = 0;
#define ASSERT(cond) do { if (!(cond)) { gFailures++; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

static NSString *TempDir(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"bridge-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void TestParseTunnelURL(void) {
    // lines as cloudflared prints them
    ASSERT([OVBridgeParseTunnelURL(@"2026-11-17T16:05:11Z INF |  https://gap-pushed-ranch-jeans.trycloudflare.com                                |")
           isEqualToString:@"https://gap-pushed-ranch-jeans.trycloudflare.com"]);
    ASSERT([OVBridgeParseTunnelURL(@"https://abc-def.trycloudflare.com") isEqualToString:@"https://abc-def.trycloudflare.com"]);
    ASSERT([OVBridgeParseTunnelURL(@"INF Visit it at (it may take some time to be reachable): https://abc-def.trycloudflare.com/x")
           isEqualToString:@"https://abc-def.trycloudflare.com"]);
    ASSERT(OVBridgeParseTunnelURL(@"https://evil.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"http://abc-def.trycloudflare.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"https://trycloudflare.com.evil.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"https://abc-def.trycloudflare.com.evil.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"https://abc-def.trycloudflare.com@evil.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"https://evil.com/https://abc-def.trycloudflare.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"https://evil-trycloudflare.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"ERR Request failed error=\"Post https://api.trycloudflare.com/tunnel\"") == nil);   // the service's own address
    ASSERT(OVBridgeParseTunnelURL(@"https://ABC-DEF.trycloudflare.com") == nil);
    ASSERT(OVBridgeParseTunnelURL(@"") == nil);
}

static void TestSHA256(void) {
    NSString *d = TempDir(), *f = [d stringByAppendingPathComponent:@"abc"];
    [@"abc" writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ASSERT([OVSHA256OfFile(f) isEqualToString:@"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]);
    NSString *big = [d stringByAppendingPathComponent:@"big"];       // more than one read block
    NSMutableData *m = [NSMutableData dataWithLength:3 * 1024 * 1024 + 17];
    [m writeToFile:big atomically:YES];
    ASSERT(OVSHA256OfFile(big).length == 64);
    ASSERT([OVSHA256OfFile([d stringByAppendingPathComponent:@"missing"]) isEqualToString:@""]);
}

static void TestHashMismatchDeletesDownload(void) {
    NSString *root = TempDir();
    NSData *pinData = [NSData dataWithContentsOfFile:@"Resources/bridge-pin.json"];
    NSDictionary *pin = pinData ? [NSJSONSerialization JSONObjectWithData:pinData options:0 error:nil] : nil;
    ASSERT(pin != nil);
    OVBridge *b = [OVBridge bridgeWithRoot:root pin:pin];
    ASSERT(!b.helperInstalled);
    NSString *tgz = [root stringByAppendingPathComponent:@"cloudflared-download.tgz"];
    NSString *part = [tgz stringByAppendingString:@".part"];
    [@"not the real archive" writeToFile:tgz atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"half" writeToFile:part atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *err = nil;
    ASSERT(![b installArchiveAtPath:tgz error:&err]);
    ASSERT([err isEqualToString:@"Bridge helper integrity verification failed"]);
    ASSERT(![NSFileManager.defaultManager fileExistsAtPath:tgz]);
    ASSERT(![NSFileManager.defaultManager fileExistsAtPath:part]);
    ASSERT(!b.helperInstalled);
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) ASSERT(![n hasPrefix:@"cloudflared-2"]);

    // a file in place that is not the pinned binary does not count as installed (and is never run)
    NSString *fake = [root stringByAppendingPathComponent:[@"cloudflared-" stringByAppendingString:pin[@"version"]]];
    [@"#!/bin/sh\necho hi\n" writeToFile:fake atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(fake.fileSystemRepresentation, 0755);
    ASSERT(!b.helperInstalled);
}

/// Runs the install with tar / codesign replaced: `listing` is what tar -t says, `content` what tar -x unpacks,
/// `verify` the exit status of codesign --verify, `team` the TeamIdentifier it prints.
static BOOL FakeInstall(NSString *listing, NSString *content, int verify, NSString *team, NSString **errOut, OVBridge **bridgeOut, NSString **rootOut) {
    NSString *root = TempDir();
    NSString *good = @"the pinned program";
    NSString *archive = [root stringByAppendingPathComponent:@"cloudflared-2026.11.1.tgz"];
    [@"archive bytes" writeToFile:archive atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSString *tmpGood = [root stringByAppendingPathComponent:@"good.bin"];
    [good writeToFile:tmpGood atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *pin = @{@"version": @"2026.11.1",
                          @"url": @"https://github.com/cloudflare/cloudflared/releases/download/2026.11.1/cloudflared-darwin-arm64.tgz",
                          @"sha256_archive": OVSHA256OfFile(archive), @"sha256_binary": OVSHA256OfFile(tmpGood), @"team_id": @"68WVV388M8"};
    [NSFileManager.defaultManager removeItemAtPath:tmpGood error:nil];
    OVBridge *b = [OVBridge bridgeWithRoot:root pin:pin];
    b.toolRunner = ^int(NSString *exe, NSArray<NSString *> *args, NSString **out, NSString **err) {
        if ([exe hasSuffix:@"tar"] && [args[0] isEqualToString:@"-tzf"]) { if (out) *out = listing; return 0; }
        if ([exe hasSuffix:@"tar"]) {
            [content writeToFile:[args[3] stringByAppendingPathComponent:@"cloudflared"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return 0;
        }
        if ([args[0] isEqualToString:@"--verify"]) return verify;
        if (err) *err = [NSString stringWithFormat:@"Identifier=cloudflared\nTeamIdentifier=%@\n", team];
        return 0;
    };
    *rootOut = root;
    *bridgeOut = b;
    NSString *err = nil;
    BOOL ok = [b installArchiveAtPath:archive error:&err];
    if (errOut) *errOut = err;
    ASSERT([NSFileManager.defaultManager fileExistsAtPath:archive] == NO);      // consumed or deleted, never left
    return ok;
}

static void TestInstallBranches(void) {
    NSString *good = @"the pinned program", *err = nil, *root = nil;
    OVBridge *b = nil;
    ASSERT(FakeInstall(@"cloudflared\n", good, 0, @"68WVV388M8", &err, &b, &root));
    ASSERT(b.helperInstalled);
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) ASSERT(![n hasPrefix:@"tmp-"]);
    ASSERT(FakeInstall(@"./cloudflared\n", good, 0, @"68WVV388M8", &err, &b, &root));
    // each failing branch: refused, the right message, nothing executable left
    struct { NSString *listing, *content; int verify; NSString *team; } bad[] = {
        {@"cloudflared\nextra\n", @"the pinned program", 0, @"68WVV388M8"},      // two entries in the archive
        {@"../cloudflared\n",     @"the pinned program", 0, @"68WVV388M8"},      // a path out of the folder
        {@"cloudflared\n",        @"another program",    0, @"68WVV388M8"},      // the binary's hash differs
        {@"cloudflared\n",        @"the pinned program", 1, @"68WVV388M8"},      // codesign --verify fails
        {@"cloudflared\n",        @"the pinned program", 0, @"AAAAAAAAAA"},      // signed by someone else
        {@"cloudflared\n",        @"the pinned program", 0, @""},                // no TeamIdentifier at all
    };
    for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
        BOOL ok = FakeInstall(bad[i].listing, bad[i].content, bad[i].verify, bad[i].team, &err, &b, &root);
        ASSERT(!ok);
        ASSERT([err isEqualToString:@"Bridge helper integrity verification failed"]);
        ASSERT(!b.helperInstalled);
        for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil]) ASSERT(![n hasPrefix:@"cloudflared-2"] && ![n hasPrefix:@"tmp-"]);
    }
}

static void TestConsentIsGrantedThroughOVNetwork(void) {
    [OVNetwork revokeConsentFor:OVNetBridge];
    ASSERT(![OVNetwork hasConsentFor:OVNetBridge]);
    [OVNetwork grantConsentFor:OVNetBridge];
    ASSERT([OVNetwork hasConsentFor:OVNetBridge] && [OVNetwork decisionFor:OVNetBridge] != OVNetNeedsConsent);
    [OVNetwork revokeConsentFor:OVNetBridge];
}

static void TestDevicesFileHoldsOnlyHashes(void) {
    NSString *root = TempDir();
    OVBridge *b = [OVBridge bridgeWithRoot:root pin:nil];
    NSString *hash = @"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    [b handleServerMessage:@{@"op": @"device_added", @"id": @"d1", @"name": @"iPhone", @"token_sha256": hash,
                             @"token": @"SECRET-TOKEN-VALUE", @"deviceToken": @"SECRET-TOKEN-VALUE"}];
    ASSERT(b.devices.count == 1);
    ASSERT([b.devices[0][@"name"] isEqualToString:@"iPhone"] && [b.devices[0][@"id"] isEqualToString:@"d1"]);
    ASSERT(b.devices[0][@"created"] != nil);
    ASSERT(b.devices[0][@"token_sha256"] == nil);                        // the page never gets the hash either
    NSString *path = [root stringByAppendingPathComponent:@"devices.json"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    ASSERT(text.length > 0);
    ASSERT([text containsString:hash]);
    ASSERT(![text containsString:@"SECRET"]);
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    ASSERT(([attrs[NSFilePosixPermissions] intValue] & 0777) == 0600);
    // a malformed hash is dropped
    [b handleServerMessage:@{@"op": @"device_added", @"id": @"d2", @"name": @"x", @"token_sha256": @"nothex"}];
    ASSERT(b.devices.count == 1);
    [b handleServerMessage:@{@"op": @"device_seen", @"id": @"d1"}];
    ASSERT(b.devices[0][@"lastSeen"] != nil);
    // a second instance reads the same file
    OVBridge *c = [OVBridge bridgeWithRoot:root pin:nil];
    ASSERT(c.devices.count == 1);
    NSArray *forServer = [c devicesForServer];
    ASSERT(forServer.count == 1 && [forServer[0][@"token_sha256"] isEqualToString:hash]);
    [c revokeDevice:@"d1"];
    ASSERT(c.devices.count == 0);
    ASSERT(![[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] containsString:hash]);
}

static void TestBridgeNeverAutostarts(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    OVBridge *b = [OVBridge bridgeWithRoot:TempDir() pin:nil];
    ASSERT(!b.running && b.tunnelURL == nil);
    for (NSString *k in d.dictionaryRepresentation.allKeys) {
        NSString *l = k.lowercaseString;
        if ([l hasPrefix:@"netconsent."]) continue;                      // the consent to the network feature is not a switch
        ASSERT(![l containsString:@"bridge"]);
    }
}

int main(void) {
    @autoreleasepool {
        TestParseTunnelURL();
        TestSHA256();
        TestHashMismatchDeletesDownload();
        TestInstallBranches();
        TestConsentIsGrantedThroughOVNetwork();
        TestDevicesFileHoldsOnlyHashes();
        TestBridgeNeverAutostarts();
    }
    if (gFailures) { fprintf(stderr, "bridge_test: %d failure(s)\n", gFailures); return 1; }
    printf("bridge_test: ok\n");
    return 0;
}
