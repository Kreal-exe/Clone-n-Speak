#import "OVProModelsCards.h"
#import <objc/runtime.h>
#import "OVDesign.h"
#import "OVEngines.h"
#import "OVJobs.h"
#import "OVLocale.h"
#import "OVNetwork.h"
#import "OVPaths.h"
#import "OVProKit.h"
#import "OVRvcSearch.h"
#import "OVRvcStore.h"

#pragma mark - Helpers

/// Calls `done` once, on main, when the job is no longer active.
static void WatchJob(OVJob *job, void (^done)(OVJob *job)) {
    if (!job.active) { done(job); return; }
    __block id token = nil;
    token = [NSNotificationCenter.defaultCenter addObserverForName:OVJobsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                                                       usingBlock:^(NSNotification *n) {
        BOOL gone = ![OVJobs.shared.all containsObject:job];
        if ((job.active && !gone) || !token) return;
        [NSNotificationCenter.defaultCenter removeObserver:token];
        token = nil;
        done(job);
    }];
}

static void Say(NSTextField *label, NSString *text, OVRole tone) {
    label.stringValue = text;
    label.textColor = OVColor(tone);
    label.hidden = !text.length;
    if (text.length)
        NSAccessibilityPostNotificationWithUserInfo(label, NSAccessibilityAnnouncementRequestedNotification, @{NSAccessibilityAnnouncementKey: text});
}

