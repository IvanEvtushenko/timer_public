#import "Touch.h"
#import <dlfcn.h>
#import <math.h>
#import <stdio.h>

// Раскладка структуры пальца — та же, что используют MiddleClick / Fingers / Swish.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, foo3, foo4;
    MTReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis; MTReadout mm; int zero2[2]; float unk2;
} MTFinger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTFinger *, int, double, int);

static CFMutableArrayRef (*pCreateList)(void);
static void (*pRegister)(MTDeviceRef, MTContactCallback);
static void (*pUnregister)(MTDeviceRef, MTContactCallback);
static int  (*pStart)(MTDeviceRef, int);
static int  (*pStop)(MTDeviceRef);

static CFMutableArrayRef gDevices;
static int gFingers = 1; static double gEdge = 0.03, gDistance = 0.25, gWindow = 0.6;
static TouchSwipeHandler gHandler; static BOOL gDebug;

typedef struct { int ident; float x0, y0, x, y; double t0; BOOL seen; } Track;
static Track gTracks[32]; static int gNTracks; static BOOL gFired;

static BOOL load(void) {
    static int state = 0;                      // 0 — не пробовали, 1 — ок, -1 — нет
    if (state) return state > 0;
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (h) {
        pCreateList = dlsym(h, "MTDeviceCreateList");
        pRegister   = dlsym(h, "MTRegisterContactFrameCallback");
        pUnregister = dlsym(h, "MTUnregisterContactFrameCallback");
        pStart      = dlsym(h, "MTDeviceStart");
        pStop       = dlsym(h, "MTDeviceStop");
    }
    state = (pCreateList && pRegister && pStart) ? 1 : -1;
    return state > 0;
}

static int callback(MTDeviceRef dev, MTFinger *f, int n, double ts, int frame) {
    if (gDebug) {
        printf("t=%.3f n=%d", ts, n);
        for (int i = 0; i < n; i++) printf("  [#%d st=%d x=%.3f y=%.3f]", f[i].identifier, f[i].state, f[i].normalized.pos.x, f[i].normalized.pos.y);
        printf("\n"); fflush(stdout);
    }
    for (int i = 0; i < gNTracks; i++) gTracks[i].seen = NO;
    for (int i = 0; i < n; i++) {
        float x = f[i].normalized.pos.x, y = f[i].normalized.pos.y; int k = -1;
        for (int j = 0; j < gNTracks; j++) if (gTracks[j].ident == f[i].identifier) { k = j; break; }
        if (k < 0) { if (gNTracks >= 32) continue; gTracks[gNTracks++] = (Track){ f[i].identifier, x, y, x, y, ts, YES }; }
        else { gTracks[k].x = x; gTracks[k].y = y; gTracks[k].seen = YES; }
    }
    int w = 0; for (int i = 0; i < gNTracks; i++) if (gTracks[i].seen) gTracks[w++] = gTracks[i]; gNTracks = w;
    if (gNTracks == 0) { gFired = NO; return 0; }          // все пальцы подняты — жест можно повторить
    if (gFired || gNTracks != gFingers) return 0;
    for (int i = 0; i < gNTracks; i++) {
        Track *t = &gTracks[i];
        if (t->x0 > gEdge) return 0;                        // палец появился не у края
        if (t->x - t->x0 < gDistance) return 0;             // ещё не доехал
        if (ts - t->t0 > gWindow) return 0;                 // слишком медленно
        if (fabsf(t->y - t->y0) > 0.3f) return 0;           // ушёл по вертикали
    }
    gFired = YES;
    if (gDebug) { printf(">>> SWIPE\n"); fflush(stdout); }
    if (gHandler) dispatch_async(dispatch_get_main_queue(), gHandler);
    return 0;
}

static int startDevices(void) {
    if (!load()) return 0;
    gDevices = pCreateList();
    if (!gDevices) return 0;
    CFIndex n = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        pRegister(d, callback); pStart(d, 0);
    }
    return (int)n;
}

static void stopDevices(void) {
    if (!gDevices) return;
    CFIndex n = CFArrayGetCount(gDevices);
    for (CFIndex i = 0; i < n; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(gDevices, i);
        if (pUnregister) pUnregister(d, callback);
        if (pStop) pStop(d);
        // MTDeviceRelease здесь НЕ вызывать: устройствами владеет массив, и CFRelease ниже
        // освобождает их сам. Лишний release ронял процесс при каждом пробуждении мака.
    }
    CFRelease(gDevices); gDevices = NULL; gNTracks = 0; gFired = NO;
}

int TouchStart(int fingers, double edge, double distance, double window, TouchSwipeHandler handler) {
    gFingers = fingers > 0 ? fingers : 1; gEdge = edge; gDistance = distance; gWindow = window;
    gHandler = [handler copy];
    return startDevices();
}
void TouchRestart(void) { stopDevices(); startDevices(); }
int  TouchDebug(void)   { gDebug = YES; return gDevices ? (int)CFArrayGetCount(gDevices) : startDevices(); }

void TouchSimulate(int n, const float *xs, const float *ys, double ts, int baseId) {
    MTFinger f[8] = {0};
    for (int i = 0; i < n && i < 8; i++) { f[i].identifier = baseId * 10 + i; f[i].state = 4; f[i].normalized.pos.x = xs[i]; f[i].normalized.pos.y = ys[i]; }
    callback(NULL, f, n, ts, 0);
}
