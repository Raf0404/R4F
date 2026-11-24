#!/usr/bin/env python3
"""Genera R4FBox.c dal sorgente di BlackHole (GPL-3.0) aggiungendo la matrice di instradamento.

R4F BOX è una scheda virtuale come BlackHole: i programmi scrivono sulle sue uscite e altri programmi
leggono dai suoi ingressi. Qui, tra uscite e ingressi, c'è una matrice (uscita i → ingresso j, guadagno):
- applicata dentro il driver nella lettura degli ingressi (stesso clock, nessuna latenza aggiunta);
- impostata dall'app R4F con la proprietà personalizzata 'r4fm' (CFData di rotte);
- salvata nella memoria del driver, così resta valida anche ad app chiusa e dopo un riavvio;
- senza matrice impostata vale 1:1, esattamente come BlackHole.

Ogni modifica è ancorata a un punto preciso del sorgente e verificata: se BlackHole cambia, lo script
si ferma invece di produrre un driver sbagliato.

    python3 driver/r4fbox/make_source.py   → driver/r4fbox/R4FBox.c
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "..", "vendor", "BlackHole", "BlackHole", "BlackHole.c")
OUT = os.path.join(HERE, "R4FBox.c")

s = open(SRC, encoding="utf-8").read()


def func_span(name):
    """Inizio e fine (approssimata: inizio della funzione successiva) della definizione di una funzione."""
    import re
    m = re.search(r"\nstatic (?:OSStatus|Boolean)\s+" + name + r"\([^;{]*\)\n\{", s)
    assert m, name
    nxt = re.search(r"\nstatic (?:OSStatus|Boolean|void|UInt32|Float64)\s+\w+\([^;{]*\)\n\{", s[m.end():])
    return m.start(), m.end() + (nxt.start() if nxt else len(s) - m.end())


def replace_in_func(name, old, new):
    global s
    a, b = func_span(name)
    body = s[a:b]
    assert body.count(old) == 1, (name, old[:60], body.count(old))
    s = s[:a] + body.replace(old, new, 1) + s[b:]


def replace_once(old, new):
    global s
    assert s.count(old) == 1, (old[:60], s.count(old))
    s = s.replace(old, new, 1)


HEADER = '''/*
 * R4F BOX — derivato da BlackHole (https://github.com/ExistentialAudio/BlackHole), GPL-3.0.
 * Modifiche: matrice di instradamento uscite → ingressi (proprietà 'r4fm'), generate da
 * driver/r4fbox/make_source.py. Il resto del file è il sorgente originale di BlackHole.
 */
'''

R4F_CODE = r'''
//==================================================================================================
//	R4F BOX — matrice di instradamento uscite → ingressi
//==================================================================================================

#include <stdatomic.h>
#include <unistd.h>

#define kR4F_PropertyMatrix     'r4fm'
#define kR4F_MaxRoutes          16384

#pragma pack(push, 1)
typedef struct { UInt16 src; UInt16 dst; Float32 gain; } R4FRoute;   // indici 0-based, 8 byte
#pragma pack(pop)

static R4FRoute                 gR4F_Routes[2][kR4F_MaxRoutes];
static UInt32                   gR4F_Count[2]   = { 0, 0 };
static _Atomic int              gR4F_Active     = 0;    // slot letto dal thread audio
static _Atomic int              gR4F_Identity   = 1;    // nessuna matrice: 1:1 come BlackHole
static _Atomic UInt64           gR4F_Cycles     = 0;    // letture completate (per riusare lo slot)
static pthread_mutex_t          gR4F_Mutex      = PTHREAD_MUTEX_INITIALIZER;
static CFDataRef                gR4F_Data       = NULL; // ultima matrice ricevuta

static CFDataRef R4F_CopyIdentity(void)
{
    R4FRoute r[kNumber_Of_Channels];
    for (UInt32 i = 0; i < kNumber_Of_Channels; i++) { r[i].src = (UInt16)i; r[i].dst = (UInt16)i; r[i].gain = 1.0f; }
    return CFDataCreate(NULL, (const UInt8*)r, sizeof(r));
}

static OSStatus R4F_SetMatrix(CFTypeRef inData, Boolean inPersist)
{
    if (inData == NULL || CFGetTypeID(inData) != CFDataGetTypeID()) return kAudioHardwareIllegalOperationError;
    CFDataRef d = (CFDataRef)inData;
    CFIndex len = CFDataGetLength(d);
    if (len % (CFIndex)sizeof(R4FRoute) != 0 || len / (CFIndex)sizeof(R4FRoute) > kR4F_MaxRoutes) return kAudioHardwareBadPropertySizeError;
    UInt32 n = (UInt32)(len / (CFIndex)sizeof(R4FRoute));
    const R4FRoute* in = (const R4FRoute*)CFDataGetBytePtr(d);

    pthread_mutex_lock(&gR4F_Mutex);
    int next = 1 - atomic_load(&gR4F_Active);
    // lo slot da riscrivere può essere ancora in lettura: si aspetta che passino due cicli audio
    UInt64 c0 = atomic_load(&gR4F_Cycles);
    for (int w = 0; w < 100 && (gDevice_IOIsRunning || gDevice2_IOIsRunning) && atomic_load(&gR4F_Cycles) < c0 + 2; w++) usleep(2000);

    UInt32 m = 0;
    UInt8 seen[kNumber_Of_Channels];
    memset(seen, 0, sizeof(seen));
    Boolean identity = true;
    for (UInt32 i = 0; i < n; i++) {
        if (in[i].src >= kNumber_Of_Channels || in[i].dst >= kNumber_Of_Channels) continue;
        if (in[i].gain == 0.0f) continue;
        gR4F_Routes[next][m++] = in[i];
        if (in[i].src != in[i].dst || in[i].gain != 1.0f || seen[in[i].src]) identity = false;
        seen[in[i].src] = 1;
    }
    if (m != kNumber_Of_Channels) identity = false;
    gR4F_Count[next] = m;
    atomic_store_explicit(&gR4F_Active, next, memory_order_release);
    atomic_store_explicit(&gR4F_Identity, identity ? 1 : 0, memory_order_release);
    if (gR4F_Data != NULL) CFRelease(gR4F_Data);
    gR4F_Data = CFDataCreateCopy(NULL, d);
    pthread_mutex_unlock(&gR4F_Mutex);

    if (inPersist && gPlugIn_Host != NULL) gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("r4f matrix"), d);
    return 0;
}

static CFDataRef R4F_CopyMatrix(void)
{
    pthread_mutex_lock(&gR4F_Mutex);
    CFDataRef d = gR4F_Data != NULL ? CFDataCreateCopy(NULL, gR4F_Data) : R4F_CopyIdentity();
    pthread_mutex_unlock(&gR4F_Mutex);
    return d;
}

static void R4F_LoadMatrix(void)
{
    if (gPlugIn_Host == NULL) return;
    CFPropertyListRef p = NULL;
    gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("r4f matrix"), &p);
    if (p != NULL) { R4F_SetMatrix(p, false); CFRelease(p); }
}

// Lettura degli ingressi: 1:1 (memcpy) oppure la matrice, sul blocco del ring in due parti.
static void R4F_ReadInput(Float32* out, UInt32 start, UInt32 first, UInt32 second, UInt32 frames)
{
    if (atomic_load_explicit(&gR4F_Identity, memory_order_acquire)) {
        memcpy(out, gRingBuffer + start * kNumber_Of_Channels, first * kNumber_Of_Channels * sizeof(Float32));
        memcpy(out + first * kNumber_Of_Channels, gRingBuffer, second * kNumber_Of_Channels * sizeof(Float32));
    } else {
        int sl = atomic_load_explicit(&gR4F_Active, memory_order_acquire);
        const R4FRoute* r = gR4F_Routes[sl];
        const UInt32 n = gR4F_Count[sl];
        memset(out, 0, (size_t)frames * kNumber_Of_Channels * sizeof(Float32));
        for (UInt32 f = 0; f < frames; f++) {
            const Float32* in = (f < first) ? gRingBuffer + (size_t)(start + f) * kNumber_Of_Channels
                                            : gRingBuffer + (size_t)(f - first) * kNumber_Of_Channels;
            Float32* o = out + (size_t)f * kNumber_Of_Channels;
            for (UInt32 i = 0; i < n; i++) o[r[i].dst] += r[i].gain * in[r[i].src];
        }
    }
    atomic_fetch_add_explicit(&gR4F_Cycles, 1, memory_order_release);
}

'''

# 1) codice R4F prima della definizione di BlackHole_Initialize
replace_once("\nstatic OSStatus\tBlackHole_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)\n{",
             R4F_CODE + "\nstatic OSStatus\tBlackHole_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)\n{")

# 2) matrice salvata caricata all'avvio del driver
replace_in_func("BlackHole_Initialize", "\tgPlugIn_Host = inHost;\n",
                "\tgPlugIn_Host = inHost;\n\tR4F_LoadMatrix();\n")

# 3) proprietà sul dispositivo
replace_in_func("BlackHole_HasDeviceProperty", "\t\tcase kAudioDevicePropertyStreams:\n\t\t\ttheAnswer = true;",
                "\t\tcase kAudioDevicePropertyStreams:\n\t\tcase kAudioObjectPropertyCustomPropertyInfoList:\n\t\tcase kR4F_PropertyMatrix:\n\t\t\ttheAnswer = true;")
replace_in_func("BlackHole_IsDevicePropertySettable", "\t\tcase kAudioDevicePropertyNominalSampleRate:\n\t\t\t*outIsSettable = true;",
                "\t\tcase kAudioObjectPropertyCustomPropertyInfoList:\n\t\t\t*outIsSettable = false;\n\t\t\tbreak;\n\n"
                "\t\tcase kR4F_PropertyMatrix:\n\t\tcase kAudioDevicePropertyNominalSampleRate:\n\t\t\t*outIsSettable = true;")
replace_in_func("BlackHole_GetDevicePropertyDataSize", "\tswitch(inAddress->mSelector)\n\t{\n",
                "\tswitch(inAddress->mSelector)\n\t{\n"
                "\t\tcase kAudioObjectPropertyCustomPropertyInfoList:\n\t\t\t*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);\n\t\t\tbreak;\n\n"
                "\t\tcase kR4F_PropertyMatrix:\n\t\t\t*outDataSize = sizeof(CFPropertyListRef);\n\t\t\tbreak;\n\n")
replace_in_func("BlackHole_GetDevicePropertyData", "\tswitch(inAddress->mSelector)\n\t{\n",
                "\tswitch(inAddress->mSelector)\n\t{\n"
                "\t\tcase kAudioObjectPropertyCustomPropertyInfoList:\n"
                "\t\t\tFailWithAction(inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo), theAnswer = kAudioHardwareBadPropertySizeError, Done, \"R4F: spazio insufficiente per CustomPropertyInfoList\");\n"
                "\t\t\t((AudioServerPlugInCustomPropertyInfo*)outData)->mSelector = kR4F_PropertyMatrix;\n"
                "\t\t\t((AudioServerPlugInCustomPropertyInfo*)outData)->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;\n"
                "\t\t\t((AudioServerPlugInCustomPropertyInfo*)outData)->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;\n"
                "\t\t\t*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);\n\t\t\tbreak;\n\n"
                "\t\tcase kR4F_PropertyMatrix:\n"
                "\t\t\tFailWithAction(inDataSize < sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, \"R4F: spazio insufficiente per la matrice\");\n"
                "\t\t\t*((CFPropertyListRef*)outData) = R4F_CopyMatrix();\n"
                "\t\t\t*outDataSize = sizeof(CFPropertyListRef);\n\t\t\tbreak;\n\n")
replace_in_func("BlackHole_SetDevicePropertyData", "\tswitch(inAddress->mSelector)\n\t{\n",
                "\tswitch(inAddress->mSelector)\n\t{\n"
                "\t\tcase kR4F_PropertyMatrix:\n"
                "\t\t\tFailWithAction(inDataSize != sizeof(CFPropertyListRef), theAnswer = kAudioHardwareBadPropertySizeError, Done, \"R4F: dimensione errata per la matrice\");\n"
                "\t\t\ttheAnswer = R4F_SetMatrix(*((const CFPropertyListRef*)inData), true);\n"
                "\t\t\tif (theAnswer == 0) { *outNumberPropertiesChanged = 1; outChangedAddresses[0].mSelector = kR4F_PropertyMatrix;\n"
                "\t\t\t\toutChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal; outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain; }\n"
                "\t\t\tbreak;\n\n")

# 4) lettura degli ingressi attraverso la matrice
replace_in_func("BlackHole_DoIOOperation",
                "            memcpy(ioMainBuffer, gRingBuffer + ringBufferFrameLocationStart * kNumber_Of_Channels, firstPartFrameSize * kNumber_Of_Channels * sizeof(Float32));\n"
                "            memcpy((Float32*)ioMainBuffer + firstPartFrameSize * kNumber_Of_Channels, gRingBuffer, secondPartFrameSize * kNumber_Of_Channels * sizeof(Float32));\n",
                "            R4F_ReadInput((Float32*)ioMainBuffer, ringBufferFrameLocationStart, firstPartFrameSize, secondPartFrameSize, inIOBufferFrameSize);\n")

open(OUT, "w", encoding="utf-8").write(HEADER + s)
print("ok:", os.path.relpath(OUT))
