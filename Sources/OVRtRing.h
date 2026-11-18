// Foundation-only building blocks of the realtime audio path. Plain C so the audio thread never touches the
// Objective-C runtime, a lock or an allocation: everything is created up front.
//   OVRtRing        single-producer / single-consumer float ring (lock-free), silence + counter on underrun,
//                   drop-oldest trimming on overrun.
//   OVRtAssembler   producer side: samples in, whole blocks (block_frame, a multiple of 480) out, each with the host
//                   time (ns) of its LAST captured sample.
//   OVRtLatencyStats  the last 512 latency samples; p50 / p95 by nearest rank like cns_rt_proto.LatencyStats.
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#define OV_RT_RATE 48000
#define OV_RT_MAX_BLOCK 96000    // cns_rt_proto.MAX_N

/// Samples per block at 48 kHz: seconds rounded to a multiple of 480 (10 ms), at least 480, at most 96 000.
uint32_t OVRtBlockFrames(double seconds);
/// Host-time ticks (mach_absolute_time units) to nanoseconds / milliseconds. The timebase variants are for tests.
uint64_t OVRtTicksToNs(uint64_t ticks);
double OVRtTicksToMs(uint64_t ticks);
uint64_t OVRtTicksToNsWithTimebase(uint64_t ticks, uint32_t numer, uint32_t denom);
double OVRtTicksToMsWithTimebase(uint64_t ticks, uint32_t numer, uint32_t denom);
/// "Now" in the same nanoseconds.
uint64_t OVRtNowNs(void);

typedef struct OVRtRing {
    float *buf;
    uint32_t mask;                    // capacity - 1 (capacity is a power of two)
    _Atomic uint64_t wr, rd;          // total samples written / read
    _Atomic uint64_t underruns;       // starvation EVENTS: the first short read after the ring was primed (a run of short reads is one)
    _Atomic bool starved;
    _Atomic uint64_t trimmed;         // samples dropped by trimming
    _Atomic uint64_t overflows;       // samples the writer could not store
    _Atomic bool primed;              // set by the first write: before it, a short read is not an underrun
} OVRtRing;

/// Capacity is rounded up to a power of two. Free with OVRtRingFree.
OVRtRing *_Nullable OVRtRingCreate(uint32_t minCapacity);
void OVRtRingFree(OVRtRing *_Nullable r);
uint32_t OVRtRingCapacity(const OVRtRing *r);
uint32_t OVRtRingAvailable(const OVRtRing *r);
/// Producer. Stores as many samples as fit and returns that number (the rest counts as overflows).
uint32_t OVRtRingWrite(OVRtRing *r, const float *src, uint32_t n);
/// Consumer. Copies up to n samples; the rest of dst is zeroed (silence). A shortfall after the first write counts one
/// underrun. Returns the samples that came from the ring.
uint32_t OVRtRingRead(OVRtRing *r, float *dst, uint32_t n);
/// Consumer. When more than maxFill samples wait, drops the OLDEST so that `target` remain; returns the count dropped.
uint32_t OVRtRingTrim(OVRtRing *r, uint32_t maxFill, uint32_t target);
void OVRtRingReset(OVRtRing *r);    // only while no thread uses the ring

typedef struct OVRtAssembler {
    uint32_t blockFrame;
    float *acc;                       // the block being filled (producer only)
    uint32_t fill;
    uint64_t blockEndNs[256];         // host ns of the last sample of each queued block, indexed by block number
    OVRtRing *queue;                  // whole blocks
    _Atomic uint64_t blocksIn, blocksOut, dropped;
} OVRtAssembler;

/// queueBlocks = how many whole blocks the queue holds (2...128).
OVRtAssembler *_Nullable OVRtAssemblerCreate(uint32_t blockFrame, uint32_t queueBlocks);
void OVRtAssemblerFree(OVRtAssembler *_Nullable a);
/// Producer (audio thread). `firstSampleNs` is the host time of src[0]; blocks that do not fit the queue are dropped
/// (counted). Returns the number of blocks completed.
uint32_t OVRtAssemblerPush(OVRtAssembler *a, const float *src, uint32_t n, uint64_t firstSampleNs);
/// Consumer (sender thread). YES and one block in `out` (blockFrame floats) with its last-sample host time.
bool OVRtAssemblerPop(OVRtAssembler *a, float *out, uint64_t *_Nullable lastSampleNs);
uint32_t OVRtAssemblerQueued(const OVRtAssembler *a);

#define OV_RT_STATS_N 512
typedef struct OVRtLatencyStats {
    _Atomic uint32_t ms[OV_RT_STATS_N];   // float bits
    _Atomic uint64_t count;
} OVRtLatencyStats;
void OVRtLatencyStatsAdd(OVRtLatencyStats *s, float ms);    // one writer
uint64_t OVRtLatencyStatsCount(const OVRtLatencyStats *s);
/// p50 / p95 of the window (nearest rank, ceil); 0 when empty. Any thread.
void OVRtLatencyStatsPercentiles(const OVRtLatencyStats *s, double *_Nullable p50, double *_Nullable p95);
void OVRtLatencyStatsReset(OVRtLatencyStats *s);

NS_ASSUME_NONNULL_END
