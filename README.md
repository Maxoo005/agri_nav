# AgriNav — Rolnicza Nawigacja GPS

Aplikacja nawigacji precyzyjnej dla maszyn rolniczych. Rdzeń obliczeniowy w **C++17**, interfejs użytkownika we **Flutterze**, komunikacja przez **dart:ffi**.

---

## Funkcjonalności

| Funkcja | Status |
|---|---|
| Linia AB (punkt A i punkt B) | ✅ |
| Odchylenie poprzeczne (cross-track) w C++ | ✅ |
| Symulator GNSS (wątek C++, 100 ms) | ✅ |
| Mapa satelitarna Esri (offline-first FMTC) | ✅ |
| Pobieranie map offline przez Wi-Fi | ✅ |
| Planowanie ścieżek uprawowych (swath planning) | ✅ |
| Nagrywanie granic pola (długie naciśnięcie) | ✅ |
| Ikona ciągnika obracająca się wg kursu GPS | ✅ |
| Trwały zapis pól (Hive) — CRUD + serializacja JSON | ✅ |
| Ekran zarządzania polami (lista, wybór, usuwanie) | ✅ |
| Planowanie pełne z uwornicami (headland rings) | ✅ |
| Snap-to-nearest-swath (SwathGuidance, thread-safe) | ✅ |
| Section Control — detekcja zakrycia i nakładki | ✅ |
| Ślad GPS trasy uprawowej (CoverageService, Hive) | ✅ |
| Integracja z ULDK/GUGiK — pobieranie granic działek po nr TERYT | ✅ |
| Parser WKT (POLYGON / MULTIPOLYGON, EPSG:4326) | ✅ |
| Scalanie działek katastralnych (C++ Clipper2 Union + ENU buffer) | ✅ |
| Kreator pola geodezyjnego (multi-step: ULDK → scalenie → Hive) | ✅ |
| Integracja z ARiMR/LPIS — pobieranie upraw po obszarze lub nr gosp. | ✅ |
| Przetwarzanie geometrii LPIS (C++ union + RDP simplify + buffer 2 cm) | ✅ |
| Bulk import działek ARiMR — BottomSheet z kreatorem wielokrokowym | ✅ |
| Warstwa LPIS na mapie — zielone p.-przezroczyste wielokąty | ✅ |
| Cache offline ARiMR (Hive `arimr_lpis`) | ✅ |

---

## Architektura

```
agri_nav/
├── CMakeLists.txt              # Buduje agri_nav_core (static) + agri_nav_ffi (shared .so)
├── core/
│   ├── include/
│   │   ├── GnssProcessor.h     # Interfejs GNSS (abstract), struct GnssPosition
│   │   ├── GnssSimulator.h     # Symulator toru kołowego (wątek C++, NMEA $GPGGA)
│   │   │   ├── NavEngine.h         # Silnik prowadzenia po linii AB
│   │   ├── SwathPlanner.h      # Planowanie ścieżek z uwornicami (headland rings)
│   │   ├── SwathGuidance.h     # Snap-to-nearest-swath (thread-safe, ENU pre-filter)
│   │   ├── SectionControl.h    # Grid pokrycia pola + detekcja nakładki
│   │   ├── ParcelMerger.h      # Union działek (Clipper2): ENU buffer → boolean → WGS-84
│   │   └── GeometryProcessor.h # LPIS: union + RDP simplify (ε=0.3m) + buffer 2 cm
│   └── src/
│       ├── GnssSimulator.cpp   # Tor kołowy, NMEA $GPGGA, callback + polling API
│       ├── NavEngine.cpp       # Cross-track ENU (WGS-84 → metry, formuła 2D)
│       ├── SwathPlanner.cpp    # Algorytm + uwornice, nakładka, pełne planowanie
│       ├── SwathGuidance.cpp   # Cylinder spatial pre-filter, punkt-do-odcinka
│       ├── SectionControl.cpp  # Unordered_set<int64_t> jako haszowane komórki siatki
│       ├── ParcelMerger.cpp    # Clipper2 Union: centroida ENU, outward buffer, ring class.
│       └── GeometryProcessor.cpp # LPIS: InflatePaths → Union → SimplifyPaths → WGS-84
├── bridge/
│   ├── agri_nav_ffi.h          # Publiczne C API (brak wyjątków, POD-only)
│   └── agri_nav_ffi.cpp        # NavContext, SimContext, SwathPlanner, SwathGuidance,
│                               #   SectionControl, ParcelMerger — pełna implementacja FFI
├── third_party/
│   └── clipper2/               # Clipper2 1.4.0 — vendored (bez FetchContent)
└── app/                        # Flutter
    ├── pubspec.yaml
    └── lib/
        ├── main.dart           # Inicjalizacja FMTC ObjectBox + Hive coverage box
        ├── ffi/
        │   └── nav_bridge.dart # Dart: NavBridge, GnssSimulatorBridge,
        │                       #   SwathPlannerBridge, SwathGuidanceBridge,
        │                       #   SectionControlBridge, ParcelMergerBridge
        ├── offline/
        │   ├── offline_map_manager.dart  # FMTC: downloadRegion, stats, clearAll
        │   └── download_region_sheet.dart # BottomSheet: pobieranie map offline
        ├── models/
        │   ├── field_model.dart          # FieldModel: granica, linia AB, szerokość robocza, arimrParcelIds
        │   └── arimr_parcel.dart         # ArimrParcel: model działki LPIS z ARiMR (JSON/Hive)
        ├── services/
        │   ├── field_service.dart        # Hive CRUD: save/get/delete pól uprawowych
        │   ├── coverage_service.dart     # Hive: zapis/odczyt śladu GPS, bufor + flush
        │   ├── geoportal_service.dart    # ULDK/GUGiK: fetch wg XY / TERYT, nudge
        │   ├── arimr_service.dart        # ARiMR ArcGIS REST: LPIS pagination, filtr, Hive cache
        │   └── wkt_parser.dart          # WKT → List<LatLng> (POLYGON + MULTIPOLYGON)
        └── ui/
            ├── map_view.dart            # Główny ekran: mapa, AB, swaths, ciągnik, snap-guidance
            ├── field_manager_screen.dart # Ekran listy i zarządzania polami
            ├── field_builder_screen.dart # Kreator pola: ULDK → scalenie → zapis
            ├── arimr_import_sheet.dart  # Import LPIS: obszar → ARiMR → C++ → Hive
            └── cadastral_widgets.dart   # TerytSearchSheet — wyszukiwanie po nr ewidencyjnym
```

