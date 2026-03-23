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
    double altitude;   // [m] n.p.m.
    float  accuracy;   // [m] pozioma dokładność
} FfiPosition;

// Wynik prowadzenia po linii AB
typedef struct {
    float crossTrackError; // [m]
    float headingError;    // [deg]
    int   isValid;         // 0 lub 1
} FfiGuidance;

// Zwraca wersję biblioteki jako liczba całkowita (aktualnie: 1).
int32_t   agrinav_version();

NavHandle agrinav_create();
void      agrinav_destroy(NavHandle h);

void      agrinav_set_ab_line(NavHandle h,
                               double ax, double ay,
                               double bx, double by);
// Kasuje aktywną linię AB (engine.isValid() → false do kolejnego setAbLine).
void      agrinav_reset_ab_line(NavHandle h);

// Przesuwa pozycję do silnika i zwraca aktualny wynik prowadzenia.
FfiGuidance agrinav_update(NavHandle h, FfiPosition pos);

// Zwraca ostatnią pozycję zapisaną w silniku (po agrinav_update).
FfiPosition agrinav_get_position(NavHandle h);

// ── Symulator GPS ─────────────────────────────────────────────────────────────

// Callback wywoływany z wątku symulatora co 100 ms.
// Argumenty: latitude, longitude, altitude [m], accuracy [m]
typedef void (*SimPositionCallback)(double lat, double lon,
                                    double alt, float  accuracy);

typedef void* SimHandle;

SimHandle agrinav_sim_create(double startLat, double startLon, double startAlt);
void      agrinav_sim_start(SimHandle h, SimPositionCallback cb);
void      agrinav_sim_stop(SimHandle h);
void      agrinav_sim_destroy(SimHandle h);

// Zwraca 1 jeśli wątek symulatora jest aktywny, 0 w przeciwnym razie.
int32_t     agrinav_sim_is_running(SimHandle h);

// Polling: zwraca ostatnią pozycję symulatora bez potrzeby callbacku.
FfiPosition agrinav_sim_get_position(SimHandle h);

// Zwraca ostatnie zdanie $GPGGA (wskaźnik ważny do następnego wywołania tick).
// Wołać tylko z wątku Dart (głównego), nie z callbacku.
const char* agrinav_sim_last_nmea(SimHandle h);

// ── Planowanie ścieżek uprawowych (swath planning) ───────────────────────────

/// Wynik planowania ścieżek: płaski bufor double + liczba swath'ów.
///
/// Układ danych w `data`:
///   [ startLat₀, startLon₀, endLat₀, endLon₀,
///     startLat₁, startLon₁, endLat₁, endLon₁, ... ]
///
/// Zwolnij pamięć przez agrinav_free_swaths().
typedef struct {
    double*  data;        ///< swath_count * 4 wartości double
    int32_t  swath_count; ///< liczba ścieżek
} FfiSwathList;

/// Generuje równoległe ścieżki uprawowe wypełniające wielokąt pola.
///
/// @param polygon       Wierzchołki granic pola (WGS-84), przeplatane: lat₀,lon₀,lat₁,lon₁,...
/// @param vertex_count  Liczba wierzchołków (nie par!).
/// @param ax,ay         Punkt A linii AB (WGS-84 lat/lon).
/// @param bx,by         Punkt B linii AB (WGS-84 lat/lon).
/// @param working_width Szerokość robocza [m].
/// @return              Wskaźnik na FfiSwathList (właściciel callera), nigdy NULL.
FfiSwathList* agrinav_plan_swaths(
    const double* polygon,
    int32_t       vertex_count,
    double        ax, double ay,
    double        bx, double by,
    double        working_width
);

/// Zwalnia pamięć przydzieloną przez agrinav_plan_swaths().
void agrinav_free_swaths(FfiSwathList* list);

#ifdef __cplusplus
}
#endif
