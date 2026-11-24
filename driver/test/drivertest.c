// Host di prova: carica un .driver AudioServerPlugIn nel processo (senza installarlo),
// ne legge le proprietà e verifica il loopback uscita→ingresso su tutti i canali.
//
//   drivertest <percorso.driver> <canali attesi>

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static OSStatus h_changed(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) {
    (void)h; (void)o; (void)n; (void)a; return 0;
}
static OSStatus h_copy(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef* out) {
    (void)h; (void)k; *out = NULL; return 0;
}
static int gStoredMatrix = 0;
static OSStatus h_write(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) {
    (void)h; (void)d;
    if (k && CFStringCompare(k, CFSTR("r4f matrix"), 0) == kCFCompareEqualTo) gStoredMatrix++;
    return 0;
}
static OSStatus h_delete(AudioServerPlugInHostRef h, CFStringRef k) { (void)h; (void)k; return 0; }
static OSStatus h_request(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void* i) { (void)h; (void)d; (void)a; (void)i; return 0; }

static AudioServerPlugInHostInterface gHost = { h_changed, h_copy, h_write, h_delete, h_request };
static int gFail = 0;

#define CHECK(cond, ...) do { int c_ = (cond) ? 1 : 0; printf(c_ ? "  ok    " : "  FALLITO "); printf(__VA_ARGS__); printf("\n"); if (!c_) gFail = 1; } while (0)

static OSStatus getp(AudioServerPlugInDriverRef d, AudioObjectID obj, AudioObjectPropertySelector sel,
                     AudioObjectPropertyScope sc, UInt32 size, void* out, UInt32* outSize) {
    AudioObjectPropertyAddress a = { sel, sc, kAudioObjectPropertyElementMain };
    return (*d)->GetPropertyData(d, obj, 0, &a, 0, NULL, size, outSize, out);
}

static void cfstr(CFStringRef s, char* buf, size_t n) {
    buf[0] = 0;
    if (s) { CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(s); }
}

static UInt32 streamChannels(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectPropertyScope sc, AudioObjectID* streamOut) {
    AudioObjectID streams[8]; UInt32 sz = 0;
    if (getp(d, dev, kAudioDevicePropertyStreams, sc, sizeof(streams), streams, &sz) || sz == 0) return 0;
    AudioStreamBasicDescription f; UInt32 fs = 0;
    if (getp(d, streams[0], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, sizeof(f), &f, &fs)) return 0;
    if (streamOut) *streamOut = streams[0];
    return f.mChannelsPerFrame;
}

typedef struct __attribute__((packed)) { UInt16 src; UInt16 dst; Float32 gain; } R4FRoute;

static int ioCycle(AudioServerPlugInDriverRef drv, AudioObjectID dev, AudioObjectID outS, AudioObjectID inS,
                   UInt32 frames, Float64 t, float* w, float* r) {
    AudioServerPlugInIOCycleInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.mCurrentTime.mSampleTime = t - 96;
    ci.mOutputTime.mSampleTime = t;
    ci.mInputTime.mSampleTime = t;
    OSStatus a = (*drv)->DoIOOperation(drv, dev, outS, 1, kAudioServerPlugInIOOperationWriteMix, frames, &ci, w, NULL);
    OSStatus b = (*drv)->DoIOOperation(drv, dev, inS, 1, kAudioServerPlugInIOOperationReadInput, frames, &ci, r, NULL);
    return a == 0 && b == 0;
}

