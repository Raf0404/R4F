#include "livebus.h"

#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ */
/* Parametri                                                           */
/* ------------------------------------------------------------------ */

#define LB_PHASES 256        /* fasi della tabella polifase (interpolate linearmente) */
#define LB_CUTOFF 0.455      /* taglio del filtro, frazione di fs */
#define LB_BETA 8.0          /* finestra di Kaiser */
#define LB_MAX_RETIRED 256   /* tabelle di rotte in attesa di essere liberate */
#define LB_PI_MAX 1.0e-3     /* correzione PI massima: ±1000 ppm */
#define LB_FF_MAX 2.0e-3     /* feed-forward massimo: ±2000 ppm (protezione da valori assurdi) */
#define LB_TAU 0.25          /* costante di tempo del filtro sul riempimento (s) */
#define LB_OMEGA 0.2         /* banda del loop di controllo (rad/s) */
#define LB_ZETA 0.8          /* smorzamento del loop */

/* ------------------------------------------------------------------ */
/* Utilità                                                             */
/* ------------------------------------------------------------------ */

static inline uint64_t d2u(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
static inline double u2d(uint64_t u) { double d; memcpy(&d, &u, 8); return d; }
static inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static inline double clampd(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

/* Aggiorna un picco (float >= 0 memorizzato come bit) con un CAS. */
static inline void peak_update(_Atomic uint32_t* a, float v) {
    uint32_t cur = atomic_load_explicit(a, memory_order_relaxed);
    while (u2f(cur) < v &&
           !atomic_compare_exchange_weak_explicit(a, &cur, f2u(v), memory_order_relaxed, memory_order_relaxed)) {
    }
}

/* ------------------------------------------------------------------ */
/* Tabella dei coefficienti (sinc finestrata, polifase)                */
/* ------------------------------------------------------------------ */

static float g_coef[LB_PHASES + 1][LB_TAPS];
static pthread_once_t g_coef_once = PTHREAD_ONCE_INIT;

static double bessel_i0(double x) {
    double sum = 1.0, term = 1.0, q = x * x / 4.0;
    for (int k = 1; k < 100; k++) {
        term *= q / ((double)k * (double)k);
        sum += term;
        if (term < 1e-15 * sum) break;
    }
    return sum;
}

/* Fase f in [0,1]: uscita al tempo r + (LB_TAPS/2 - 1) + f. */
static void init_coefs(void) {
    const double L = LB_TAPS / 2.0;
    const double i0b = bessel_i0(LB_BETA);
    for (int p = 0; p <= LB_PHASES; p++) {
        const double f = (double)p / LB_PHASES;
        double h[LB_TAPS], sum = 0.0;
        for (int k = 0; k < LB_TAPS; k++) {
            const double t = (double)k - (LB_TAPS / 2 - 1) - f;
            const double x = 2.0 * LB_CUTOFF * t;
            const double s = fabs(x) < 1e-12 ? 1.0 : sin(M_PI * x) / (M_PI * x);
            const double rr = t / L;
            const double w = fabs(rr) >= 1.0 ? 0.0 : bessel_i0(LB_BETA * sqrt(1.0 - rr * rr)) / i0b;
            h[k] = s * w;
            sum += h[k];
        }
        for (int k = 0; k < LB_TAPS; k++) g_coef[p][k] = (float)(h[k] / sum);
    }
}

/* ------------------------------------------------------------------ */
/* Strutture                                                           */
/* ------------------------------------------------------------------ */

typedef struct { uint32_t src, out, dst; float g0, g1; } lb_entry;

typedef struct {
    uint32_t count;
    uint32_t* active;   /* per uscita: 1 + indice massimo di canale usato */
    lb_entry e[];
} lb_table;

typedef struct lb_out {
    lb_engine* eng;
    uint32_t index, nch;

    /* ring SPSC: produttore = IOProc del bus, consumatore = IOProc dell'uscita */
    float* ring;
    uint32_t cap, mask;
    _Atomic uint64_t w, r;

    /* timestamp del produttore, letto dal consumatore con un seqlock */
    _Atomic uint64_t seq, stamp_w, stamp_t, stamp_fpt;

    /* lato produttore */
    float* scratch;
    int dropped;
    _Atomic uint32_t active;

    /* configurazione */
    double base_step, rate;
    uint32_t target;
    int use_ff;

    /* lato consumatore */
    float* acc;
    double pos, fill_avg, integ, target_cont, pi;
    int running, cont_mode;

    /* statistiche */
    _Atomic uint64_t st_fill, st_under, st_over, st_cb, st_err, st_ff, st_pi;
    _Atomic uint32_t st_peak;
    _Atomic int st_running;
} lb_out;

struct lb_engine {
    uint32_t bus_nch, nout, max_frames;
    double bus_rate, host_freq;
    lb_out* outs;

    _Atomic(lb_table*) table;
    lb_table* last_table;            /* solo thread del bus */
    _Atomic uint64_t in_cb;
    _Atomic uint64_t in_scalar;      /* double come bit */
    _Atomic uint32_t* bus_peak;

    pthread_mutex_t lock;
    lb_table* retired[LB_MAX_RETIRED];
    uint64_t retired_mark[LB_MAX_RETIRED];
    uint32_t nretired;
};

/* ------------------------------------------------------------------ */
/* Creazione / distruzione                                             */
/* ------------------------------------------------------------------ */

lb_engine* lb_engine_create(uint32_t bus_channels, double bus_rate, double host_freq,
                            uint32_t num_outputs, const uint32_t* out_channels,
                            uint32_t max_frames, uint32_t ring_frames) {
    pthread_once(&g_coef_once, init_coefs);
    if (bus_channels == 0 || bus_channels > LB_MAX_CHANNELS || max_frames == 0) return NULL;

    lb_engine* e = calloc(1, sizeof(lb_engine));
    if (!e) return NULL;
    e->bus_nch = bus_channels;
    e->nout = num_outputs;
    e->max_frames = max_frames;
    e->bus_rate = bus_rate;
    e->host_freq = host_freq;
    atomic_init(&e->table, NULL);
    atomic_init(&e->in_cb, 0);
    atomic_init(&e->in_scalar, d2u(1.0));
    pthread_mutex_init(&e->lock, NULL);

    e->bus_peak = calloc(bus_channels, sizeof(_Atomic uint32_t));
    e->outs = calloc(num_outputs ? num_outputs : 1, sizeof(lb_out));
    if (!e->bus_peak || !e->outs) { lb_engine_destroy(e); return NULL; }

    uint32_t cap = 1;
    while (cap < ring_frames || cap < 4 * max_frames) cap <<= 1;

    for (uint32_t i = 0; i < num_outputs; i++) {
        lb_out* o = &e->outs[i];
        o->eng = e;
        o->index = i;
        o->nch = out_channels[i] > LB_MAX_CHANNELS ? LB_MAX_CHANNELS : out_channels[i];
        if (o->nch == 0) o->nch = 1;
        o->cap = cap;
        o->mask = cap - 1;
        o->ring = calloc((size_t)cap * o->nch, sizeof(float));
        o->scratch = calloc((size_t)max_frames * o->nch, sizeof(float));
        o->acc = calloc(o->nch, sizeof(float));
        if (!o->ring || !o->scratch || !o->acc) { lb_engine_destroy(e); return NULL; }
        atomic_init(&o->w, 0);
        atomic_init(&o->r, 0);
        atomic_init(&o->seq, 0);
        o->base_step = 1.0;
        o->rate = bus_rate;
        o->target = 2 * max_frames;
        o->use_ff = 1;
    }
    return e;
}

void lb_engine_destroy(lb_engine* e) {
    if (!e) return;
    if (e->outs) {
        for (uint32_t i = 0; i < e->nout; i++) {
            free(e->outs[i].ring);
            free(e->outs[i].scratch);
            free(e->outs[i].acc);
        }
        free(e->outs);
    }
    for (uint32_t i = 0; i < e->nretired; i++) free(e->retired[i]);
    free(atomic_load(&e->table));
    free(e->bus_peak);
    pthread_mutex_destroy(&e->lock);
    free(e);
}

void lb_engine_config_output(lb_engine* e, uint32_t out, double base_step,
                             uint32_t target_fill, int32_t use_feedforward, double out_rate) {
    if (!e || out >= e->nout) return;
    lb_out* o = &e->outs[out];
    o->base_step = base_step > 0 ? base_step : 1.0;
    uint32_t min_target = LB_TAPS + 8;
    uint32_t max_target = o->cap / 2;
    o->target = target_fill < min_target ? min_target : (target_fill > max_target ? max_target : target_fill);
    o->use_ff = use_feedforward ? 1 : 0;
    o->rate = out_rate > 0 ? out_rate : e->bus_rate;
}

/* ------------------------------------------------------------------ */
/* Rotte (thread di controllo)                                         */
/* ------------------------------------------------------------------ */

static void collect_locked(lb_engine* e) {
    uint64_t now = atomic_load_explicit(&e->in_cb, memory_order_acquire);
    uint32_t j = 0;
    for (uint32_t i = 0; i < e->nretired; i++) {
        if (now >= e->retired_mark[i] + 2) {
            free(e->retired[i]);
        } else {
            e->retired[j] = e->retired[i];
            e->retired_mark[j] = e->retired_mark[i];
            j++;
        }
    }
    e->nretired = j;
}

int32_t lb_engine_set_routes(lb_engine* e, const lb_route* routes, uint32_t count) {
    if (!e) return -1;
    pthread_mutex_lock(&e->lock);

    lb_table* old = atomic_load_explicit(&e->table, memory_order_acquire);
    uint32_t oldn = old ? old->count : 0;
    uint32_t capn = count + oldn;
    size_t bytes = sizeof(lb_table) + sizeof(lb_entry) * capn + sizeof(uint32_t) * (e->nout ? e->nout : 1);
    lb_table* t = calloc(1, bytes);
    if (!t) { pthread_mutex_unlock(&e->lock); return -1; }
    t->active = (uint32_t*)((char*)t + sizeof(lb_table) + sizeof(lb_entry) * capn);

    uint32_t n = 0;
    for (uint32_t i = 0; i < count; i++) {
        const lb_route* r = &routes[i];
        if (r->out >= e->nout || r->src >= e->bus_nch || r->dst >= e->outs[r->out].nch) continue;
        float g0 = 0.f;
        for (uint32_t j = 0; j < oldn; j++) {
            const lb_entry* oe = &old->e[j];
            if (oe->src == r->src && oe->out == r->out && oe->dst == r->dst) { g0 = oe->g1; break; }
        }
        t->e[n++] = (lb_entry){ r->src, r->out, r->dst, g0, r->gain };
    }
    /* le rotte rimosse sfumano a zero nel primo callback */
    uint32_t nnew = n;
    for (uint32_t j = 0; j < oldn; j++) {
        const lb_entry* oe = &old->e[j];
        if (oe->g1 == 0.f) continue;
        int found = 0;
        for (uint32_t i = 0; i < nnew; i++) {
            if (t->e[i].src == oe->src && t->e[i].out == oe->out && t->e[i].dst == oe->dst) { found = 1; break; }
        }
        if (!found) t->e[n++] = (lb_entry){ oe->src, oe->out, oe->dst, oe->g1, 0.f };
    }
    t->count = n;
    for (uint32_t i = 0; i < n; i++) {
        const lb_entry* en = &t->e[i];
        if (en->g0 != 0.f || en->g1 != 0.f) {
            if (en->dst + 1 > t->active[en->out]) t->active[en->out] = en->dst + 1;
        }
    }

    atomic_store_explicit(&e->table, t, memory_order_release);

    if (old) {
        collect_locked(e);
        if (e->nretired < LB_MAX_RETIRED) {
            e->retired[e->nretired] = old;
            e->retired_mark[e->nretired] = atomic_load_explicit(&e->in_cb, memory_order_acquire);
            e->nretired++;
        }
        /* se la coda è piena la tabella resta allocata: meglio una piccola perdita che un crash */
    }
    pthread_mutex_unlock(&e->lock);
    return (int32_t)nnew;
}

void lb_engine_collect_garbage(lb_engine* e) {
    if (!e) return;
    pthread_mutex_lock(&e->lock);
    collect_locked(e);
    pthread_mutex_unlock(&e->lock);
}

/* ------------------------------------------------------------------ */
/* Statistiche                                                         */
/* ------------------------------------------------------------------ */

void lb_engine_get_output_stats(lb_engine* e, uint32_t out, lb_output_stats* st) {
    if (!e || !st || out >= e->nout) return;
    lb_out* o = &e->outs[out];
    st->fill = atomic_load_explicit(&o->st_fill, memory_order_relaxed);
    st->error = u2d(atomic_load_explicit(&o->st_err, memory_order_relaxed));
    st->ppm_ff = u2d(atomic_load_explicit(&o->st_ff, memory_order_relaxed));
    st->ppm_pi = u2d(atomic_load_explicit(&o->st_pi, memory_order_relaxed));
    st->underruns = atomic_load_explicit(&o->st_under, memory_order_relaxed);
    st->overruns = atomic_load_explicit(&o->st_over, memory_order_relaxed);
    st->callbacks = atomic_load_explicit(&o->st_cb, memory_order_relaxed);
    st->peak = u2f(atomic_exchange_explicit(&o->st_peak, 0, memory_order_relaxed));
    st->running = atomic_load_explicit(&o->st_running, memory_order_relaxed);
    st->active_channels = atomic_load_explicit(&o->active, memory_order_relaxed);
}

void lb_engine_get_bus_peaks(lb_engine* e, float* peaks, uint32_t n) {
    if (!e || !peaks) return;
    for (uint32_t i = 0; i < n; i++) {
        peaks[i] = i < e->bus_nch ? u2f(atomic_exchange_explicit(&e->bus_peak[i], 0, memory_order_relaxed)) : 0.f;
    }
}

uint64_t lb_engine_input_callbacks(lb_engine* e) {
    return e ? atomic_load_explicit(&e->in_cb, memory_order_relaxed) : 0;
}

/* ------------------------------------------------------------------ */
/* Produttore (IOProc del bus)                                         */
/* ------------------------------------------------------------------ */

static void ring_push(lb_out* o, uint32_t n) {
    uint64_t w = atomic_load_explicit(&o->w, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&o->r, memory_order_acquire);
    if ((uint64_t)o->cap - (w - r) < n) {
        /* uscita ferma o in ritardo: scartiamo il blocco */
        atomic_fetch_add_explicit(&o->st_over, 1, memory_order_relaxed);
        o->dropped = 1;
        return;
    }
    const uint32_t nch = o->nch;
    uint32_t start = (uint32_t)(w & o->mask);
    uint32_t first = o->cap - start;
    if (first > n) first = n;
    memcpy(o->ring + (size_t)start * nch, o->scratch, (size_t)first * nch * sizeof(float));
    if (n > first) memcpy(o->ring, o->scratch + (size_t)first * nch, (size_t)(n - first) * nch * sizeof(float));
    atomic_store_explicit(&o->w, w + n, memory_order_release);
}

static void stamp(lb_out* o, uint64_t w_before, double t, double fpt) {
    uint64_t s = atomic_load_explicit(&o->seq, memory_order_relaxed);
    atomic_store_explicit(&o->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&o->stamp_w, w_before, memory_order_relaxed);
    atomic_store_explicit(&o->stamp_t, d2u(t), memory_order_relaxed);
    atomic_store_explicit(&o->stamp_fpt, d2u(fpt), memory_order_relaxed);
    atomic_store_explicit(&o->seq, s + 2, memory_order_release);
}

void lb_engine_process_input(lb_engine* e, const lb_in_chan* ch, uint32_t nch,
                             uint32_t frames, double scalar, double host_time) {
    if (!e || frames == 0) return;
    const int scalar_ok = scalar > 0.5 && scalar < 2.0;
    if (scalar_ok) atomic_store_explicit(&e->in_scalar, d2u(scalar), memory_order_relaxed);

    lb_table* t = atomic_load_explicit(&e->table, memory_order_acquire);
    const int ramp = (t != e->last_table);
    const uint32_t nbus = nch < e->bus_nch ? nch : e->bus_nch;

    /* picchi del bus */
    for (uint32_t c = 0; c < nbus; c++) {
        const float* p = ch[c].ptr;
        const uint32_t s = ch[c].stride;
        float m = 0.f;
        for (uint32_t f = 0; f < frames; f++) {
            float v = fabsf(p[(size_t)f * s]);
            if (v > m) m = v;
        }
        if (m > 0.f) peak_update(&e->bus_peak[c], m);
    }

    uint64_t w_before[e->nout ? e->nout : 1];
    for (uint32_t o = 0; o < e->nout; o++) {
        e->outs[o].dropped = 0;
        w_before[o] = atomic_load_explicit(&e->outs[o].w, memory_order_relaxed);
        atomic_store_explicit(&e->outs[o].active, t ? t->active[o] : 0, memory_order_relaxed);
    }

    const float inv = 1.0f / (float)frames;
    uint32_t done = 0;
    while (done < frames) {
        uint32_t n = frames - done;
        if (n > e->max_frames) n = e->max_frames;

        for (uint32_t o = 0; o < e->nout; o++) {
            memset(e->outs[o].scratch, 0, (size_t)n * e->outs[o].nch * sizeof(float));
        }
        if (t) {
            for (uint32_t i = 0; i < t->count; i++) {
                const lb_entry* en = &t->e[i];
                if (en->src >= nbus) continue;
                if (!ramp && en->g1 == 0.f) continue;
                lb_out* o = &e->outs[en->out];
                const uint32_t ss = ch[en->src].stride;
                const float* src = ch[en->src].ptr + (size_t)done * ss;
                const uint32_t ds = o->nch;
                float* dst = o->scratch + en->dst;
                if (ramp) {
                    const float g0 = en->g0, dg = en->g1 - en->g0;
                    for (uint32_t f = 0; f < n; f++) {
                        const float a = (float)(done + f + 1) * inv;
                        dst[(size_t)f * ds] += (g0 + dg * a) * src[(size_t)f * ss];
                    }
                } else {
                    const float g = en->g1;
                    for (uint32_t f = 0; f < n; f++) dst[(size_t)f * ds] += g * src[(size_t)f * ss];
                }
            }
        }
        for (uint32_t o = 0; o < e->nout; o++) ring_push(&e->outs[o], n);
        done += n;
    }

    if (host_time > 0 && e->host_freq > 0) {
        const double fpt = e->bus_rate / (e->host_freq * (scalar_ok ? scalar : 1.0));
        for (uint32_t o = 0; o < e->nout; o++) {
            if (!e->outs[o].dropped) stamp(&e->outs[o], w_before[o], host_time, fpt);
        }
    }

    e->last_table = t;
    atomic_fetch_add_explicit(&e->in_cb, 1, memory_order_release);
}

/* ------------------------------------------------------------------ */
/* Consumatore (IOProc di un'uscita)                                   */
/* ------------------------------------------------------------------ */

/* Riempimento "continuo": frame che il produttore avrebbe scritto al tempo t
 * se scrivesse campione per campione, meno quelli già letti. Elimina il dente
 * di sega dovuto ai blocchi del produttore. */
static int measure_cont(lb_out* o, double t, double rpos, double* out) {
    if (t <= 0) return 0;
    for (int tries = 0; tries < 16; tries++) {
        uint64_t s1 = atomic_load_explicit(&o->seq, memory_order_acquire);
        if (s1 & 1) continue;
        uint64_t w = atomic_load_explicit(&o->stamp_w, memory_order_relaxed);
        double T = u2d(atomic_load_explicit(&o->stamp_t, memory_order_relaxed));
        double fpt = u2d(atomic_load_explicit(&o->stamp_fpt, memory_order_relaxed));
        atomic_thread_fence(memory_order_acquire);
        uint64_t s2 = atomic_load_explicit(&o->seq, memory_order_relaxed);
        if (s1 != s2) continue;
        if (s1 == 0 || T <= 0) return 0;
        *out = (double)w + (t - T) * fpt - rpos;
        return 1;
    }
    return 0;
}

void lb_engine_process_output(lb_engine* e, uint32_t idx, const lb_out_chan* ch,
                              uint32_t nch, uint32_t frames, double scalar, double host_time) {
    if (!e || idx >= e->nout || frames == 0) return;
    lb_out* o = &e->outs[idx];
    atomic_fetch_add_explicit(&o->st_cb, 1, memory_order_relaxed);

    for (uint32_t c = 0; c < nch; c++) {
        float* p = ch[c].ptr;
        const uint32_t s = ch[c].stride;
        for (uint32_t f = 0; f < frames; f++) p[(size_t)f * s] = 0.f;
    }

    const uint64_t w = atomic_load_explicit(&o->w, memory_order_acquire);
    uint64_t r = atomic_load_explicit(&o->r, memory_order_relaxed);
    uint64_t avail = w - r;
    atomic_store_explicit(&o->st_fill, avail, memory_order_relaxed);

    double cont = 0;
    if (!o->running) {
        if (avail < o->target) return;   /* riempimento in corso: silenzio */
        if (avail > o->target) {
            r += avail - o->target;
            avail = o->target;
            atomic_store_explicit(&o->r, r, memory_order_release);
        }
        o->pos = 0;
        o->cont_mode = measure_cont(o, host_time, (double)r, &cont);
        o->target_cont = o->cont_mode ? cont : (double)avail;
        o->fill_avg = o->target_cont;
        o->running = 1;
        atomic_store_explicit(&o->st_running, 1, memory_order_relaxed);
    }

    /* controllo della deriva */
    int have;
    /* il cursore di lettura reale è r + pos (la parte frazionaria conta) */
    if (o->cont_mode) have = measure_cont(o, host_time, (double)r + o->pos, &cont);
    else { cont = (double)avail - o->pos; have = 1; }
    const double dt = (double)frames / o->rate;
    if (have) {
        double a = dt / LB_TAU;
        if (a > 1.0) a = 1.0;
        o->fill_avg += a * (cont - o->fill_avg);
        const double err = o->fill_avg - o->target_cont;
        const double kp = 2.0 * LB_ZETA * LB_OMEGA / o->rate;
        const double ki = LB_OMEGA * LB_OMEGA / o->rate;
        o->integ = clampd(o->integ + err * dt, -LB_PI_MAX / ki, LB_PI_MAX / ki);
        o->pi = clampd(kp * err + ki * o->integ, -LB_PI_MAX, LB_PI_MAX);
        atomic_store_explicit(&o->st_err, d2u(err), memory_order_relaxed);
    }
    double ff = 1.0;
    if (o->use_ff && scalar > 0.5 && scalar < 2.0) {
        const double si = u2d(atomic_load_explicit(&e->in_scalar, memory_order_relaxed));
        ff = clampd(scalar / si, 1.0 - LB_FF_MAX, 1.0 + LB_FF_MAX);
    }
    atomic_store_explicit(&o->st_ff, d2u((ff - 1.0) * 1e6), memory_order_relaxed);
    atomic_store_explicit(&o->st_pi, d2u(o->pi * 1e6), memory_order_relaxed);

    const double step = o->base_step * ff * (1.0 + o->pi);
    const double need = o->pos + (double)frames * step + LB_TAPS + 1;
    if ((double)avail < need) {
        atomic_fetch_add_explicit(&o->st_under, 1, memory_order_relaxed);
        o->running = 0;
        atomic_store_explicit(&o->st_running, 0, memory_order_relaxed);
        return;
    }

    /* ricampionamento polifase */
    uint32_t act = atomic_load_explicit(&o->active, memory_order_relaxed);
    const uint32_t nw = nch < o->nch ? nch : o->nch;
    if (act > nw) act = nw;
    const uint32_t onch = o->nch, mask = o->mask;
    const float* ring = o->ring;
    float* acc = o->acc;
    float pk = 0.f;
    double pos = o->pos;
    float c[LB_TAPS];

    for (uint32_t j = 0; j < frames; j++) {
        if (act) {
            const double fp = pos * LB_PHASES;
            int p = (int)fp;
            float fr = (float)(fp - (double)p);
            if (p >= LB_PHASES) { p = LB_PHASES - 1; fr = 1.f; }
            const float* c0 = g_coef[p];
            const float* c1 = g_coef[p + 1];
            for (int k = 0; k < LB_TAPS; k++) c[k] = c0[k] + fr * (c1[k] - c0[k]);

            memset(acc, 0, act * sizeof(float));
            for (int k = 0; k < LB_TAPS; k++) {
                const float* fr_ = ring + (size_t)((r + (uint64_t)k) & mask) * onch;
                const float ck = c[k];
                for (uint32_t q = 0; q < act; q++) acc[q] += ck * fr_[q];
            }
            for (uint32_t q = 0; q < act; q++) {
                const float v = acc[q];
                ch[q].ptr[(size_t)j * ch[q].stride] = v;
                const float av = fabsf(v);
                if (av > pk) pk = av;
            }
        }
        pos += step;
        const uint64_t adv = (uint64_t)pos;
        r += adv;
        pos -= (double)adv;
    }
    o->pos = pos;
    atomic_store_explicit(&o->r, r, memory_order_release);
    if (pk > 0.f) peak_update(&o->st_peak, pk);
}

/* ------------------------------------------------------------------ */
/* IOProc CoreAudio                                                    */
/* ------------------------------------------------------------------ */

static uint32_t map_in(const AudioBufferList* abl, lb_in_chan* ch, uint32_t* frames) {
    uint32_t n = 0;
    *frames = 0;
    if (!abl) return 0;
    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
        const AudioBuffer* ab = &abl->mBuffers[b];
        const uint32_t nc = ab->mNumberChannels;
        if (nc == 0 || ab->mData == NULL) continue;
        const uint32_t fr = ab->mDataByteSize / (uint32_t)(sizeof(float) * nc);
        if (*frames == 0 || fr < *frames) *frames = fr;
        for (uint32_t c = 0; c < nc && n < LB_MAX_CHANNELS; c++) {
            ch[n].ptr = (const float*)ab->mData + c;
            ch[n].stride = nc;
            n++;
        }
    }
    return n;
}

static uint32_t map_out(AudioBufferList* abl, lb_out_chan* ch, uint32_t* frames) {
    uint32_t n = 0;
    *frames = 0;
    if (!abl) return 0;
    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
        AudioBuffer* ab = &abl->mBuffers[b];
        const uint32_t nc = ab->mNumberChannels;
        if (nc == 0 || ab->mData == NULL) continue;
        const uint32_t fr = ab->mDataByteSize / (uint32_t)(sizeof(float) * nc);
        if (*frames == 0 || fr < *frames) *frames = fr;
        for (uint32_t c = 0; c < nc && n < LB_MAX_CHANNELS; c++) {
            ch[n].ptr = (float*)ab->mData + c;
            ch[n].stride = nc;
            n++;
        }
    }
    return n;
}

