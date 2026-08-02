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

// ── Wynik snap-to-nearest-swath ──────────────────────────────────────────────

/// Result of agrinav_guidance_query().
typedef struct {
    float   distanceM;       ///< perpendicular distance to nearest swath [m]
    int32_t swathIndex;      ///< index in swath list; -1 = no swaths loaded
    int32_t side;            ///< +1 = right of swath, -1 = left, 0 = on-line
    float   headingErrorDeg; ///< signed heading error [deg]: machine − swath
} FfiSnapResult;

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

// ── Symulator GPS (odłączony — zachowany na później) ─────────────────────────
//
// typedef void (*SimPositionCallback)(double lat, double lon,
//                                     double alt, float  accuracy);
// typedef void* SimHandle;
// SimHandle agrinav_sim_create(double startLat, double startLon, double startAlt);
// void      agrinav_sim_start(SimHandle h, SimPositionCallback cb);
// void      agrinav_sim_stop(SimHandle h);
// void      agrinav_sim_destroy(SimHandle h);
// int32_t     agrinav_sim_is_running(SimHandle h);
// FfiPosition agrinav_sim_get_position(SimHandle h);
// const char* agrinav_sim_last_nmea(SimHandle h);

// ── Full planning result (swaths + headland rings) ────────────────────────────

/// Combined result of agrinav_plan_full().
///
/// Memory layout (all pointers are heap-allocated, release via agrinav_free_plan):
///
///   swathData[swathCount × 4]          — startLat, startLon, endLat, endLon
///   ringPointData[totalPoints × 2]     — consecutive lat/lon pairs, all rings
///   ringPointCounts[ringCount]         — vertex count per ring
///
/// Struct layout on 64-bit (all pointers first for natural alignment):
///   +0   double*   swathData        (8 bytes)
///   +8   double*   ringPointData    (8 bytes)
///   +16  int32_t*  ringPointCounts  (8 bytes — pointer)
///   +24  int32_t   swathCount       (4 bytes)
///   +28  int32_t   ringCount        (4 bytes)
///   total = 32 bytes
typedef struct {
    double*   swathData;        ///< swathCount × 4 doubles
    double*   ringPointData;    ///< (sum of ringPointCounts) × 2 doubles
    int32_t*  ringPointCounts;  ///< ringCount int32 values
    int32_t   swathCount;
    int32_t   ringCount;
} FfiPlanResult;

/// Extended planner that returns both inner-field swaths and headland rings.
///
/// @param overlapM      Overlap between adjacent strips [m]  (0 = no overlap).
/// @param headlandLaps  Concentric headland passes to generate (0 = full-field).
/// @return              Heap-allocated FfiPlanResult; release with agrinav_free_plan().
FfiPlanResult* agrinav_plan_full(
    const double* polygon,
    int32_t       vertexCount,
    double        ax, double ay,
    double        bx, double by,
    double        workingWidth,
    double        overlapM,
    int32_t       headlandLaps
);

/// Releases all memory allocated by agrinav_plan_full().
void agrinav_free_plan(FfiPlanResult* result);

// ── Snap-to-nearest-swath guidance ───────────────────────────────────────────

/// Opaque handle to a SwathGuidance instance.
typedef void* GuidanceHandle;

/// Create a SwathGuidance instance.  Must be destroyed via agrinav_guidance_destroy().
GuidanceHandle agrinav_guidance_create();

/// Destroy a GuidanceHandle and free its memory.
void agrinav_guidance_destroy(GuidanceHandle h);

/// Load / replace the swath list used for snap-to-path queries.
///
/// @param swathData    Flat buffer in the same layout as FfiPlanResult::swathData:
///                     [startLat₀, startLon₀, endLat₀, endLon₀, ...]
/// @param swathCount   Number of swaths (not number of doubles).
/// @param originLat    WGS-84 latitude of the ENU origin (use point A).
/// @param originLon    WGS-84 longitude of the ENU origin.
void agrinav_guidance_set_swaths(GuidanceHandle h,
                                  const double*  swathData,
                                  int32_t        swathCount,
                                  double         originLat,
                                  double         originLon);