static OSStatus setMatrix(AudioServerPlugInDriverRef drv, AudioObjectID dev, const R4FRoute* routes, UInt32 n) {
    CFDataRef d = CFDataCreate(NULL, (const UInt8*)routes, (CFIndex)(n * sizeof(R4FRoute)));
    AudioObjectPropertyAddress a = { 'r4fm', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFPropertyListRef p = d;
    OSStatus st = (*drv)->SetPropertyData(drv, dev, 0, &a, 0, NULL, sizeof(p), &p);
    CFRelease(d);
    return st;
}

int main(int argc, const char* argv[]) {
    if (argc < 3) { fprintf(stderr, "uso: %s <driver> <canali> [--box]\n", argv[0]); return 2; }
    const UInt32 expected = (UInt32)atoi(argv[2]);
    const int box = argc > 3 && strcmp(argv[3], "--box") == 0;

    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8*)argv[1], (CFIndex)strlen(argv[1]), true);
    CFPlugInRef plugin = CFPlugInCreate(NULL, url);
    if (!plugin) { printf("FALLITO: impossibile caricare il bundle\n"); return 1; }
    CFArrayRef facs = CFPlugInFindFactoriesForPlugInTypeInPlugIn(kAudioServerPlugInTypeUUID, plugin);
    CHECK(facs && CFArrayGetCount(facs) == 1, "factory AudioServerPlugIn registrata");
    if (!facs || CFArrayGetCount(facs) == 0) return 1;

    IUnknownVTbl** unk = (IUnknownVTbl**)CFPlugInInstanceCreate(NULL, (CFUUIDRef)CFArrayGetValueAtIndex(facs, 0), kAudioServerPlugInTypeUUID);
    AudioServerPlugInDriverRef drv = NULL;
    if (!unk || (*unk)->QueryInterface(unk, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), (LPVOID*)&drv) || !drv) {
        printf("FALLITO: interfaccia del driver non disponibile\n"); return 1;
    }
    CHECK((*drv)->Initialize(drv, &gHost) == 0, "Initialize");

    AudioObjectID devs[8]; UInt32 sz = 0;
    getp(drv, kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, sizeof(devs), devs, &sz);
    UInt32 ndev = sz / sizeof(AudioObjectID);
    CHECK(ndev >= 1, "%u dispositivi esposti", ndev);

    AudioObjectID main = 0, inS = 0, outS = 0;
    for (UInt32 i = 0; i < ndev; i++) {
        char name[256], uid[256], manu[256]; CFStringRef s = NULL; UInt32 hidden = 0, sysdef = 1;
        getp(drv, devs[i], kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, sizeof(s), &s, &sz); cfstr(s, name, sizeof name); s = NULL;
        getp(drv, devs[i], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, sizeof(s), &s, &sz); cfstr(s, uid, sizeof uid); s = NULL;
        getp(drv, devs[i], kAudioObjectPropertyManufacturer, kAudioObjectPropertyScopeGlobal, sizeof(s), &s, &sz); cfstr(s, manu, sizeof manu);
        getp(drv, devs[i], kAudioDevicePropertyIsHidden, kAudioObjectPropertyScopeGlobal, sizeof(hidden), &hidden, &sz);
        getp(drv, devs[i], kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeOutput, sizeof(sysdef), &sysdef, &sz);
        UInt32 ci = streamChannels(drv, devs[i], kAudioObjectPropertyScopeInput, NULL);
        UInt32 co = streamChannels(drv, devs[i], kAudioObjectPropertyScopeOutput, NULL);
        printf("dispositivo %u: \"%s\" uid=%s %s — in %u, out %u, nascosto %u, suoni di sistema %u\n",
               devs[i], name, uid, manu, ci, co, hidden, sysdef);
        if (!hidden) {
            main = devs[i];
            CHECK(strstr(name, "R4F") != NULL, "nome: %s", name);
            CHECK(ci == expected && co == expected, "%u canali in ingresso e in uscita (attesi %u)", ci, expected);
            CHECK(sysdef == 0, "non selezionabile per i suoni di sistema");
        }
    }
    if (!main) { printf("FALLITO: nessun dispositivo visibile\n"); return 1; }

    AudioValueRange rates[16];
    getp(drv, main, kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, sizeof(rates), rates, &sz);
    printf("frequenze:");
    for (UInt32 i = 0; i < sz / sizeof(AudioValueRange); i++) printf(" %.0f", rates[i].mMinimum);
    printf("\n");

    // Loopback: scrivo un segnale diverso su ogni canale e lo rileggo.
    streamChannels(drv, main, kAudioObjectPropertyScopeInput, &inS);
    streamChannels(drv, main, kAudioObjectPropertyScopeOutput, &outS);
    const UInt32 frames = 512, ch = expected;
    float* wbuf = calloc((size_t)frames * ch, sizeof(float));
    float* rbuf = calloc((size_t)frames * ch, sizeof(float));
    for (UInt32 f = 0; f < frames; f++)
        for (UInt32 c = 0; c < ch; c++) wbuf[f * ch + c] = (float)sin(0.01 * f * (c + 1)) * 0.5f + (float)c * 1e-4f;

    CHECK((*drv)->StartIO(drv, main, 1) == 0, "StartIO");
    AudioServerPlugInIOCycleInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.mCurrentTime.mSampleTime = 4000;
    ci.mOutputTime.mSampleTime = 4096;
    ci.mInputTime.mSampleTime = 4096;
    OSStatus ew = (*drv)->DoIOOperation(drv, main, outS, 1, kAudioServerPlugInIOOperationWriteMix, frames, &ci, wbuf, NULL);
    OSStatus er = (*drv)->DoIOOperation(drv, main, inS, 1, kAudioServerPlugInIOOperationReadInput, frames, &ci, rbuf, NULL);
    double maxd = 0; UInt32 nonzeroLast = 0;
    for (UInt32 i = 0; i < frames * ch; i++) { double d = fabs(wbuf[i] - rbuf[i]); if (d > maxd) maxd = d; }
    for (UInt32 f = 0; f < frames; f++) if (rbuf[f * ch + ch - 1] != 0.f) nonzeroLast++;
    CHECK(ew == 0 && er == 0 && maxd == 0.0, "loopback bit-exact su %u canali (diff max %g)", ch, maxd);
    CHECK(nonzeroLast > frames / 2, "l'ultimo canale (%u) porta segnale", ch);

    // Costo: scrittura + lettura di 512 frame × N canali.
    const int iters = 4000;
    uint64_t t0 = mach_absolute_time();
    for (int i = 0; i < iters; i++) {
        ci.mOutputTime.mSampleTime = ci.mInputTime.mSampleTime = 4096 + (Float64)i * frames;
        ci.mCurrentTime.mSampleTime = ci.mOutputTime.mSampleTime - 96;
        (*drv)->DoIOOperation(drv, main, outS, 1, kAudioServerPlugInIOOperationWriteMix, frames, &ci, wbuf, NULL);
        (*drv)->DoIOOperation(drv, main, inS, 1, kAudioServerPlugInIOOperationReadInput, frames, &ci, rbuf, NULL);
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double us = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1000.0 / iters;
    double budget = frames / 48000.0 * 1e6;
    CHECK(us < budget * 0.05, "costo per ciclo %.1f µs su %.0f µs disponibili a 48 kHz (%.2f%%)", us, budget, 100 * us / budget);
    if (box) {
        printf("— matrice di R4F BOX —\n");
        AudioObjectPropertyAddress ia = { kAudioObjectPropertyCustomPropertyInfoList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioServerPlugInCustomPropertyInfo info; UInt32 isz = 0;
        OSStatus ist = (*drv)->GetPropertyData(drv, main, 0, &ia, 0, NULL, sizeof info, &isz, &info);
        CHECK(ist == 0 && info.mSelector == 'r4fm' && info.mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
              "proprietà personalizzata 'r4fm' dichiarata (CFPropertyList)");
        AudioObjectPropertyAddress ma = { 'r4fm', kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        Boolean settable = false;
        (*drv)->IsPropertySettable(drv, main, 0, &ma, &settable);
        CFPropertyListRef cur = NULL; UInt32 csz = 0;
        (*drv)->GetPropertyData(drv, main, 0, &ma, 0, NULL, sizeof cur, &csz, &cur);
        CHECK(settable && cur && CFGetTypeID(cur) == CFDataGetTypeID() && CFDataGetLength(cur) == (CFIndex)(ch * sizeof(R4FRoute)),
              "di default la matrice è 1:1 (%u rotte), modificabile", ch);
        if (cur) CFRelease(cur);

        // uscite 1+2 → ingresso 5 a metà guadagno; uscita 3 → ingressi 1 e 2; tutto il resto muto
        R4FRoute m[4] = { {0, 4, 0.5f}, {1, 4, 0.5f}, {2, 0, 1.0f}, {2, 1, 1.0f} };
        CHECK(setMatrix(drv, main, m, 4) == 0, "matrice impostata");
        CHECK(gStoredMatrix == 1, "matrice salvata nella memoria del driver (resta dopo un riavvio) [scritture: %d]", gStoredMatrix);
        int ok = ioCycle(drv, main, outS, inS, frames, 900000, wbuf, rbuf);
        double e5 = 0, e1 = 0, eSilent = 0;
        for (UInt32 f = 0; f < frames; f++) {
            e5 = fmax(e5, fabs(rbuf[f * ch + 4] - 0.5 * (wbuf[f * ch + 0] + wbuf[f * ch + 1])));
            e1 = fmax(e1, fabs(rbuf[f * ch + 0] - wbuf[f * ch + 2]) + fabs(rbuf[f * ch + 1] - wbuf[f * ch + 2]));
            for (UInt32 c = 2; c < ch; c++) if (c != 4) eSilent = fmax(eSilent, fabs(rbuf[f * ch + c]));
        }
        CHECK(ok && e5 < 1e-6, "ingresso 5 = media delle uscite 1 e 2 (errore %g)", e5);
        CHECK(e1 < 1e-7, "uscita 3 su ingressi 1 e 2 (fan-out)");
        CHECK(eSilent == 0, "gli altri %u ingressi sono muti", ch - 3);
        cur = NULL;
        (*drv)->GetPropertyData(drv, main, 0, &ma, 0, NULL, sizeof cur, &csz, &cur);
        CHECK(cur && CFDataGetLength(cur) == 4 * sizeof(R4FRoute) && memcmp(CFDataGetBytePtr(cur), m, sizeof m) == 0,
              "la matrice si rilegge identica");
        if (cur) CFRelease(cur);

        R4FRoute* id = calloc(ch, sizeof(R4FRoute));
        for (UInt32 c = 0; c < ch; c++) { id[c].src = c; id[c].dst = c; id[c].gain = 1; }
        setMatrix(drv, main, id, ch);
        ioCycle(drv, main, outS, inS, frames, 950000, wbuf, rbuf);
        CHECK(memcmp(wbuf, rbuf, (size_t)frames * ch * sizeof(float)) == 0, "di nuovo 1:1: copia bit-exact");
        R4FRoute bad = { 300, 0, 1 };
        CHECK(setMatrix(drv, main, &bad, 1) == 0, "rotta fuori dai canali ignorata senza errori");

        // costo con una matrice piena (ogni uscita su due ingressi)
        R4FRoute* full = calloc(ch * 2, sizeof(R4FRoute));
        for (UInt32 c = 0; c < ch; c++) { full[2*c] = (R4FRoute){ c, c, 0.5f }; full[2*c+1] = (R4FRoute){ c, (c + 1) % ch, 0.5f }; }
        setMatrix(drv, main, full, ch * 2);
        uint64_t t1 = mach_absolute_time();
        for (int i = 0; i < 2000; i++) ioCycle(drv, main, outS, inS, frames, 1e6 + (double)i * frames, wbuf, rbuf);
        double us2 = (double)(mach_absolute_time() - t1) * tb.numer / tb.denom / 1000.0 / 2000;
        CHECK(us2 < budget * 0.05, "costo con %u rotte: %.1f µs su %.0f µs (%.2f%%)", ch * 2, us2, budget, 100 * us2 / budget);
        free(id); free(full);
    }
    (*drv)->StopIO(drv, main, 1);

    printf(gFail ? "\nDRIVERTEST FALLITO\n" : "\nDRIVERTEST OK\n");
    return gFail;
}