static OSStatus input_ioproc(AudioObjectID dev, const AudioTimeStamp* now, const AudioBufferList* in,
                             const AudioTimeStamp* in_time, AudioBufferList* out,
                             const AudioTimeStamp* out_time, void* client) {
    (void)dev; (void)now; (void)out; (void)out_time;
    lb_engine* e = (lb_engine*)client;
    lb_in_chan ch[LB_MAX_CHANNELS];
    uint32_t frames;
    const uint32_t n = map_in(in, ch, &frames);
    if (n == 0 || frames == 0) return noErr;
    double scalar = 0, host = 0;
    if (in_time) {
        if (in_time->mFlags & kAudioTimeStampRateScalarValid) scalar = in_time->mRateScalar;
        if (in_time->mFlags & kAudioTimeStampHostTimeValid) host = (double)in_time->mHostTime;
    }
    lb_engine_process_input(e, ch, n, frames, scalar, host);
    return noErr;
}

static OSStatus output_ioproc(AudioObjectID dev, const AudioTimeStamp* now, const AudioBufferList* in,
                              const AudioTimeStamp* in_time, AudioBufferList* out,
                              const AudioTimeStamp* out_time, void* client) {
    (void)dev; (void)in; (void)in_time;
    lb_out* o = (lb_out*)client;
    lb_out_chan ch[LB_MAX_CHANNELS];
    uint32_t frames;
    const uint32_t n = map_out(out, ch, &frames);
    if (n == 0 || frames == 0) return noErr;
    double scalar = 0, host = 0;
    if (out_time) {
        if (out_time->mFlags & kAudioTimeStampRateScalarValid) scalar = out_time->mRateScalar;
        if (out_time->mFlags & kAudioTimeStampHostTimeValid) host = (double)out_time->mHostTime;
    }
    if (host == 0 && now && (now->mFlags & kAudioTimeStampHostTimeValid)) host = (double)now->mHostTime;
    lb_engine_process_output(o->eng, o->index, ch, n, frames, scalar, host);
    return noErr;
}

