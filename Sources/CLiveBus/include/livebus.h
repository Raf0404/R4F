#ifndef LIVEBUS_H
#define LIVEBUS_H

/*
 * LiveBus — motore real-time.
 *
 * Un dispositivo "bus" (es. BlackHole) viene letto da un IOProc di ingresso.
 * Una matrice sparsa di rotte (src bus -> uscita/canale, guadagno) mixa i canali
 * in un ring buffer SPSC per ogni dispositivo di uscita. Ogni uscita ha il suo
 * IOProc, il suo clock e un ricampionatore polifase che insegue la deriva tra i
 * clock (feed-forward dai rate scalar di CoreAudio + controllore PI sul
 * riempimento del ring, misurato con i timestamp host per non soffrire
 * dell'aliasing tra le dimensioni dei buffer).
 */

#include <stdint.h>
#include <CoreAudio/CoreAudio.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LB_TAPS 64            /* lunghezza del filtro di interpolazione */
#define LB_MAX_CHANNELS 1024  /* canali massimi per dispositivo */

typedef struct lb_engine lb_engine;
typedef struct lb_tone lb_tone;

/* Una rotta: canale del bus -> canale di un'uscita. Indici 0-based. */
typedef struct {
    uint32_t src;
    uint32_t out;
    uint32_t dst;
    float gain;   /* lineare */
} lb_route;

typedef struct {
    uint64_t fill;          /* frame nel ring all'ultimo callback */
    double error;           /* errore di riempimento filtrato (frame) */
    double ppm_ff;          /* correzione feed-forward (ppm) */
    double ppm_pi;          /* correzione del controllore PI (ppm) */
    uint64_t underruns;
    uint64_t overruns;
    uint64_t callbacks;
    float peak;             /* picco dall'ultima lettura (lineare) */
    int32_t running;        /* 0 = in riempimento, 1 = in riproduzione */
    uint32_t active_channels;
} lb_output_stats;

typedef struct { const float* ptr; uint32_t stride; } lb_in_chan;
typedef struct { float* ptr; uint32_t stride; } lb_out_chan;

/* --- controllo (thread non real-time) --- */
lb_engine* lb_engine_create(uint32_t bus_channels, double bus_rate, double host_freq,
                            uint32_t num_outputs, const uint32_t* out_channels,
                            uint32_t max_frames, uint32_t ring_frames);
void lb_engine_destroy(lb_engine* e);
void lb_engine_config_output(lb_engine* e, uint32_t out, double base_step,
                             uint32_t target_fill, int32_t use_feedforward, double out_rate);
int32_t lb_engine_set_routes(lb_engine* e, const lb_route* routes, uint32_t count);
void lb_engine_collect_garbage(lb_engine* e);
void lb_engine_get_output_stats(lb_engine* e, uint32_t out, lb_output_stats* st);
void lb_engine_get_bus_peaks(lb_engine* e, float* peaks, uint32_t n);
uint64_t lb_engine_input_callbacks(lb_engine* e);

/* --- real-time (chiamate dagli IOProc, o dalla simulazione) ---
 * host_time: tick host del primo frame (ingresso) o del primo frame riprodotto (uscita); 0 = non valido. */
void lb_engine_process_input(lb_engine* e, const lb_in_chan* chans, uint32_t nch,
                             uint32_t frames, double rate_scalar, double host_time);
void lb_engine_process_output(lb_engine* e, uint32_t out, const lb_out_chan* chans,
                              uint32_t nch, uint32_t frames, double rate_scalar, double host_time);

/* --- IOProc CoreAudio --- */
OSStatus lb_create_input_proc(lb_engine* e, AudioObjectID dev, AudioDeviceIOProcID* proc_id);
OSStatus lb_create_output_proc(lb_engine* e, uint32_t out, AudioObjectID dev, AudioDeviceIOProcID* proc_id);

/* --- tono di prova (simula Live che scrive sul bus) --- */
lb_tone* lb_tone_create(double rate, double freq, float amp, const uint32_t* channels,
                        uint32_t nch, double cycle_seconds);
void lb_tone_destroy(lb_tone* t);
uint32_t lb_tone_current(lb_tone* t);
OSStatus lb_create_tone_proc(lb_tone* t, AudioObjectID dev, AudioDeviceIOProcID* proc_id);

#ifdef __cplusplus
}
#endif

#endif