static NSString *NameFromFile(NSString *path) {
    NSString *n = [[path.lastPathComponent stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return n.length ? n : L(@"Voice model");
}

#pragma mark - Voice models (RVC)

@interface OVRvcCardController : NSObject
@property (strong) NSView *card;
@property (strong) NSStackView *list, *results;
@property (strong) NSTextField *searchField, *linkField, *status, *searchStatus;
@property (strong) NSButton *searchButton, *linkButton;
@property BOOL engineReady, busy;
@property (copy) NSString *busyText;
@property (strong) NSMutableSet<NSString *> *settled;   // finished model jobs already seen (train and blend add models too)
@end

@implementation OVRvcCardController

- (instancetype)init {
    if ((self = [super init])) {
        _settled = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload) name:OVRvcStoreDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsChanged:) name:OVJobsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

/// A finished import, blend or training adds a model: rescan once per finished job.
- (void)jobsChanged:(NSNotification *)n {
    OVJob *j = n.object;
    if (![j isKindOfClass:OVJob.class] || j.active || [self.settled containsObject:j.identifier]) return;
    if (![@[OVProKindRvcImport, OVProKindRvcBlend, OVProKindRvcTrain] containsObject:j.kind]) return;
    [self.settled addObject:j.identifier];
    if (j.state == OVJobSucceeded) [OVRvcStore.shared rescanInBackground];
}

- (NSWindow *)window { return self.card.window; }

- (NSView *)build {
    NSTextField *consent = OVWrapLabel(L(@"Use voices only with the speaker’s consent."), 13, OVColor(OVRoleMuted));
    __weak typeof(self) w = self;
    NSView *gate = OVEngineGateCard(L(@"Voice models"), @[@"pro-env", @"applio", @"rvc-core"], ^(BOOL ready) {
        w.engineReady = ready;
    });

    self.list = OVVStack(@[], 4);
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.status.hidden = YES;

    self.searchField = OVField(L(@"Search voice models, for example “rvc”"));
    self.searchField.target = self;
    self.searchField.action = @selector(search:);
    self.searchField.accessibilityLabel = L(@"Search voice models");
    self.searchButton = OVPrimaryButton(L(@"Search"), self, @selector(search:));
    NSStackView *searchRow = OVHStack(@[self.searchField, self.searchButton], 8);
    [self.searchField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.searchStatus = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.searchStatus.hidden = YES;
    self.results = OVVStack(@[], 4);
    NSStackView *searchBody = OVVStack(@[searchRow, self.searchStatus, self.results], 8);
    OVFillWidth(@[searchRow, self.searchStatus, self.results], searchBody);

    self.linkField = OVField(L(@"https://huggingface.co/…/model.pth"));
    self.linkField.target = self;
    self.linkField.action = @selector(downloadLink:);
    self.linkField.accessibilityLabel = L(@"Link to a voice model");
    self.linkButton = OVGhostButton(L(@"Download"), nil, self, @selector(downloadLink:));
    NSStackView *linkRow = OVHStack(@[self.linkField, self.linkButton], 8);
    [self.linkField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    OVDropZone *zone = [OVDropZone zoneWithTitle:L(@"Drop a voice model here or click to choose")
                                            hint:L(@"A .pth file, its .index file, or a .zip with both")
                                           types:@[@"pth", @"index", @"zip"]
                                         onFiles:^(NSArray<NSURL *> *urls) { [w importFiles:urls]; }];

    NSView *searchBlock = OVFieldBlock(L(@"Search"), L(@"Looks on Hugging Face. Only the words you type are sent."), searchBody);
    NSView *linkBlock = OVFieldBlock(L(@"Link"), L(@"A direct https link to a .pth or .zip file. Google Drive pages aren’t supported: download the file and import it."), linkRow);
    NSView *importBlock = OVFieldBlock(L(@"Import"), nil, zone);

    NSStackView *content = OVVStack(@[consent, gate, self.list, self.status, searchBlock, linkBlock, importBlock], 14);
    OVFillWidth(@[consent, gate, self.list, self.status, searchBlock, linkBlock, importBlock], content);
    self.card = OVStepCardWithAccessory(0, @"waveform", L(@"Voice models (RVC)"), OVProBadge(), content);
    objc_setAssociatedObject(self.card, "ovRvcController", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self reload];
    return self.card;
}

#pragma mark List

static NSString *DetailText(OVRvcModel *m) {
    NSMutableArray *parts = [NSMutableArray array];
    if (m.version.length) [parts addObject:m.version];
    if (m.sampleRate) [parts addObject:[OVRvcStore kHzText:m.sampleRate]];
    [parts addObject:m.pitch ? L(@"pitch") : L(@"no pitch")];
    [parts addObject:OVFormatBytes(m.sizeBytes)];
    [parts addObject:m.hasIndex ? L(@"with index") : L(@"no index")];
    return [parts componentsJoinedByString:@" · "];
}

/// A model an active convert, blend or realtime job reads must not be renamed or moved away under it.
static BOOL ModelInUse(OVRvcModel *m) {
    for (OVJob *j in OVJobs.shared.all) {
        if (!j.active || ![@[OVProKindConvert, OVProKindRvcBlend, OVProKindRealtime] containsObject:j.kind]) continue;
        for (NSString *k in @[@"model", @"model_a", @"model_b"]) {
            NSString *v = j.request[k];
            if ([v isKindOfClass:NSString.class] && ([v isEqualToString:m.folder] || [v isEqualToString:m.identifier] || [v isEqualToString:m.pthPath])) return YES;
        }
    }
    return NO;
}

- (NSView *)rowFor:(OVRvcModel *)m {
    OVTableRowView *row = [OVTableRowView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *name = OVLabel(m.name, 14, NSFontWeightSemibold, nil);
    name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSTextField *detail = OVLabel(DetailText(m), 12, NSFontWeightRegular, OVColor(OVRoleMuted));
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSTextField *t in @[name, detail]) [t setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *text = OVVStack(@[name, detail], 2);
    text.alignment = NSLayoutAttributeLeading;
    [text setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSArray *spec in @[@[@"info.circle", L(@"Info"), @"infoModel:"], @[@"folder", L(@"Show in Finder"), @"revealModel:"],
                            @[@"pencil", L(@"Rename"), @"renameModel:"], @[@"trash", L(@"Move to Trash"), @"deleteModel:"]]) {
        NSButton *b = OVIconButton(spec[0], spec[1], self, NSSelectorFromString(spec[2]));
        b.identifier = m.identifier;
        b.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", spec[1], m.name];
        if (ModelInUse(m) && ([spec[2] isEqual:@"renameModel:"] || [spec[2] isEqual:@"deleteModel:"])) {
            b.enabled = NO;
            b.toolTip = b.accessibilityHelp = L(@"This voice is in use by a running task.");
        }
        [buttons addObject:b];
    }
    NSStackView *inner = OVHStack(@[text, OVSpacer(), OVHStack(buttons, 2)], 8);
    inner.alignment = NSLayoutAttributeCenterY;
    [row addSubview:inner];
    OVPin(inner, row, NSEdgeInsetsMake(8, 12, 8, 8));
    row.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", m.name, DetailText(m)];
    return row;
}

- (void)reload {
    for (NSView *v in self.list.arrangedSubviews.copy) [v removeFromSuperview];
    NSArray<OVRvcModel *> *models = OVRvcStore.shared.models;
    if (!models.count) {
        NSView *empty = OVEmptyState(@"waveform", L(@"No RVC models yet"),
                                     L(@"Download a voice model below or import one you already have."),
                                     @[OVGhostButton(L(@"Download"), nil, self, @selector(focusSearch:)),
                                       OVGhostButton(L(@"Import…"), nil, self, @selector(chooseFiles:))]);
        [self.list addArrangedSubview:empty];
        OVFillWidth(@[empty], self.list);
        return;
    }
    for (OVRvcModel *m in models) {
        NSView *row = [self rowFor:m];
        [self.list addArrangedSubview:row];
        OVFillWidth(@[row], self.list);
    }
}

- (OVRvcModel *)modelOf:(NSButton *)b { return [OVRvcStore.shared modelWithIdentifier:b.identifier]; }

- (void)focusSearch:(id)s { [self.window makeFirstResponder:self.searchField]; }

- (void)chooseFiles:(id)s {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = YES;
    p.message = L(@"Choose a voice model: .pth (with its .index) or .zip");
    if ([p runModal] == NSModalResponseOK) [self importFiles:p.URLs];
}

- (void)revealModel:(NSButton *)b {
    OVRvcModel *m = [self modelOf:b];
    if (m) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:m.pthPath ?: m.folder]]];
}

- (void)renameModel:(NSButton *)b {
    OVRvcModel *m = [self modelOf:b];
    if (!m || ModelInUse(m)) return;
    NSAlert *a = [NSAlert new];
    a.messageText = L(@"Rename voice model");
    a.informativeText = L(@"Only the name in the list changes; the files stay as they are.");
    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
    f.stringValue = m.name;
    f.accessibilityLabel = L(@"Name of the voice model");
    a.accessoryView = f;
    [a addButtonWithTitle:L(@"Rename")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.window.initialFirstResponder = f;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSError *err = nil;
    if (![OVRvcStore.shared renameModel:m to:f.stringValue error:&err]) [[NSAlert alertWithError:err] runModal];
}

- (void)deleteModel:(NSButton *)b {
    OVRvcModel *m = [self modelOf:b];
    if (!m || ModelInUse(m)) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Delete “%@”?"), m.name];
    a.informativeText = [NSString stringWithFormat:L(@"%@ is freed. The files are moved to the Trash; you can put them back from there."), OVFormatBytes(m.sizeBytes)];
    [a addButtonWithTitle:L(@"Move to Trash")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.buttons.firstObject.hasDestructiveAction = YES;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSError *err = nil;
    if (![OVRvcStore.shared deleteModel:m error:&err]) [[NSAlert alertWithError:err] runModal];
}

#pragma mark Info

- (void)showInfo:(OVRvcModel *)m fields:(NSDictionary *)f note:(NSString *)note {
    NSInteger sr = [f[@"sample_rate"] integerValue] ?: m.sampleRate;
    NSString *version = [f[@"version"] isKindOfClass:NSString.class] ? f[@"version"] : m.version;
    BOOL pitch = [f[@"f0"] isKindOfClass:NSNumber.class] ? [f[@"f0"] boolValue] : m.pitch;
    NSInteger epochs = [f[@"epochs"] integerValue] ?: m.epochs;
    BOOL hasIndex = [f[@"has_index"] isKindOfClass:NSNumber.class] ? [f[@"has_index"] boolValue] : m.hasIndex;
    NSString *sha = [f[@"sha256"] isKindOfClass:NSString.class] ? f[@"sha256"] : m.sha256;
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:L(@"Version: %@"), version.length ? version : L(@"unknown")]];
    [lines addObject:[NSString stringWithFormat:L(@"Sample rate: %@"), sr ? [OVRvcStore kHzText:sr] : L(@"unknown")]];
    [lines addObject:[NSString stringWithFormat:L(@"Pitch (f0): %@"), pitch ? L(@"yes") : L(@"no")]];
    if (epochs) [lines addObject:[NSString stringWithFormat:L(@"Epochs: %ld"), (long)epochs]];
    [lines addObject:[NSString stringWithFormat:L(@"Index: %@"), hasIndex ? L(@"yes") : L(@"no")]];
    [lines addObject:[NSString stringWithFormat:L(@"Size: %@"), OVFormatBytes(m.sizeBytes)]];
    if (sha.length) [lines addObject:[NSString stringWithFormat:L(@"SHA-256: %@"), [sha substringToIndex:MIN((NSUInteger)16, sha.length)]]];
    if (m.sourceURL.length) [lines addObject:[NSString stringWithFormat:L(@"Source: %@"), m.sourceURL]];
    if (note.length) [lines addObject:note];
    NSAlert *a = [NSAlert new];
    a.messageText = m.name;
    a.informativeText = [lines componentsJoinedByString:@"\n"];
    [a addButtonWithTitle:L(@"OK")];
    [a runModal];
}

- (void)infoModel:(NSButton *)b {
    OVRvcModel *m = [self modelOf:b];
    if (!m) return;
    if (!self.engineReady) {
        [self showInfo:m fields:@{} note:L(@"Install the voice engine to check the file itself.")];
        return;
    }
    Say(self.status, L(@"Checking the voice model…"), OVRoleMuted);
    __weak typeof(self) w = self;
    [OVProRun submitKind:OVProKindRvcInfo request:@{@"model": m.folder, @"_name": m.name} feature:L(@"Voice models") window:self.window
                 network:(OVNetFeature)-1 completion:^(OVJob *job, NSString *error) {
        if (!job) {
            Say(w.status, error ?: @"", OVRoleErr);
            if (error) [w showInfo:m fields:@{} note:error];
            return;
        }
        WatchJob(job, ^(OVJob *done) {
            Say(w.status, @"", OVRoleMuted);
            NSDictionary *res = done.state == OVJobSucceeded ? done.result : nil;
            NSDictionary *fields = [res[@"data"] isKindOfClass:NSDictionary.class] ? res[@"data"] : res;
            [w showInfo:m fields:fields ?: @{} note:fields ? L(@"The file was checked: it is a valid voice model.") : (done.error ?: L(@"The file couldn’t be checked."))];
            [OVJobs.shared remove:done];
        });
    }];
}

#pragma mark Search

- (void)search:(id)s {
    NSString *q = self.searchField.stringValue;
    if (![q stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) { [self focusSearch:nil]; return; }
    self.searchButton.enabled = NO;
    Say(self.searchStatus, L(@"Searching Hugging Face…"), OVRoleMuted);
    __weak typeof(self) w = self;
    [OVRvcSearch search:q completion:^(NSArray<OVRvcSearchResult *> *results, NSString *error) {
        w.searchButton.enabled = YES;
        for (NSView *v in w.results.arrangedSubviews.copy) [v removeFromSuperview];
        if (!results) { Say(w.searchStatus, error ?: @"", OVRoleErr); return; }
        Say(w.searchStatus, results.count ? [NSString stringWithFormat:L(@"Found %lu"), (unsigned long)results.count] : L(@"No voice models found. Try another word."), OVRoleMuted);
        for (OVRvcSearchResult *r in results) {
            NSView *row = [w resultRow:r];
            [w.results addArrangedSubview:row];
            OVFillWidth(@[row], w.results);
        }
    }];
}

- (NSView *)resultRow:(OVRvcSearchResult *)r {
    OVTableRowView *row = [OVTableRowView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *name = OVLabel(r.repo, 14, NSFontWeightSemibold, nil);
    name.lineBreakMode = NSLineBreakByTruncatingMiddle;
    BOOL stated = r.license.length > 0;
    NSString *lic = stated ? [NSString stringWithFormat:L(@"License: %@"), r.license] : L(@"License not stated");
    NSMutableArray *parts = [NSMutableArray arrayWithObject:lic];
    if (r.downloads) [parts addObject:[NSString stringWithFormat:@"↓ %ld", (long)r.downloads]];
    if (r.pthCount > 1) [parts addObject:[NSString stringWithFormat:L(@"%lu voice files"), (unsigned long)r.pthCount]];
    if (r.indexFile) [parts addObject:L(@"with index")];
    NSTextField *detail = OVLabel([parts componentsJoinedByString:@" · "], 12, NSFontWeightRegular, OVColor(stated ? OVRoleMuted : OVRoleWarn));
    detail.lineBreakMode = NSLineBreakByTruncatingTail;
    for (NSTextField *t in @[name, detail]) [t setContentCompressionResistancePriority:250 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *text = OVVStack(@[name, detail], 2);
    text.alignment = NSLayoutAttributeLeading;
    [text setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *dl = OVSmallPill(OVGhostButton(L(@"Download"), nil, self, @selector(downloadResult:)));
    objc_setAssociatedObject(dl, "ovResult", r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dl.accessibilityLabel = [NSString stringWithFormat:L(@"Download %@"), r.repo];
    NSStackView *inner = OVHStack(@[text, OVSpacer(), dl], 8);
    inner.alignment = NSLayoutAttributeCenterY;
    [row addSubview:inner];
    OVPin(inner, row, NSEdgeInsetsMake(8, 12, 8, 12));
    return row;
}

- (void)downloadResult:(NSButton *)b {
    OVRvcSearchResult *r = objc_getAssociatedObject(b, "ovResult");
    if (!r) return;
    NSURL *u = [OVRvcSearch downloadURLForRepo:r.repo file:r.pthFile];
    NSURL *iu = r.indexFile.length ? [OVRvcSearch downloadURLForRepo:r.repo file:r.indexFile] : nil;
    if (!u) { Say(self.status, L(@"The Hugging Face address in the settings is not https, so nothing is downloaded."), OVRoleErr); return; }
    NSString *name = r.repo.lastPathComponent.length ? r.repo.lastPathComponent : NameFromFile(r.pthFile);
    [self downloadPth:u.absoluteString index:iu.absoluteString name:name];
}

#pragma mark Link

- (void)downloadLink:(id)s {
    NSString *err = nil;
    NSString *link = [OVRvcSearch fetchLinkFromText:self.linkField.stringValue error:&err];
    if (!link) { Say(self.status, err ?: L(@"Paste a link to a voice model (.pth or .zip)."), OVRoleErr); return; }
    [self downloadPth:link index:nil name:NameFromFile([NSURL URLWithString:link].path ?: link)];
}

#pragma mark Jobs

/// Submits a pro job and calls `done` with the finished job; nil job = refused or declined (error nil = declined).
- (void)run:(NSString *)kind request:(NSDictionary *)req done:(void (^)(OVJob *job, NSString *error))done {
    [OVProRun submitKind:kind request:req feature:L(@"Voice models") window:self.window network:(OVNetFeature)-1
              completion:^(OVJob *job, NSString *error) {
        if (!job) { done(nil, error); return; }
        WatchJob(job, ^(OVJob *finished) { done(finished, nil); });
    }];
}

- (BOOL)canStart {
    if (self.busy) { Say(self.status, self.busyText ?: L(@"Wait until the current download or import ends."), OVRoleWarn); return NO; }
    if (!self.engineReady) { Say(self.status, L(@"Install the voice engine first (the card above)."), OVRoleWarn); return NO; }
    return YES;
}

- (void)finishWith:(NSString *)error name:(NSString *)name {
    self.busy = NO;
    [OVRvcStore.shared rescanInBackground];
    [NSNotificationCenter.defaultCenter postNotificationName:OVRvcModelsDidChangeNotification object:self];
    if (error.length) Say(self.status, error, OVRoleErr);
    else Say(self.status, [NSString stringWithFormat:L(@"“%@” was added to your voice models."), name], OVRoleOK);
}

/// Fetch the .pth (and the .index), then import them in a separate process that has no network.
- (void)downloadPth:(NSString *)pthURL index:(NSString *)indexURL name:(NSString *)name {
    if (![self canStart]) return;
    self.busy = YES;
    self.busyText = [NSString stringWithFormat:L(@"Downloading “%@”…"), name];
    Say(self.status, self.busyText, OVRoleMuted);
    __weak typeof(self) w = self;
    NSDictionary *base = @{@"name": name, @"_name": name, @"explicit_download": @YES};
    NSMutableDictionary *r1 = [base mutableCopy];
    r1[@"url"] = pthURL;
    [self run:OVProKindRvcFetch request:r1 done:^(OVJob *fetched, NSString *err) {
        if (!fetched || fetched.state != OVJobSucceeded) {
            if (fetched) [OVJobs.shared remove:fetched];
            [w finishWith:fetched ? (fetched.error ?: L(@"The download didn’t finish.")) : err name:name];
            if (!fetched && !err) { Say(w.status, @"", OVRoleMuted); }
            return;
        }
        NSString *file = fetched.outputs.firstObject ?: fetched.result[@"path"] ?: fetched.result[@"data"][@"path"];
        void (^importNow)(NSString *, OVJob *) = ^(NSString *indexPath, OVJob *indexJob) {
            NSMutableDictionary *req = [@{@"name": name, @"_name": name, @"source_url": pthURL} mutableCopy];
            if ([fetched.result[@"kind"] isEqual:@"zip"] || [file.pathExtension.lowercaseString isEqualToString:@"zip"]) req[@"zip"] = file;
            else req[@"pth"] = file;
            if (indexPath) req[@"index"] = indexPath;
            Say(w.status, [NSString stringWithFormat:L(@"Checking and importing “%@”…"), name], OVRoleMuted);
            [w run:OVProKindRvcImport request:req done:^(OVJob *imported, NSString *ierr) {
                [OVJobs.shared remove:fetched];
                if (indexJob) [OVJobs.shared remove:indexJob];
                [w finishWith:imported ? (imported.state == OVJobSucceeded ? nil : (imported.error ?: L(@"The import failed."))) : ierr name:name];
                if (!imported && !ierr) Say(w.status, @"", OVRoleMuted);
                if (imported) [OVJobs.shared remove:imported];
            }];
        };
        if (!indexURL.length || !file.length) { importNow(nil, nil); return; }
        NSMutableDictionary *r2 = [base mutableCopy];
        r2[@"url"] = indexURL;
        r2[@"name"] = [name stringByAppendingString:@" index"];
        // the same download the user approved with the .pth: submitted directly, no second prompt
        NSString *serr = nil;
        OVJob *idxJob = [OVJobs.shared submitKind:OVProKindRvcFetch request:r2 origin:@"app" onFinish:nil error:&serr];
        if (!idxJob) { importNow(nil, nil); return; }
        WatchJob(idxJob, ^(OVJob *idx) {
            NSString *ip = idx.state == OVJobSucceeded ? idx.outputs.firstObject : nil;
            if (!ip) [OVJobs.shared remove:idx];
            importNow(ip, ip ? idx : nil);   // a missing index is not fatal: the voice works without it
        });
    }];
}

#pragma mark Import

- (void)importFiles:(NSArray<NSURL *> *)urls {
    if (![self canStart]) return;
    NSMutableArray<NSString *> *pths = [NSMutableArray array], *indexes = [NSMutableArray array], *zips = [NSMutableArray array];
    for (NSURL *u in urls) {
        NSString *ext = u.path.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"pth"]) [pths addObject:u.path];
        else if ([ext isEqualToString:@"index"]) [indexes addObject:u.path];
        else if ([ext isEqualToString:@"zip"]) [zips addObject:u.path];
    }
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    for (NSString *z in zips) [queue addObject:@{@"zip": z, @"name": NameFromFile(z)}];
    for (NSString *p in pths) {
        NSString *stem = [p.lastPathComponent stringByDeletingPathExtension], *index = nil;
        for (NSString *i in indexes) if ([[i.lastPathComponent stringByDeletingPathExtension] isEqualToString:stem]) index = i;
        if (!index && pths.count == 1 && indexes.count == 1) index = indexes.firstObject;   // one voice, one index: they belong together
        NSMutableDictionary *item = [@{@"pth": p, @"name": NameFromFile(p)} mutableCopy];
        if (index) item[@"index"] = index;
        [queue addObject:item];
    }
    if (!queue.count) { Say(self.status, L(@"Choose a .pth file (and its .index) or a .zip."), OVRoleWarn); return; }
    self.busy = YES;
    [self importNext:queue added:0 failed:nil];
}

- (void)importNext:(NSMutableArray<NSDictionary *> *)queue added:(NSInteger)added failed:(NSString *)lastError {
    if (!queue.count) {
        self.busy = NO;
        [OVRvcStore.shared rescanInBackground];
        [NSNotificationCenter.defaultCenter postNotificationName:OVRvcModelsDidChangeNotification object:self];
        if (lastError.length) Say(self.status, lastError, OVRoleErr);
        else Say(self.status, added == 1 ? L(@"The voice model was added.") : [NSString stringWithFormat:L(@"%ld voice models were added."), (long)added], OVRoleOK);
        return;
    }
    NSDictionary *item = queue.firstObject;
    [queue removeObjectAtIndex:0];
    NSMutableDictionary *req = [item mutableCopy];
    req[@"_name"] = item[@"name"];
    self.busyText = [NSString stringWithFormat:L(@"Checking and importing “%@”…"), item[@"name"]];
    Say(self.status, self.busyText, OVRoleMuted);
    __weak typeof(self) w = self;
    [self run:OVProKindRvcImport request:req done:^(OVJob *job, NSString *err) {
        BOOL ok = job && job.state == OVJobSucceeded;
        NSString *msg = ok ? nil : (job ? (job.error ?: L(@"The import failed.")) : err);
        if (job) [OVJobs.shared remove:job];
        if (!job && !err) { w.busy = NO; Say(w.status, @"", OVRoleMuted); return; }   // declined by the user: stop the rest
        [w importNext:queue added:added + (ok ? 1 : 0) failed:msg ?: lastError];
    }];
}

@end

NSView *OVRvcModelsCard(void) {
    return [[OVRvcCardController new] build];
}

#pragma mark - Pro engines

@interface OVEnginesCardController : NSObject
@property (strong) NSView *card;
@property (strong) NSStackView *rows;
@property (strong) NSTextField *footer, *status;
@property (copy) NSString *signature;
@property (copy) NSString *ytVersion;   // read from disk on engine changes only
@property BOOL lastBusy;
@end

@implementation OVEnginesCardController

- (instancetype)init {
    if ((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(enginesChanged) name:OVEnginesDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jobsTick) name:OVJobsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (NSView *)build {
    self.rows = OVVStack(@[], 6);
    self.status = OVWrapLabel(@"", 13, OVColor(OVRoleMuted));
    self.status.hidden = YES;
    NSStackView *content = OVVStack(@[self.rows, self.status], 12);
    OVFillWidth(@[self.rows, self.status], content);
    self.card = OVStepCardWithAccessory(0, @"cpu", L(@"Pro engines"), OVProBadge(), content);
    objc_setAssociatedObject(self.card, "ovEnginesController", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.ytVersion = YtDlpVersion();
    [self reload];
    [OVEngines.shared refresh];
    return self.card;
}

static NSString *YtDlpVersion(void) {
    NSString *lib = [[OVEngines.shared.root stringByAppendingPathComponent:@"pro"] stringByAppendingPathComponent:@".venv/lib"];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *py in [fm contentsOfDirectoryAtPath:lib error:nil]) {
        NSString *site = [[lib stringByAppendingPathComponent:py] stringByAppendingPathComponent:@"site-packages"];
        for (NSString *n in [fm contentsOfDirectoryAtPath:site error:nil])
            if ([n.lowercaseString hasPrefix:@"yt_dlp-"] && [n hasSuffix:@".dist-info"])
                return [n substringWithRange:NSMakeRange(7, n.length - 7 - 10)];
    }
    return nil;
}

static NSView *StateBadge(OVEngineComponent *c) {
    switch (c.state) {
        case OVEngineReady: return OVBadge(L(@"Ready"), OVRoleOK);
        case OVEnginePartial: return OVBadge(L(@"Partial"), OVRoleWarn);
        case OVEngineBroken: return OVBadge(L(@"Broken"), OVRoleErr);
        case OVEngineInstalling: return OVBadge(L(@"Installing…"), OVRoleAccent);
        default: return OVBadge(L(@"Not installed"), OVRoleMuted);
    }
}

- (NSButton *)action:(NSString *)title sel:(SEL)sel id:(NSString *)ident primary:(BOOL)primary label:(NSString *)what {
    NSButton *b = OVSmallPill(primary ? OVPrimaryButton(title, self, sel) : OVGhostButton(title, nil, self, sel));
    b.identifier = ident;
    b.accessibilityLabel = [NSString stringWithFormat:@"%@: %@", title, what];
    return b;
}

- (NSView *)rowFor:(OVEngineComponent *)c {
    OVTableRowView *row = [OVTableRowView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *title = OVLabel(L(c.title), 14, NSFontWeightSemibold, nil);
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [title setContentCompressionResistancePriority:760 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *head = OVHStack(@[title, StateBadge(c)], 8);
    head.alignment = NSLayoutAttributeCenterY;
    NSMutableArray *parts = [NSMutableArray array];
    if (c.state == OVEngineReady) [parts addObject:[NSString stringWithFormat:L(@"%@ on disk"), OVFormatBytes((long long)c.diskBytes)]];
    else [parts addObject:[NSString stringWithFormat:L(@"%@ download"), OVFormatBytes((long long)c.downloadBytes)]];
    if (c.license.length) [parts addObject:[NSString stringWithFormat:L(@"License: %@"), L(c.license)]];
    if (c.optional) [parts addObject:L(@"optional")];
    NSTextField *detail = OVWrapLabel([parts componentsJoinedByString:@" · "], 12, OVColor(OVRoleMuted));
    NSStackView *text = OVVStack(@[head, detail], 2);
    text.alignment = NSLayoutAttributeLeading;
    OVFillWidth(@[detail], text);
    [text setHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    BOOL busy = OVEngines.shared.proJobActive;
    NSMutableArray *buttons = [NSMutableArray array];
    if (c.state == OVEngineNotInstalled) [buttons addObject:[self action:L(@"Install") sel:@selector(install:) id:c.identifier primary:YES label:L(c.title)]];
    else if (c.state == OVEnginePartial) [buttons addObject:[self action:L(@"Finish installing") sel:@selector(install:) id:c.identifier primary:YES label:L(c.title)]];
    else if (c.state == OVEngineBroken) [buttons addObject:[self action:L(@"Repair") sel:@selector(install:) id:c.identifier primary:YES label:L(c.title)]];
    if (c.state != OVEngineNotInstalled && c.state != OVEngineInstalling) {
        NSButton *rm = [self action:L(@"Remove") sel:@selector(remove:) id:c.identifier primary:NO label:L(c.title)];
        rm.enabled = !busy;
        if (busy) rm.toolTip = rm.accessibilityHelp = L(@"A pro job is running — wait for it or stop it in Jobs");
        [buttons addObject:rm];
    }
    NSStackView *inner = OVHStack(@[text, OVSpacer(), OVHStack(buttons, 6)], 10);
    inner.alignment = NSLayoutAttributeCenterY;
    [row addSubview:inner];
    OVPin(inner, row, NSEdgeInsetsMake(8, 12, 8, 12));
    return row;
}

- (NSView *)ytDlpRow {
    NSString *v = self.ytVersion;
    NSTextField *label = OVLabel(v ? [NSString stringWithFormat:L(@"yt-dlp: version %@"), v] : L(@"yt-dlp: not installed"), 13, NSFontWeightRegular, OVColor(OVRoleMuted));
    NSButton *up = [self action:L(@"Update") sel:@selector(updateYtDlp:) id:@"yt-dlp" primary:NO label:@"yt-dlp"];
    up.enabled = v != nil && !OVEngines.shared.proJobActive;
    NSStackView *row = OVHStack(@[label, OVSpacer(), up], 8);
    row.alignment = NSLayoutAttributeCenterY;
    row.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
    return row;
}

- (NSView *)layoutRow {
    BOOL split = [OVEngines.shared.layout isEqualToString:@"split"];
    NSTextField *l = OVWrapLabel(split ? L(@"Python environment layout: split (two environments, one per engine set)")
                                       : L(@"Python environment layout: shared (one environment for every pro feature)"),
                                 13, OVColor(OVRoleMuted));
    NSStackView *s = OVVStack(@[l], 0);
    s.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
    OVFillWidth(@[l], s);
    return s;
}

- (void)reload {
    OVEngines *e = OVEngines.shared;
    for (NSView *v in self.rows.arrangedSubviews.copy) [v removeFromSuperview];
    if (!e.statusLoaded || !e.components.count) {
        NSString *text = e.statusError.length && !e.refreshing ? e.statusError : L(@"Checking the engines…");
        NSTextField *l = OVWrapLabel(text, 13, OVColor(e.statusError.length && !e.refreshing ? OVRoleErr : OVRoleMuted));
        [self.rows addArrangedSubview:l];
        OVFillWidth(@[l], self.rows);
        return;
    }
    NSMutableArray *views = [NSMutableArray array];
    for (OVEngineComponent *c in e.components) [views addObject:[self rowFor:c]];
    [views addObject:[self ytDlpRow]];
    [views addObject:[self layoutRow]];
    if (e.proJobActive) {
        NSTextField *why = OVWrapLabel(L(@"Remove and Update are unavailable while a pro job runs."), 13, OVColor(OVRoleWarn));
        [views addObject:why];
    }
    for (NSView *v in views) { [self.rows addArrangedSubview:v]; OVFillWidth(@[v], self.rows); }
}

- (void)enginesChanged { self.ytVersion = YtDlpVersion(); [self reload]; }

/// Job ticks come four times a second: rebuild only when "a pro job is running" flips.
- (void)jobsTick {
    BOOL busy = OVEngines.shared.proJobActive;
    if (busy != self.lastBusy) { self.lastBusy = busy; [self reload]; }
}

- (void)say:(NSString *)text tone:(OVRole)tone { Say(self.status, text, tone); }

- (void)install:(NSButton *)b {
    NSString *err = nil;
    OVJob *job = [OVEngines.shared install:@[b.identifier] error:&err];
    if (!job) { [self say:err ?: L(@"The installation could not start.") tone:OVRoleErr]; return; }
    [self say:L(@"Installing… the progress is in Jobs.") tone:OVRoleMuted];
    [self reload];
}

- (void)updateYtDlp:(NSButton *)b {
    NSString *err = nil;
    OVJob *job = [OVEngines.shared updateYtDlp:&err];
    if (!job) { [self say:err ?: L(@"The update could not start.") tone:OVRoleErr]; return; }
    [self say:L(@"Updating yt-dlp…") tone:OVRoleMuted];
    __weak typeof(self) w = self;
    WatchJob(job, ^(OVJob *done) {
        [w say:done.state == OVJobSucceeded ? L(@"yt-dlp is up to date.") : (done.error ?: L(@"The update failed.")) tone:done.state == OVJobSucceeded ? OVRoleOK : OVRoleErr];
        [w enginesChanged];
    });
}

- (void)remove:(NSButton *)b {
    OVEngineComponent *c = [OVEngines.shared componentWithId:b.identifier];
    if (!c) return;
    if (OVEngines.shared.proJobActive) { [self say:L(@"A pro job is running — wait for it or stop it in Jobs") tone:OVRoleWarn]; return; }
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:L(@"Remove “%@”?"), L(c.title)];
    a.informativeText = [NSString stringWithFormat:L(@"Frees %@. You can install it again any time."), OVFormatBytes((long long)c.diskBytes)];
    [a addButtonWithTitle:L(@"Remove")];
    [a addButtonWithTitle:L(@"Cancel")];
    a.buttons.firstObject.hasDestructiveAction = YES;
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    __weak typeof(self) w = self;
    [OVEngines.shared uninstall:@[c.identifier] completion:^(BOOL ok, NSString *error) {
        [w say:ok ? [NSString stringWithFormat:L(@"“%@” was removed."), L(c.title)] : (error ?: L(@"It couldn’t be removed.")) tone:ok ? OVRoleOK : OVRoleErr];
        [OVEngines.shared refresh];
    }];
}

@end

NSView *OVProEnginesCard(void) {
    return [[OVEnginesCardController new] build];
}