OSStatus lb_create_input_proc(lb_engine* e, AudioObjectID dev, AudioDeviceIOProcID* proc_id) {
    return AudioDeviceCreateIOProcID(dev, input_ioproc, e, proc_id);
}

OSStatus lb_create_output_proc(lb_engine* e, uint32_t out, AudioObjectID dev, AudioDeviceIOProcID* proc_id) {
    if (!e || out >= e->nout) return kAudioHardwareIllegalOperationError;
    return AudioDeviceCreateIOProcID(dev, output_ioproc, &e->outs[out], proc_id);
}

/* ------------------------------------------------------------------ */
/* Tono di prova                                                       */
/* ------------------------------------------------------------------ */

struct lb_tone {
    double rate, freq, phase;
    float amp;
    uint32_t* chans;
    uint32_t nch;
    uint64_t seg, count;
    _Atomic uint32_t current;
};

lb_tone* lb_tone_create(double rate, double freq, float amp, const uint32_t* channels,
                        uint32_t nch, double cycle_seconds) {
    if (nch == 0 || rate <= 0) return NULL;
    lb_tone* t = calloc(1, sizeof(lb_tone));
    if (!t) return NULL;
    t->chans = calloc(nch, sizeof(uint32_t));
    if (!t->chans) { free(t); return NULL; }
    memcpy(t->chans, channels, nch * sizeof(uint32_t));
    t->nch = nch;
    t->rate = rate;
    t->freq = freq;
    t->amp = amp;
    t->seg = cycle_seconds > 0 ? (uint64_t)(cycle_seconds * rate) : 0;
    atomic_init(&t->current, 0);
    return t;
}

