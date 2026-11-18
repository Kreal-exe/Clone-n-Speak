#import "OVRtRing.h"
#import <mach/mach_time.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

uint32_t OVRtBlockFrames(double seconds) {
    if (!(seconds == seconds)) seconds = 0;
    double steps = round(seconds * OV_RT_RATE / 480.0);
    if (steps > 1e6) steps = 1e6;
    long n = (long)steps * 480;
    long cap = (OV_RT_MAX_BLOCK / 480) * 480;
    if (n < 480) n = 480;
    if (n > cap) n = cap;
    return (uint32_t)n;
}

static void Timebase(uint32_t *n, uint32_t *d) {
    static mach_timebase_info_data_t tb;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&tb); });
    *n = tb.numer; *d = tb.denom ? tb.denom : 1;
}

uint64_t OVRtTicksToNsWithTimebase(uint64_t ticks, uint32_t numer, uint32_t denom) {
    if (!denom) denom = 1;
    __uint128_t v = (__uint128_t)ticks * numer / denom;
    return (uint64_t)v;
}
double OVRtTicksToMsWithTimebase(uint64_t ticks, uint32_t numer, uint32_t denom) {
    return (double)OVRtTicksToNsWithTimebase(ticks, numer, denom) / 1e6;
}
uint64_t OVRtTicksToNs(uint64_t ticks) { uint32_t n, d; Timebase(&n, &d); return OVRtTicksToNsWithTimebase(ticks, n, d); }
double OVRtTicksToMs(uint64_t ticks) { return (double)OVRtTicksToNs(ticks) / 1e6; }
uint64_t OVRtNowNs(void) { return OVRtTicksToNs(mach_absolute_time()); }

#pragma mark Ring

OVRtRing *OVRtRingCreate(uint32_t minCapacity) {
    uint32_t cap = 1024;
    while (cap < minCapacity && cap < (1u << 30)) cap <<= 1;
    OVRtRing *r = calloc(1, sizeof(OVRtRing));
    if (!r) return NULL;
    r->buf = calloc(cap, sizeof(float));
    if (!r->buf) { free(r); return NULL; }
    r->mask = cap - 1;
    return r;
}
void OVRtRingFree(OVRtRing *r) { if (!r) return; free(r->buf); free(r); }
uint32_t OVRtRingCapacity(const OVRtRing *r) { return r->mask + 1; }

uint32_t OVRtRingAvailable(const OVRtRing *r) {
    OVRtRing *m = (OVRtRing *)r;
    uint64_t w = atomic_load_explicit(&m->wr, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&m->rd, memory_order_acquire);
    return (uint32_t)(w - rd);
}

uint32_t OVRtRingWrite(OVRtRing *r, const float *src, uint32_t n) {
    uint64_t w = atomic_load_explicit(&r->wr, memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_acquire);
    uint32_t cap = r->mask + 1, space = cap - (uint32_t)(w - rd);
    uint32_t k = n < space ? n : space;
    if (k < n) atomic_fetch_add_explicit(&r->overflows, n - k, memory_order_relaxed);
    uint32_t i = (uint32_t)(w & r->mask), first = cap - i < k ? cap - i : k;
    memcpy(r->buf + i, src, first * sizeof(float));
    if (k > first) memcpy(r->buf, src + first, (k - first) * sizeof(float));
    atomic_store_explicit(&r->wr, w + k, memory_order_release);
    if (k) atomic_store_explicit(&r->primed, true, memory_order_relaxed);
    return k;
}

uint32_t OVRtRingRead(OVRtRing *r, float *dst, uint32_t n) {
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->wr, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - rd), cap = r->mask + 1;
    uint32_t k = n < avail ? n : avail;
    uint32_t i = (uint32_t)(rd & r->mask), first = cap - i < k ? cap - i : k;
    memcpy(dst, r->buf + i, first * sizeof(float));
    if (k > first) memcpy(dst + first, r->buf, (k - first) * sizeof(float));
    if (k < n) {
        memset(dst + k, 0, (n - k) * sizeof(float));
        if (atomic_load_explicit(&r->primed, memory_order_relaxed) && !atomic_exchange_explicit(&r->starved, true, memory_order_relaxed))
            atomic_fetch_add_explicit(&r->underruns, 1, memory_order_relaxed);
    } else if (n) {
        atomic_store_explicit(&r->starved, false, memory_order_relaxed);
    }
    atomic_store_explicit(&r->rd, rd + k, memory_order_release);
    return k;
}

uint32_t OVRtRingTrim(OVRtRing *r, uint32_t maxFill, uint32_t target) {
    uint64_t rd = atomic_load_explicit(&r->rd, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&r->wr, memory_order_acquire);
    uint32_t avail = (uint32_t)(w - rd);
    if (avail <= maxFill || avail <= target) return 0;
    uint32_t drop = avail - target;
    atomic_store_explicit(&r->rd, rd + drop, memory_order_release);
    atomic_fetch_add_explicit(&r->trimmed, drop, memory_order_relaxed);
    return drop;
}

void OVRtRingReset(OVRtRing *r) {
    atomic_store(&r->wr, 0); atomic_store(&r->rd, 0);
    atomic_store(&r->underruns, 0); atomic_store(&r->trimmed, 0); atomic_store(&r->overflows, 0);
    atomic_store(&r->primed, false); atomic_store(&r->starved, false);
}

