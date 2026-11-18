// deps: OVRtRing.m
// Prints "PASS <name>" or "FAIL <name>" per case; tests/test_realtime_objc.py maps each case to a Python test.
#import <Foundation/Foundation.h>
#import "OVRtRing.h"

static NSString *gCase;
static int gFailures = 0, gCaseFailures = 0;
#define ASSERT(cond, ...) do { if (!(cond)) { gCaseFailures++; fprintf(stderr, "FAIL %s:%d  %s  ", gCase.UTF8String, __LINE__, #cond); \
    fprintf(stderr, "" __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)

static void ramp(float *p, uint32_t n, float start) { for (uint32_t i = 0; i < n; i++) p[i] = start + i; }

static void testRingWrapAndBlockAssemblyExact(void) {
    // odd-sized pushes through a small ring: every block comes out exact, in order, nothing lost at the wrap
    OVRtAssembler *a = OVRtAssemblerCreate(480, 4);
    ASSERT(a != NULL);
    float in[1000], out[480];
    uint32_t total = 0, blocks = 0;
    uint64_t t0 = 1000000000ull;
    for (int round = 0; round < 40; round++) {
        uint32_t n = 100 + (round * 37) % 700;
        ramp(in, n, (float)total);
        OVRtAssemblerPush(a, in, n, t0 + (uint64_t)total * 1000000000ull / OV_RT_RATE);
        total += n;
        uint64_t last = 0;
        while (OVRtAssemblerPop(a, out, &last)) {
            for (uint32_t i = 0; i < 480; i++) ASSERT(out[i] == (float)(blocks * 480 + i), "block %u sample %u = %f", blocks, i, out[i]);
            // host time of the LAST sample of the block
            uint64_t want = t0 + (uint64_t)(blocks * 480 + 479) * 1000000000ull / OV_RT_RATE;
            ASSERT(llabs((long long)last - (long long)want) <= 1, "last %llu want %llu", last, want);
            blocks++;
        }
    }
    ASSERT(blocks == total / 480, "blocks %u of %u", blocks, total / 480);
    ASSERT(atomic_load(&a->dropped) == 0);
    // the plain ring wraps too
    OVRtRing *r = OVRtRingCreate(1024);
    float w[700], rd[700];
    uint32_t seq = 0, got = 0;
    for (int i = 0; i < 30; i++) {
        ramp(w, 700, (float)seq);
        ASSERT(OVRtRingWrite(r, w, 700) == 700);
        seq += 700;
        ASSERT(OVRtRingRead(r, rd, 700) == 700);
        for (int k = 0; k < 700; k++) ASSERT(rd[k] == (float)(got + k));
        got += 700;
    }
    ASSERT(atomic_load(&r->underruns) == 0);
    OVRtRingFree(r);
    OVRtAssemblerFree(a);
}

static void testBlockSizeRoundsTo480(void) {
    ASSERT(OVRtBlockFrames(0.15) == 7200);
    ASSERT(OVRtBlockFrames(0.10) == 4800);
    ASSERT(OVRtBlockFrames(0.03) == 1440);
    ASSERT(OVRtBlockFrames(0.25) == 12000);
    ASSERT(OVRtBlockFrames(0.0) == 480);
    ASSERT(OVRtBlockFrames(-1.0) == 480);
    ASSERT(OVRtBlockFrames(0.012) == 480);            // 576 -> 1 step
    ASSERT(OVRtBlockFrames(0.0151) == 960);           // 1.51 steps -> 2
    ASSERT(OVRtBlockFrames(9.0) == 96000);            // cap = MAX_N
    for (double s = 0.01; s < 2.2; s += 0.0137) ASSERT(OVRtBlockFrames(s) % 480 == 0, "%f", s);
}

static void testUnderrunReturnsSilenceAndCounts(void) {
    OVRtRing *r = OVRtRingCreate(4096);
    float dst[256];
    for (int i = 0; i < 256; i++) dst[i] = 9.0f;
    // before the first write there is nothing to underrun
    ASSERT(OVRtRingRead(r, dst, 256) == 0);
    ASSERT(atomic_load(&r->underruns) == 0);
    for (int i = 0; i < 256; i++) ASSERT(dst[i] == 0.0f);
    float src[100];
    ramp(src, 100, 1);
    OVRtRingWrite(r, src, 100);
    for (int i = 0; i < 256; i++) dst[i] = 9.0f;
    ASSERT(OVRtRingRead(r, dst, 256) == 100);
    ASSERT(atomic_load(&r->underruns) == 1);
    ASSERT(dst[0] == 1 && dst[99] == 100);
    for (int i = 100; i < 256; i++) ASSERT(dst[i] == 0.0f, "tail %d", i);
    // a run of short reads is ONE starvation event; it ends with a read that is fully served
    OVRtRingRead(r, dst, 256);
    OVRtRingRead(r, dst, 256);
    ASSERT(atomic_load(&r->underruns) == 1, "a run counted %llu", atomic_load(&r->underruns));
    OVRtRingWrite(r, src, 100);
    OVRtRingRead(r, dst, 64);
    ASSERT(atomic_load(&r->underruns) == 1);
    OVRtRingRead(r, dst, 256);
    ASSERT(atomic_load(&r->underruns) == 2);
    OVRtRingFree(r);
}