---

## Warstwy

| Warstwa | Technologia | Odpowiedzialność |
|---|---|---|
| `core` | C++17, CMake 3.21 | GNSS, ENU cross-track, swath + headland, snap-guidance, coverage grid, parcel union, LPIS processing |
| `bridge` | C ABI | Czyste C API eksponowane przez `dart:ffi` (malloc/free, brak C++) |
| `app` | Flutter 3, Dart ≥3.3 | Mapa, UI nawigacji, offline cache, zapis śladu GPS, kreator pola ULDK, bulk import ARiMR |
| `third_party` | Clipper2 1.4.0 (vendored) | Operacje boolowskie na wielokątach 2D (Union, Buffer, SimplifyPaths RDP) |

---

## C++ — kluczowe algorytmy

### Cross-track error (`NavEngine.cpp`)
Konwersja WGS-84 → lokalny ENU (origin = punkt A), następnie 2D cross product:
```
ct = (b.n · p.e − b.e · p.n) / |AB|   [m, + prawo / − lewo]
```

### Swath planning (`SwathPlanner.cpp`)
1. Wyznacz kierunek $\hat{d}$ (AB) i prostopadły $\hat{p}$
2. Rzutuj wierzchołki wielokąta na $\hat{p}$ → zakres $[t_{min}, t_{max}]$
3. Dla $t_k = t_{min} + k \cdot w$: wyznacz przecięcia linii z krawędziami wielokąta
4. Sortuj parametry $s$ wzdłuż $\hat{d}$ → pary wejście/wyjście = jeden swath
5. Konwertuj punkty ENU → WGS-84

### Headland planning (`SwathPlanner.cpp` — `agrinav_plan_full`)
Przed wyznaczeniem ścieżek wewnętrznych generowane są uwornicowe pierścienie:
- wielokąt jest sukcesywnie „erodowany" o $w/2$ (Sutherland-Hodgman offset),
- każdy pierścień staje się jedną pętlą jazdy cołem/uwornicy,
- liczba pierścieni sterowana przez `headlandLaps` (0 = brak uwornicy).

### Snap-to-nearest-swath (`SwathGuidance.cpp`)
`setSwaths()` przelicza wszystkie swaths do ENU przy inicjalizacji.  
`query()` stosuje filtr cylindryczny 50 m, następnie minimalizuje odległość punkt–odcinek.  
Wynik: `distanceM`, `swathIndex`, `side`, `headingErrorDeg` — thread-safe (std::mutex).