/// Query nearest swath for a given position and machine heading.
///
/// @param lat        Current latitude  [deg WGS-84].
/// @param lon        Current longitude [deg WGS-84].
/// @param headingDeg Machine heading, degrees from North (0 = N, 90 = E).
/// @return           FfiSnapResult by value (zero-copy on most ABIs).
FfiSnapResult agrinav_guidance_query(GuidanceHandle h,
                                      double         lat,
                                      double         lon,
                                      float          headingDeg);

// ── Section Control + Coverage Area ──────────────────────────────────────────

/// Opaque handle to a SectionControl instance.
typedef void* SectionHandle;

/// Create a SectionControl engine with the given grid cell size [m].
/// A cell size of 1.0 m gives 1 m² resolution (1 ha = 10 000 cells).
SectionHandle agrinav_section_create(double cell_size_m);

/// Destroy a SectionHandle and free its memory.
void agrinav_section_destroy(SectionHandle h);

/// Set the WGS-84 ENU origin for the coverage grid.
/// Must be called before first addStrip / checkOverlap.
void agrinav_section_set_origin(SectionHandle h, double lat, double lon);

/// Returns fraction [0, 1] of the tool footprint already covered (read-only).
float agrinav_section_check_overlap(SectionHandle h,
                                     double lat, double lon,
                                     float  heading_deg,
                                     double tool_width_m);

/// Mark tool footprint covered; returns overlap fraction BEFORE this strip.
float agrinav_section_add_strip(SectionHandle h,
                                 double lat, double lon,
                                 float  heading_deg,
                                 double tool_width_m);

/// Total covered area [ha].
double agrinav_section_covered_ha(SectionHandle h);

/// Net new (unique) area [ha] added by the most recent agrinav_section_add_strip()
/// call.  Returns 0.0 when the strip was fully inside already-covered area
/// (overlap → 100 %).  Use this to detect "no-progress" passes.
double agrinav_section_new_area_ha(SectionHandle h);

/// Erase all coverage data (retains origin + cell size).
void agrinav_section_clear(SectionHandle h);

// ── Scalanie działek katastralnych (Kreator Pola) ────────────────────────────

/// Typ pierścienia wynikowego.
///   0 = OuterPrimary   — zewnętrzna granica głównej części
///   1 = HolePrimary    — otwór w głównej części (np. las)
///   2 = OuterSecondary — kolejna część pola wieloczęściowego
///   3 = HoleSecondary  — otwór w kolejnej części
typedef int32_t FfiRingType;

/// Wynik scalania działek — płaski bufor wszystkich pierścieni.
///
/// Układ pamięci dla ring_data:
///   ring 0: lat₀,lon₀, lat₁,lon₁, ... (ring_vertex_counts[0] par)
///   ring 1: lat₀,lon₀, ... (ring_vertex_counts[1] par)
///   ...
typedef struct {
    double*      ring_data;           ///< (Σ ring_vertex_counts) × 2 wartości double
    int32_t*     ring_vertex_counts;  ///< liczba wierzchołków per pierścień
    FfiRingType* ring_types;          ///< typ każdego pierścienia
    int32_t      ring_count;          ///< łączna liczba pierścieni
    int32_t      is_multipart;        ///< 1 gdy działki nie stykają się
} FfiMergeResult;

/// Scala wiele wielokątów działek w jeden obrys pola.
///
/// @param polygon_data   Płaski bufor par (lat,lon) dla wszystkich wielokątów.
///                       Kolejność: polygon0_v0_lat, polygon0_v0_lon, ...
/// @param vertex_counts  Tablica liczby wierzchołków dla każdego wielokąta.
/// @param polygon_count  Liczba wielokątów wejściowych.
/// @param buffer_m       Outward buffer [m] do eliminacji mikroszczelin (np. 0.05).
/// @return               Wskaźnik na FfiMergeResult; zwolnij przez agrinav_free_merge_result().
///                       Nigdy NULL (błąd → ring_count == 0).
FfiMergeResult* agrinav_merge_parcels(
    const double*  polygon_data,
    const int32_t* vertex_counts,
    int32_t        polygon_count,
    double         buffer_m
);

