#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The logic of the Training page without any views, so it can be tested: voice names, dataset files, the epoch
/// recommendation, the parser of the engine's log lines, the reader of the TensorBoard scalars, the dataset-review
/// sentences, and the list of earlier training runs.
@interface OVTrainingModel : NSObject

#pragma mark Names

/// A voice name is a folder name and an Applio argument: letters, digits, "_" and "-" only, up to 64, starting with a
/// letter or a digit. Spaces become "_", accents and Cyrillic are transliterated, anything else is dropped.
/// `changed` = the result differs from the text typed (the page shows the real name).
+ (NSString *)slugForName:(NSString *)raw changed:(BOOL *_Nullable)changed;
+ (BOOL)isValidSlug:(NSString *)slug;

#pragma mark Dataset

/// wav, mp3, m4a, flac, ogg (the page's own list; the engine reads a few more).
+ (NSArray<NSString *> *)datasetExtensions;
/// The audio files of a folder (recursive, hidden files skipped, at most `limit`), sorted by name.
+ (NSArray<NSURL *> *)audioFilesInFolder:(NSURL *)folder limit:(NSUInteger)limit;
/// Epochs to suggest for a dataset of this length (seconds): 100 under a minute, 150 under 3 minutes, 200 under 10,
/// 300 under 30, 400 above. 0 seconds = the default 200.
+ (NSInteger)recommendedEpochsForSeconds:(double)seconds;
/// "12 min 40 s", "45 s", "1 h 05 min".
+ (NSString *)durationLabel:(double)seconds;
/// "1:23" style for a file row; nil duration = "—".
+ (NSString *)clockLabel:(double)seconds;
/// Seconds left, "about 4 min", "about 1 h 10 min", "under a minute".
+ (NSString *)etaLabelForSeconds:(double)seconds;

#pragma mark Dataset review

/// The sentences for the issues of a `dataset_review` report: @[@{@"code", @"text", @"files": removable file names}].
/// Texts are localized; they name at most 3 files. `removable` codes: excessive_silence, too_short, duplicate,
/// unreadable, clipping.
+ (NSArray<NSDictionary *> *)issuesForReport:(NSDictionary *)report;
/// The names of every file the report flags with a removable code.
+ (NSArray<NSString *> *)removableFilesInReport:(NSDictionary *)report;
/// One line about the levels: "Levels: median −21 dB; 2 files are 6 dB or more off", nil when there is nothing to say.
+ (nullable NSString *)levelSummaryForReport:(NSDictionary *)report;
/// "ok" | "warn" | "err" for the report's verdict (ok | warn | poor).
+ (NSString *)toneForVerdict:(NSString *)verdict;

#pragma mark Live training

/// Reads the log of a training job: @{@"epoch": N, @"step": N, @"seconds_per_epoch": double (0 = unknown),
/// @"state": improving|plateau|overtrained, @"best_epoch": N (0 = none)}. The state comes from the engine's
/// "Overtraining check: …" lines, which it writes after every epoch while the voice is not improving: one after the
/// last epoch line means that state, none means improving.
+ (NSDictionary *)progressFromLog:(NSString *)log;

#pragma mark TensorBoard scalars

/// Values of one scalar tag (e.g. "loss/g/mel") over all event files of a folder, in file then record order, as
/// @[@[step, value]]. Reads TFRecord frames and the Event/Summary protobuf; a half-written last record, an unreadable
/// file or a missing folder give what was read up to there. Needs nothing from the engine.
+ (NSArray<NSArray<NSNumber *> *> *)scalarsInEventsFolder:(NSString *)folder tag:(NSString *)tag;

#pragma mark Earlier runs

/// Marker the page writes into a training folder when the run finished (the engine never does).
+ (NSString *)completeMarkerName;
/// Folders under `training`: @[@{@"name", @"epochs": reached, @"bytes", @"checkpoint_bytes", @"has_checkpoints",
/// @"status": interrupted|done|unfinished, @"has_model": BOOL, @"path"}], newest first. Hidden folders and anything
/// whose name is not a valid slug are skipped.
+ (NSArray<NSDictionary *> *)savedRunsInTraining:(NSString *)training models:(NSString *)models;
/// Deletes G_<n>.pth / D_<n>.pth directly inside the folder (not links). Returns the bytes freed.
+ (unsigned long long)removeCheckpointsInFolder:(NSString *)folder;
+ (unsigned long long)sizeOfFolder:(NSString *)folder;

@end

NS_ASSUME_NONNULL_END