#pragma mark Assembler

OVRtAssembler *OVRtAssemblerCreate(uint32_t blockFrame, uint32_t queueBlocks) {
    if (blockFrame < 1) blockFrame = 480;
    if (queueBlocks < 2) queueBlocks = 2;
    if (queueBlocks > 128) queueBlocks = 128;
    OVRtAssembler *a = calloc(1, sizeof(OVRtAssembler));
    if (!a) return NULL;
    a->blockFrame = blockFrame;
    a->acc = calloc(blockFrame, sizeof(float));
    a->queue = OVRtRingCreate(blockFrame * queueBlocks);
    if (!a->acc || !a->queue) { OVRtAssemblerFree(a); return NULL; }
    return a;
}
void OVRtAssemblerFree(OVRtAssembler *a) { if (!a) return; free(a->acc); OVRtRingFree(a->queue); free(a); }

uint32_t OVRtAssemblerPush(OVRtAssembler *a, const float *src, uint32_t n, uint64_t firstSampleNs) {
    uint32_t done = 0, used = 0;
    while (used < n) {
        uint32_t take = a->blockFrame - a->fill;
        if (take > n - used) take = n - used;
        memcpy(a->acc + a->fill, src + used, take * sizeof(float));
        a->fill += take; used += take;
        if (a->fill == a->blockFrame) {
            uint64_t lastNs = firstSampleNs + (uint64_t)(used - 1) * 1000000000ull / OV_RT_RATE;
            // whole block or nothing: the queue is a ring of samples, so check the room first
            uint32_t cap = OVRtRingCapacity(a->queue), have = OVRtRingAvailable(a->queue);
            if (cap - have >= a->blockFrame) {
                uint64_t idx = atomic_load_explicit(&a->blocksIn, memory_order_relaxed);
                a->blockEndNs[idx & 255] = lastNs;
                OVRtRingWrite(a->queue, a->acc, a->blockFrame);
                atomic_store_explicit(&a->blocksIn, idx + 1, memory_order_release);
                done++;
            } else {
                atomic_fetch_add_explicit(&a->dropped, 1, memory_order_relaxed);
            }
            a->fill = 0;
        }
    }
    return done;
}

bool OVRtAssemblerPop(OVRtAssembler *a, float *out, uint64_t *lastSampleNs) {
    uint64_t in = atomic_load_explicit(&a->blocksIn, memory_order_acquire);
    uint64_t o = atomic_load_explicit(&a->blocksOut, memory_order_relaxed);
    if (o == in) return false;
    OVRtRingRead(a->queue, out, a->blockFrame);
    if (lastSampleNs) *lastSampleNs = a->blockEndNs[o & 255];
    atomic_store_explicit(&a->blocksOut, o + 1, memory_order_release);
    return true;
}

uint32_t OVRtAssemblerQueued(const OVRtAssembler *a) {
    OVRtAssembler *m = (OVRtAssembler *)a;
    return (uint32_t)(atomic_load(&m->blocksIn) - atomic_load(&m->blocksOut));
}

#pragma mark Stats

void OVRtLatencyStatsAdd(OVRtLatencyStats *s, float ms) {
    uint64_t c = atomic_load_explicit(&s->count, memory_order_relaxed);
    uint32_t bits; memcpy(&bits, &ms, 4);
    atomic_store_explicit(&s->ms[c % OV_RT_STATS_N], bits, memory_order_relaxed);
    atomic_store_explicit(&s->count, c + 1, memory_order_release);
}
uint64_t OVRtLatencyStatsCount(const OVRtLatencyStats *s) { return atomic_load(&((OVRtLatencyStats *)s)->count); }

static int CmpF(const void *a, const void *b) { float x = *(const float *)a, y = *(const float *)b; return x < y ? -1 : x > y; }

void OVRtLatencyStatsPercentiles(const OVRtLatencyStats *s, double *p50, double *p95) {
    OVRtLatencyStats *m = (OVRtLatencyStats *)s;
    uint64_t c = atomic_load_explicit(&m->count, memory_order_acquire);
    uint32_t n = c < OV_RT_STATS_N ? (uint32_t)c : OV_RT_STATS_N;
    if (!n) { if (p50) *p50 = 0; if (p95) *p95 = 0; return; }
    float v[OV_RT_STATS_N];
    for (uint32_t i = 0; i < n; i++) { uint32_t b = atomic_load_explicit(&m->ms[i], memory_order_relaxed); memcpy(&v[i], &b, 4); }
    qsort(v, n, sizeof(float), CmpF);
    // nearest rank, ceil: k = ceil(q * n / 100), index k - 1
    uint32_t k50 = (50 * n + 99) / 100, k95 = (95 * n + 99) / 100;
    if (p50) *p50 = v[(k50 ? k50 : 1) - 1];
    if (p95) *p95 = v[(k95 ? k95 : 1) - 1];
}
void OVRtLatencyStatsReset(OVRtLatencyStats *s) {
    atomic_store(&s->count, 0);
    for (uint32_t i = 0; i < OV_RT_STATS_N; i++) atomic_store(&s->ms[i], 0);
}