### Section Control (`SectionControl.cpp`)
Siatka kwadratowych komórek (domyślnie 1 m²) zakodowana jako `unordered_set<int64_t>`.  
`addStrip()` wyznacza rzut prostokąta narzędzia → klucze komórek → wstawia nowe.  
`checkOverlap()` — identyczna geometria, bez modyfikacji zbioru.  
`coveredAreaHa()` = liczba unikalnych komórek × $w^2$ / 10 000.

### Parcel Merger (`ParcelMerger.cpp`)
Scala wiele wielokątów działkowych (WGS-84) w jeden obrys pola:
1. Centroida wszystkich wierzchołków → lokalna ramka ENU [m].
2. Outward buffer `+bufferM` (domyślnie 5 cm) — eliminacja mikroszczelin między działkami.
3. **Union Boolean** (Clipper2, `FillRule::NonZero`).
4. Konwersja wyniku ENU → WGS-84.
5. Klasyfikacja pierścieni: CCW = `OuterPrimary/OuterSecondary`, CW = `HolePrimary/HoleSecondary`.
6. Wykrywanie pola wieloczęściowego (`isMultipart = true` gdy wiele outer rings).

---

## FFI API (`bridge/agri_nav_ffi.h`)

```c
// Nawigacja
NavHandle   agrinav_create();
void        agrinav_destroy(NavHandle);
void        agrinav_set_ab_line(NavHandle, double ax, double ay, double bx, double by);
void        agrinav_reset_ab_line(NavHandle);
FfiGuidance agrinav_update(NavHandle, FfiPosition);       // → crossTrackError [m]

// Symulator GNSS
SimHandle   agrinav_sim_create(double lat, double lon, double alt);
void        agrinav_sim_start(SimHandle, SimPositionCallback);  // wątek C++
void        agrinav_sim_stop(SimHandle);
FfiPosition agrinav_sim_get_position(SimHandle);          // polling bez callbacku
const char* agrinav_sim_last_nmea(SimHandle);             // ostatnie zdanie $GPGGA

// Planowanie ścieżek (podstawowe)
FfiSwathList* agrinav_plan_swaths(
    const double* polygon, int32_t vertex_count,
    double ax, double ay, double bx, double by,
    double working_width   // [m]
);
void agrinav_free_swaths(FfiSwathList*);

// Planowanie pełne (ścieżki + uwornice)
FfiPlanResult* agrinav_plan_full(
    const double* polygon, int32_t vertexCount,
    double ax, double ay, double bx, double by,
    double workingWidth, double overlapM, int32_t headlandLaps
);
void agrinav_free_plan(FfiPlanResult*);

// Snap-to-nearest-swath
GuidanceHandle agrinav_guidance_create();
void           agrinav_guidance_destroy(GuidanceHandle);
void           agrinav_guidance_set_swaths(GuidanceHandle,
                   const double* swathData, int32_t swathCount,
                   double originLat, double originLon);
FfiSnapResult  agrinav_guidance_query(GuidanceHandle,
                   double lat, double lon, float headingDeg);

// Section Control + Coverage Area
SectionHandle agrinav_section_create(double cell_size_m);
void          agrinav_section_destroy(SectionHandle);
void          agrinav_section_set_origin(SectionHandle, double lat, double lon);
float         agrinav_section_check_overlap(SectionHandle, double lat, double lon,
                  float heading_deg, double tool_width_m);
float         agrinav_section_add_strip(SectionHandle, double lat, double lon,
                  float heading_deg, double tool_width_m);
double        agrinav_section_covered_ha(SectionHandle);
void          agrinav_section_clear(SectionHandle);

// Scalanie działek katastralnych (Clipper2 Union)
FfiMergeResult* agrinav_merge_parcels(
    const double* polygons, const int32_t* sizes, int32_t parcel_count,
    double buffer_m     // outward buffer [m], np. 0.05
);
void agrinav_free_merge(FfiMergeResult*);
```

---

## Zależności Flutter

```yaml
flutter_map: ^7.0.0
flutter_map_tile_caching: ^9.1.0   # ObjectBox backend, offline-first
latlong2: ^0.9.0
ffi: ^2.1.0
connectivity_plus: ^6.0.0
hive_flutter: ^1.1.0               # Persystencja pól i śladu GPS
http: ^1.2.0                       # Zapytania REST do ULDK/GUGiK
uuid: ^4.4.0                       # Unikalne ID pól i działek
```

---

## GeoportalService (`app/lib/services/geoportal_service.dart`)