static void testOverrunDropsOldestToTarget(void) {
    OVRtRing *r = OVRtRingCreate(8192);
    float src[6000], dst[16];
    ramp(src, 6000, 0);
    OVRtRingWrite(r, src, 6000);
    // below the limit: nothing happens
    ASSERT(OVRtRingTrim(r, 7000, 1000) == 0);
    ASSERT(OVRtRingAvailable(r) == 6000);
    // above it: the oldest go, `target` newest stay
    ASSERT(OVRtRingTrim(r, 5000, 1000) == 5000);
    ASSERT(OVRtRingAvailable(r) == 1000);
    ASSERT(atomic_load(&r->trimmed) == 5000);
    OVRtRingRead(r, dst, 16);
    ASSERT(dst[0] == 5000.0f && dst[15] == 5015.0f, "first kept = %f", dst[0]);
    // a writer that outruns the reader is cut at capacity and counted
    OVRtRing *s = OVRtRingCreate(1024);
    uint32_t cap = OVRtRingCapacity(s);
    float big[3000];
    ramp(big, 3000, 0);
    ASSERT(OVRtRingWrite(s, big, 3000) == cap);
    ASSERT(atomic_load(&s->overflows) == 3000 - cap);
    OVRtRingFree(s);
    OVRtRingFree(r);
}

static void testLatencyStatsP50P95(void) {
    OVRtLatencyStats *s = calloc(1, sizeof(OVRtLatencyStats));
    double p50 = -1, p95 = -1;
    OVRtLatencyStatsPercentiles(s, &p50, &p95);
    ASSERT(p50 == 0 && p95 == 0);
    for (int i = 1; i <= 100; i++) OVRtLatencyStatsAdd(s, (float)i);     // 1..100 ms
    OVRtLatencyStatsPercentiles(s, &p50, &p95);
    ASSERT(p50 == 50 && p95 == 95, "%f %f", p50, p95);                   // nearest rank, as in cns_rt_proto
    ASSERT(OVRtLatencyStatsCount(s) == 100);
    OVRtLatencyStatsReset(s);
    OVRtLatencyStatsAdd(s, 240.5f);
    OVRtLatencyStatsPercentiles(s, &p50, &p95);
    ASSERT(p50 == 240.5f && p95 == 240.5f);
    // only the last window counts: 600 samples of 1 then 512 of 7 -> all 7
    OVRtLatencyStatsReset(s);
    for (int i = 0; i < 600; i++) OVRtLatencyStatsAdd(s, 1.0f);
    for (int i = 0; i < OV_RT_STATS_N; i++) OVRtLatencyStatsAdd(s, 7.0f);
    OVRtLatencyStatsPercentiles(s, &p50, &p95);
    ASSERT(p50 == 7 && p95 == 7);
    free(s);
}

static void testHostTimeToMs(void) {
    // Intel-style 1:1 and Apple-silicon 125:3 timebases
    ASSERT(OVRtTicksToNsWithTimebase(1000000, 1, 1) == 1000000);
    ASSERT(fabs(OVRtTicksToMsWithTimebase(24000000, 125, 3) - 1000.0) < 1e-6);   // 24 MHz tick = 41.667 ns
    ASSERT(fabs(OVRtTicksToMsWithTimebase(3600, 125, 3) - 0.15) < 1e-9);
    // no overflow for a machine that has been up for months
    uint64_t ticks = 24000000ull * 3600 * 24 * 90;
    ASSERT(fabs(OVRtTicksToMsWithTimebase(ticks, 125, 3) - 90.0 * 24 * 3600 * 1000) < 1.0);
    ASSERT(OVRtTicksToNsWithTimebase(5, 1, 0) == 5);   // a zero denominator does not crash
    uint64_t a = OVRtNowNs();
    [NSThread sleepForTimeInterval:0.02];
    double dt = (double)(OVRtNowNs() - a) / 1e6;
    ASSERT(dt >= 19 && dt < 200, "slept %f ms", dt);
}

int main(void) {
    @autoreleasepool {
        struct { const char *name; void (*fn)(void); } cases[] = {
            {"testRingWrapAndBlockAssemblyExact", testRingWrapAndBlockAssemblyExact},
            {"testBlockSizeRoundsTo480", testBlockSizeRoundsTo480},
            {"testUnderrunReturnsSilenceAndCounts", testUnderrunReturnsSilenceAndCounts},
            {"testOverrunDropsOldestToTarget", testOverrunDropsOldestToTarget},
            {"testLatencyStatsP50P95", testLatencyStatsP50P95},
            {"testHostTimeToMs", testHostTimeToMs},
        };
        for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            gCase = @(cases[i].name);
            gCaseFailures = 0;
            cases[i].fn();
            printf("%s %s\n", gCaseFailures ? "FAIL" : "PASS", cases[i].name);
            if (gCaseFailures) gFailures++;
        }
    }
    return gFailures ? 1 : 0;
}
