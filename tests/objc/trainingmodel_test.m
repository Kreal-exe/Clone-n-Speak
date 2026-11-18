// deps: OVTrainingModel.m OVLocale.m
#import <Foundation/Foundation.h>
#import "OVTrainingModel.h"

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL %s:%d  ", __func__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)

static NSString *Tmp(void) {
    NSString *d = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"trainmodel-%u", arc4random()]];
    [NSFileManager.defaultManager createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

static void testSlug(void) {
    BOOL ch = NO;
    CHECK([[OVTrainingModel slugForName:@"My Voice 2" changed:&ch] isEqualToString:@"My_Voice_2"] && ch, "spaces become _");
    CHECK([[OVTrainingModel slugForName:@"voice" changed:&ch] isEqualToString:@"voice"] && !ch, "plain name is unchanged");
    CHECK([[OVTrainingModel slugForName:@"  _-Голос  " changed:&ch] isEqualToString:@"Golos"], "Cyrillic, edges: %s", [OVTrainingModel slugForName:@"  _-Голос  " changed:NULL].UTF8String);
    CHECK([[OVTrainingModel slugForName:@"a/b\\c:d" changed:&ch] isEqualToString:@"abcd"], "path characters are dropped");
    CHECK([[OVTrainingModel slugForName:@"../../etc" changed:&ch] isEqualToString:@"__etc"] == NO, "no leading dots survive");
    NSString *long65 = [@"" stringByPaddingToLength:80 withString:@"a" startingAtIndex:0];
    CHECK([OVTrainingModel slugForName:long65 changed:&ch].length == 64, "64 at most");
    CHECK([OVTrainingModel slugForName:@"???" changed:&ch].length == 0, "nothing valid left");
    CHECK([OVTrainingModel isValidSlug:@"abc_1-2"] && ![OVTrainingModel isValidSlug:@"_abc"] && ![OVTrainingModel isValidSlug:@""] && ![OVTrainingModel isValidSlug:@"a b"], "validity");
}

static void testRecommendation(void) {
    CHECK([OVTrainingModel recommendedEpochsForSeconds:115] == 150, "115 s");
    CHECK([OVTrainingModel recommendedEpochsForSeconds:760] == 300, "12:40");
    CHECK([OVTrainingModel recommendedEpochsForSeconds:0] == 200, "unknown");
    CHECK([OVTrainingModel recommendedEpochsForSeconds:7200] == 400, "long");
    CHECK([[OVTrainingModel durationLabel:760] isEqualToString:@"12 min 40 s"], "label: %s", [OVTrainingModel durationLabel:760].UTF8String);
    CHECK([[OVTrainingModel durationLabel:45] isEqualToString:@"45 s"], "seconds");
    CHECK([[OVTrainingModel durationLabel:3900] isEqualToString:@"1 h 05 min"], "hours: %s", [OVTrainingModel durationLabel:3900].UTF8String);
    CHECK([[OVTrainingModel etaLabelForSeconds:30] isEqualToString:@"under a minute"], "eta short");
    CHECK([[OVTrainingModel etaLabelForSeconds:250] isEqualToString:@"about 4 min"], "eta min: %s", [OVTrainingModel etaLabelForSeconds:250].UTF8String);
}

static void testFiles(void) {
    NSString *d = Tmp();
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:[d stringByAppendingPathComponent:@"sub"] withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *n in @[@"b.wav", @"a.MP3", @"sub/c.flac", @"notes.txt", @".hidden.wav", @"d.ogg", @"e.m4a"])
        [@"x" writeToFile:[d stringByAppendingPathComponent:n] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *files = [OVTrainingModel audioFilesInFolder:[NSURL fileURLWithPath:d] limit:100];
    CHECK(files.count == 5, "five audio files, got %lu", (unsigned long)files.count);
    CHECK([OVTrainingModel audioFilesInFolder:[NSURL fileURLWithPath:d] limit:2].count == 2, "limit");
}

static void testReview(void) {
    NSDictionary *report = @{
        @"verdict": @"warn", @"total_s": @115.0, @"dataset_flags": @[@"short_dataset"], @"median_rms_db": @(-21.4),
        @"files": @[@{@"file": @"a.wav", @"flags": @[@"excessive_silence"]}, @{@"file": @"b.wav", @"flags": @[@"excessive_silence", @"level_outlier"]},
                    @{@"file": @"c.wav", @"flags": @[@"long_pause"]}, @{@"file": @"d.wav", @"flags": @[@"duplicate"]},
                    @{@"file": @"e.wav", @"flags": @[]}]};
    NSArray *issues = [OVTrainingModel issuesForReport:report];
    CHECK(issues.count == 5, "short + silence + pause + level + duplicate = 5, got %lu", (unsigned long)issues.count);
    CHECK([issues[0][@"text"] isEqualToString:@"Total 1 min 55 s — add recordings, 10+ minutes give a much better voice."], "short dataset text: %s", [issues[0][@"text"] UTF8String]);
    CHECK([issues[1][@"text"] hasPrefix:@"Mostly silence, remove them (2)"], "silence: %s", [issues[1][@"text"] UTF8String]);
    CHECK([[OVTrainingModel removableFilesInReport:report] isEqualToArray:(@[@"a.wav", @"b.wav", @"d.wav"])], "removable: %s", [[[OVTrainingModel removableFilesInReport:report] description] UTF8String]);
    CHECK([[OVTrainingModel levelSummaryForReport:report] isEqualToString:@"Levels: median -21 dB; off by 6 dB or more: 1"], "levels: %s", [OVTrainingModel levelSummaryForReport:report].UTF8String);
    CHECK([[OVTrainingModel toneForVerdict:@"poor"] isEqualToString:@"err"] && [[OVTrainingModel toneForVerdict:@"ok"] isEqualToString:@"ok"], "tone");
    NSDictionary *clean = @{@"verdict": @"ok", @"total_s": @1500.0, @"dataset_flags": @[], @"files": @[@{@"file": @"a.wav", @"flags": @[]}], @"median_rms_db": @(-20)};
    CHECK([OVTrainingModel issuesForReport:clean].count == 0, "a clean dataset has no issues");
    CHECK([[OVTrainingModel levelSummaryForReport:clean] hasSuffix:@"all files are even"], "levels even");
}

static void testLog(void) {
    NSString *real = @"realcap | epoch=1 | step=4 | time=21:52:56 | training_speed=0:00:07\n"
                     @"realcap | epoch=2 | step=8 | time=21:53:05 | training_speed=0:00:06 | lowest_value=28.185 (epoch 2 and step 5)";
    NSDictionary *p = [OVTrainingModel progressFromLog:real];
    CHECK([p[@"epoch"] integerValue] == 2 && [p[@"step"] integerValue] == 8, "epoch/step from real lines");
    CHECK([p[@"seconds_per_epoch"] doubleValue] == 6, "speed");
    CHECK([p[@"state"] isEqualToString:@"improving"], "no check yet");

    NSString *plateau = [real stringByAppendingString:@"\nOvertraining check: plateau. The best epoch so far is 2 — you can stop and use it."];
    p = [OVTrainingModel progressFromLog:plateau];
    CHECK([p[@"state"] isEqualToString:@"plateau"] && [p[@"best_epoch"] integerValue] == 2, "plateau after the epoch line");
    NSString *over = [plateau stringByAppendingString:@"\nx | epoch=3 | step=12 | time=21:53:14 | training_speed=0:00:09\nOvertraining check: overtrained. The best epoch so far is 2 — you can stop and use it."];
    p = [OVTrainingModel progressFromLog:over];
    CHECK([p[@"state"] isEqualToString:@"overtrained"] && [p[@"epoch"] integerValue] == 3, "overtrained");
    NSString *recovered = [over stringByAppendingString:@"\nx | epoch=4 | step=16 | time=21:53:20 | training_speed=0:00:06"];
    p = [OVTrainingModel progressFromLog:recovered];
    CHECK([p[@"state"] isEqualToString:@"improving"], "an epoch without a check after it is improving again");
    p = [OVTrainingModel progressFromLog:@"batch lines\nname | epoch=1 | step=3 | batch=3/14\nStarting"];
    CHECK([p[@"epoch"] integerValue] == 0, "batch lines alone are not epoch summaries");
}

// protobuf by hand
static void Varint(NSMutableData *d, uint64_t v) { do { uint8_t b = v & 0x7F; v >>= 7; if (v) b |= 0x80; [d appendBytes:&b length:1]; } while (v); }
static NSData *Scalar(NSString *tag, float v, int64_t step, BOOL withSummary) {
    NSMutableData *val = [NSMutableData data];
    Varint(val, (1 << 3) | 2); Varint(val, tag.length); [val appendData:[tag dataUsingEncoding:NSUTF8StringEncoding]];
    Varint(val, (2 << 3) | 5); [val appendBytes:&v length:4];
    NSMutableData *summary = [NSMutableData data];
    Varint(summary, (1 << 3) | 2); Varint(summary, val.length); [summary appendData:val];
    NSMutableData *ev = [NSMutableData data];
    double wall = 1.0;
    Varint(ev, (1 << 3) | 1); [ev appendBytes:&wall length:8];
    Varint(ev, (2 << 3) | 0); Varint(ev, (uint64_t)step);
    if (withSummary) { Varint(ev, (5 << 3) | 2); Varint(ev, summary.length); [ev appendData:summary]; }
    else { NSString *ver = @"brain.Event:2"; Varint(ev, (3 << 3) | 2); Varint(ev, ver.length); [ev appendData:[ver dataUsingEncoding:NSUTF8StringEncoding]]; }
    NSMutableData *rec = [NSMutableData data];
    uint64_t len = ev.length;
    uint32_t crc = 0;
    [rec appendBytes:&len length:8]; [rec appendBytes:&crc length:4]; [rec appendData:ev]; [rec appendBytes:&crc length:4];
    return rec;
}

static void testEvents(void) {
    NSString *d = Tmp();
    NSMutableData *f = [NSMutableData data];
    [f appendData:Scalar(@"", 0, 0, NO)];
    [f appendData:Scalar(@"loss/g/mel", 30.5f, 4, YES)];
    [f appendData:Scalar(@"loss/g/total", 55.0f, 4, YES)];
    [f appendData:Scalar(@"loss/g/mel", 27.25f, 8, YES)];
    NSData *half = Scalar(@"loss/g/mel", 20.f, 12, YES);
    [f appendData:[half subdataWithRange:NSMakeRange(0, half.length - 9)]];   // a record still being written
    [f writeToFile:[d stringByAppendingPathComponent:@"events.out.tfevents.1.host"] atomically:YES];
    NSMutableData *g = [NSMutableData data];
    [g appendData:Scalar(@"loss/g/mel", 25.f, 12, YES)];
    [g writeToFile:[d stringByAppendingPathComponent:@"events.out.tfevents.2.host"] atomically:YES];
    [@"junk" writeToFile:[d stringByAppendingPathComponent:@"other.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *mel = [OVTrainingModel scalarsInEventsFolder:d tag:@"loss/g/mel"];
    CHECK(mel.count == 3, "three mel points, got %lu", (unsigned long)mel.count);
    CHECK(mel.count == 3 && [mel[0][0] intValue] == 4 && fabs([mel[0][1] doubleValue] - 30.5) < 1e-6 && fabs([mel[1][1] doubleValue] - 27.25) < 1e-6 && [mel[2][0] intValue] == 12, "values and steps in order");
    CHECK([OVTrainingModel scalarsInEventsFolder:d tag:@"nope"].count == 0, "unknown tag");
    CHECK([OVTrainingModel scalarsInEventsFolder:@"/nonexistent-folder" tag:@"loss/g/mel"].count == 0, "missing folder");
    // garbage must not crash
    NSMutableData *bad = [NSMutableData data];
    for (int i = 0; i < 400; i++) { uint8_t b = (uint8_t)arc4random(); [bad appendBytes:&b length:1]; }
    NSString *d2 = Tmp();
    [bad writeToFile:[d2 stringByAppendingPathComponent:@"events.out.tfevents.9"] atomically:YES];
    (void)[OVTrainingModel scalarsInEventsFolder:d2 tag:@"x"];
}

static void testRuns(void) {
    NSString *root = Tmp();
    NSString *training = [root stringByAppendingPathComponent:@"training"], *models = [root stringByAppendingPathComponent:@"models"];
    NSFileManager *fm = NSFileManager.defaultManager;
    void (^mk)(NSString *, NSArray *) = ^(NSString *name, NSArray *files) {
        NSString *dir = [training stringByAppendingPathComponent:name];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *f in files) [[NSData dataWithBytes:"0123456789" length:10] writeToFile:[dir stringByAppendingPathComponent:f] atomically:YES];
    };
    mk(@"half", @[@"G_8.pth", @"D_8.pth", @"half_3e_12s.pth", @"half_2e_8s.pth"]);                       // interrupted at epoch 3
    mk(@"finished", @[@"G_8.pth", @"D_8.pth", @"finished_5e_20s.pth", [OVTrainingModel completeMarkerName]]);   // done, checkpoints kept
    mk(@"cleaned", @[@"cleaned_5e_20s.pth"]);                                                                // no checkpoints, has a model
    mk(@"empty", @[@"config.json"]);                                                                         // unfinished
    mk(@"bad name", @[@"x"]);
    [fm createDirectoryAtPath:[models stringByAppendingPathComponent:@"cleaned"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"x" writeToFile:[models stringByAppendingPathComponent:@"cleaned/cleaned.pth"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSArray *runs = [OVTrainingModel savedRunsInTraining:training models:models];
    NSMutableDictionary *by = [NSMutableDictionary dictionary];
    for (NSDictionary *r in runs) by[r[@"name"]] = r;
    CHECK(runs.count == 4 && !by[@"bad name"], "four valid runs, got %lu", (unsigned long)runs.count);
    CHECK([by[@"half"][@"status"] isEqualToString:@"interrupted"] && [by[@"half"][@"epochs"] intValue] == 3, "interrupted at 3");
    CHECK([by[@"finished"][@"status"] isEqualToString:@"done"], "marker means done");
    CHECK([by[@"cleaned"][@"status"] isEqualToString:@"done"] && ![by[@"cleaned"][@"has_checkpoints"] boolValue], "cleaned, model exists");
    CHECK([by[@"empty"][@"status"] isEqualToString:@"unfinished"], "unfinished");
    CHECK([by[@"half"][@"checkpoint_bytes"] unsignedLongLongValue] == 20, "checkpoint bytes");

    unsigned long long freed = [OVTrainingModel removeCheckpointsInFolder:[training stringByAppendingPathComponent:@"half"]];
    CHECK(freed == 20, "freed 20, got %llu", freed);
    CHECK(![fm fileExistsAtPath:[training stringByAppendingPathComponent:@"half/G_8.pth"]] && ![fm fileExistsAtPath:[training stringByAppendingPathComponent:@"half/D_8.pth"]], "G_ and D_ gone");
    CHECK([fm fileExistsAtPath:[training stringByAppendingPathComponent:@"half/half_3e_12s.pth"]], "weights stay");
    // a symlink named like a checkpoint is never followed
    NSString *outside = [root stringByAppendingPathComponent:@"precious.pth"];
    [@"keep" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm createSymbolicLinkAtPath:[training stringByAppendingPathComponent:@"half/G_9.pth"] withDestinationPath:outside error:nil];
    CHECK([OVTrainingModel removeCheckpointsInFolder:[training stringByAppendingPathComponent:@"half"]] == 0 && [fm fileExistsAtPath:outside], "links are left alone");
}

int main(void) {
    @autoreleasepool {
        testSlug();
        testRecommendation();
        testFiles();
        testReview();
        testLog();
        testEvents();
        testRuns();
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("trainingmodel_test: ok\n");
    return 0;
}