Serwis integrujący API **ULDK (GUGiK)** z lokalnym magazynem Hive.

| Metoda | Opis |
|---|---|
| `fetchAndCacheParcel(lat, lon)` | Pobiera działkę wg XY (WGS-84) i zapisuje w Hive |
| `fetchAndCacheByTeryt(teryt)` | Pobiera działkę wg numeru ewidencyjnego (TERYT) |
| `fetchParcelsMulti(ids)` | Pobiera wiele działek współbieżnie → `ParcelFetchResult` |
| `nudgeField(id, dx, dy)` | Przesuwa granicę działki o dx/dy [m] (korekta offsetu) |
| `resetNudge(id)` | Zeruje przesunięcie działki |

Wyjątki: `NoNetworkException` (brak sieci), `ULDKException` (błąd serwera).

---

## FieldBuilderScreen (`app/lib/ui/field_builder_screen.dart`)

Kreator pola geodezyjnego — przepływ wieloetapowy:

| Krok | Opis |
|---|---|
| **1. Input** | Wpisz prefiks obrębu i numery działek (po jednym na linię) |
| **2. Fetching** | Współbieżne pobieranie geometrii z ULDK (`fetchParcelsMulti`) |
| **3. Preview** | Lista pobranych działek z możliwością usunięcia błędnych |
| **4. Merging** | `ParcelMergerBridge.merge()` → C++ Clipper2 Union w izolate |
| **5. Done** | Wpisz nazwę pola → zapis do Hive → powrót z `FieldModel` |

---

## ArimrService (`app/lib/services/arimr_service.dart`)

Serwis integrujący **ULDK (GUGiK)** jako źródło danych LPIS (zamiast bezpośredniego ArcGIS REST ARiMR, który wymaga autoryzacji).

| Metoda | Opis |
|---|---|
| `fetchAgriculturalParcels(bounds)` | Siatka 5×5 próbkowań XY → unikalne działki w obszarze mapy |
| `fetchByFarmId(parcelId)` | Pobiera działkę po numerze ewidencyjnym TERYT |
| `getCachedParcels([bounds])` | Zwraca działki z lokalnego cache Hive (bbox filter) |
| `clearCache()` | Czyści skrzynkę Hive `arimr_lpis` |

Wyjątki: `ArimrNoNetworkException` (brak sieci → fallback do cache), `ArimrServiceException` (błąd parsowania).

### Android Network Security (`res/xml/network_security_config.xml`)

Plik definiuje politykę TLS aplikacji:
- ruch cleartext globalnie **wyłączony** (`usesCleartextTraffic="false"`),
- jawne zaufanie dla `geoportal.arimr.gov.pl` (system CA + user CA),
- odwołanie w `AndroidManifest.xml` przez `android:networkSecurityConfig`.

---

## CoverageService (`app/lib/services/coverage_service.dart`)

Singleton przechowujący ślad GPS bieżącej operacji polowej:

| Metoda | Opis |
|---|---|
| `startTracking(fieldId)` | Wczytuje zapisany ślad; uruchamia buforowanie |
| `addPoint(LatLng)` | Dołącza punkt; co 100 pkt. flush do Hive (async) |
| `stopTracking()` | Wymusza flush; czyści bufor |
| `loadForField(fieldId)` | Zwraca zapisany ślad do wyświetlenia/odtworzenia |
| `clearForField(fieldId)` | Kasuje ślad z Hive i pamięci |

---

## Budowanie Android

```bash
cd app
flutter pub get
flutter run          # debug na podłączonym urządzeniu
flutter build apk    # release APK
```

NDK: **27.0.12077973** (ustawiony w `app/android/app/build.gradle.kts`).  
CMake jest uruchamiane automatycznie przez Gradle — nie trzeba własnoręcznie budować `.so`.

---

## Użycie mapy w aplikacji

| Gest / przycisk | Akcja |
|---|---|
| Dotknięcie mapy | Wyłącza tryb śledzenia ciągnika |
| Długie naciśnięcie | Dodaje wierzchołek granicy pola |
| Przycisk `crop_free` | Start/stop nagrywania granicy |
| Przycisk `grid` | Generuje ścieżki uprawowe (3 m) |
| Przycisk `gps_fixed` | Włącza/wyłącza śledzenie ciągnika |
| Przycisk satelita | Pobieranie map offline |
| Przycisk `add_location` | Otwiera kreator pola geodezyjnego (ULDK) |
| Snap-guidance HUD | Wyświetla odległość i kierunek do nearest swath |