/// Zwalnia pamięć przydzieloną przez agrinav_merge_parcels().
void agrinav_free_merge_result(FfiMergeResult* result);

// ── Przetwarzanie geometrii LPIS (ARiMR) — union + simplify + buffer ─────────

/// Opcje przetwarzania geometrii LPIS.
/// Przekazywane jako struct by value (packed: bez paddingu inter-field na 64-bit).
typedef struct {
    double  buffer_m;           ///< Outward buffer [m] (np. 0.02 = 2 cm)
    double  simplify_epsilon_m; ///< Epsilon uproszczenia RDP [m] (0 = brak)
    int32_t min_ring_vertices;  ///< Min. wierzchołków pierścienia (domyślnie 3)
    int32_t _pad;               ///< Wyrównanie do 8 bajtów — zawsze 0
} FfiLpisOptions;

/// Scala, upraszcza i buforuje wielokąty LPIS pobranych z ARiMR.
///
/// Używa GeometryProcessor::processLpis() z Clipper2:
///   1. Outward buffer +buffer_m.
///   2. Union Boolean (NonZero).
///   3. Simplify (Ramer–Douglas–Peucker, epsilon w metrach ENU).
///
/// @param polygon_data   Płaski bufor par (lat,lon) dla wszystkich wielokątów.
/// @param vertex_counts  Liczba wierzchołków każdego wielokąta.
/// @param polygon_count  Liczba wielokątów wejściowych.
/// @param opts           Opcje przetwarzania (pass by value).
/// @return               Wskaźnik na FfiMergeResult; zwolnij przez
///                       agrinav_free_merge_result(). Nigdy NULL.
FfiMergeResult* agrinav_process_lpis(
    const double*      polygon_data,
    const int32_t*     vertex_counts,
    int32_t            polygon_count,
    FfiLpisOptions     opts
);

// ── Headland ring guidance ────────────────────────────────────────────────────

/// Opaque handle to a HeadlandGuidance instance.
typedef void* HeadlandHandle;

/// Signed snap-to-nearest-headland-ring result.
///   crossTrackM > 0  → machine is to the RIGHT of the local ring tangent
///   crossTrackM < 0  → machine is to the LEFT
typedef struct {
    float   crossTrackM;       ///< signed cross-track distance [m]
    float   headingErrorDeg;   ///< signed heading error [deg]: machine − ring tangent
    int32_t ringIndex;         ///< index of the nearest ring; −1 when no rings loaded
    int32_t segmentIndex;      ///< index of the nearest segment within the ring
} FfiHeadlandResult;

/// Create a HeadlandGuidance instance.  Must be destroyed via agrinav_headland_destroy().
HeadlandHandle    agrinav_headland_create();

/// Destroy a HeadlandHandle and free its memory.
void              agrinav_headland_destroy(HeadlandHandle h);

/// Load / replace the headland ring geometry used for snap queries.
///
/// @param h               HeadlandGuidance handle.
/// @param ringPointData   Flat buffer of consecutive (lat, lon) pairs for all rings.
///                        Layout: ring0_pt0_lat, ring0_pt0_lon, ring0_pt1_lat, ...,
///                                ring1_pt0_lat, ...
/// @param ringPointCounts Array of vertex counts per ring (length = ringCount).
/// @param ringCount       Number of rings.
/// @param originLat       WGS-84 latitude  of the ENU origin (use AB-line point A).
/// @param originLon       WGS-84 longitude of the ENU origin.
void              agrinav_headland_set_rings(
                      HeadlandHandle    h,
                      const double*     ringPointData,
                      const int32_t*    ringPointCounts,
                      int32_t           ringCount,
                      double            originLat,
                      double            originLon);

/// Query the nearest headland ring segment for a given position / heading.
///
/// @param lat        Current latitude  [deg WGS-84].
/// @param lon        Current longitude [deg WGS-84].
/// @param headingDeg Machine heading, degrees from North (0 = N, 90 = E).
/// @return           FfiHeadlandResult by value; ringIndex == −1 when empty.
FfiHeadlandResult agrinav_headland_query(
                      HeadlandHandle h,
                      double         lat,
                      double         lon,
                      float          headingDeg);

#ifdef __cplusplus
}
#endif