void lb_tone_destroy(lb_tone* t) {
    if (!t) return;
    free(t->chans);
    free(t);
}

uint32_t lb_tone_current(lb_tone* t) { return t ? atomic_load(&t->current) : 0; }

static OSStatus tone_ioproc(AudioObjectID dev, const AudioTimeStamp* now, const AudioBufferList* in,
                            const AudioTimeStamp* in_time, AudioBufferList* out,
                            const AudioTimeStamp* out_time, void* client) {
    (void)dev; (void)now; (void)in; (void)in_time; (void)out_time;
    lb_tone* t = (lb_tone*)client;
    lb_out_chan ch[LB_MAX_CHANNELS];
    uint32_t frames;
    const uint32_t n = map_out(out, ch, &frames);
    for (uint32_t c = 0; c < n; c++)
        for (uint32_t f = 0; f < frames; f++) ch[c].ptr[(size_t)f * ch[c].stride] = 0.f;
    const double inc = 2.0 * M_PI * t->freq / t->rate;
    const double fade = 0.005 * t->rate;
    for (uint32_t f = 0; f < frames; f++) {
        const float s = t->amp * (float)sin(t->phase);
        t->phase += inc;
        if (t->phase > 2.0 * M_PI) t->phase -= 2.0 * M_PI;
        if (t->seg) {
            const uint64_t k = t->count / t->seg, d = t->count % t->seg;
            const uint32_t idx = (uint32_t)(k % t->nch);
            double env = 1.0;
            if ((double)d < fade) env = (double)d / fade;
            else if ((double)(t->seg - d) < fade) env = (double)(t->seg - d) / fade;
            const uint32_t c = t->chans[idx];
            if (c < n) ch[c].ptr[(size_t)f * ch[c].stride] = s * (float)env;
            atomic_store_explicit(&t->current, idx, memory_order_relaxed);
        } else {
            for (uint32_t i = 0; i < t->nch; i++) {
                const uint32_t c = t->chans[i];
                if (c < n) ch[c].ptr[(size_t)f * ch[c].stride] = s;
            }
        }
        t->count++;
    }
    return noErr;
}

OSStatus lb_create_tone_proc(lb_tone* t, AudioObjectID dev, AudioDeviceIOProcID* proc_id) {
    return AudioDeviceCreateIOProcID(dev, tone_ioproc, t, proc_id);
}
