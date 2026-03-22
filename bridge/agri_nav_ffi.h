#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Uchwyt silnika nawigacyjnego (nieprzezroczysty wskaźnik)
typedef void* NavHandle;

// Dane pozycji przekazywane do Fluttera przez FFI
typedef struct {
    double latitude;
    double longitude;
    float  accuracy;
} FfiPosition;

// Wynik prowadzenia po linii AB
typedef struct {
    float crossTrackError; // [m]
    float headingError;    // [deg]
    int   isValid;         // 0 lub 1
} FfiGuidance;

NavHandle agrinav_create();
void      agrinav_destroy(NavHandle h);

void      agrinav_set_ab_line(NavHandle h,
                               double ax, double ay,
                               double bx, double by);

FfiGuidance agrinav_update(NavHandle h, FfiPosition pos);

#ifdef __cplusplus
}
#endif
