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

---

## Architektura

```
agri_nav/
├── CMakeLists.txt              # Buduje agri_nav_core (static) + agri_nav_ffi (shared .so)
├── core/
│   ├── include/
│   │   ├── GnssProcessor.h     # Interfejs GNSS (abstract), struct GnssPosition
│   │   ├── GnssSimulator.h     # Symulator toru kołowego (wątek C++)
│   │   ├── NavEngine.h         # Silnik prowadzenia po linii AB
│   │   └── SwathPlanner.h      # Planowanie równoległych ścieżek uprawowych
│   └── src/
│       ├── GnssSimulator.cpp   # Tor kołowy, NMEA $GPGGA, callback 100 ms
│       ├── NavEngine.cpp       # Cross-track ENU (WGS-84 → metry, formuła 2D)
│       └── SwathPlanner.cpp    # Algorytm przycinania linii do wielokąta pola
├── bridge/
│   ├── agri_nav_ffi.h          # Publiczne C API (brak wyjątków, POD-only)
│   └── agri_nav_ffi.cpp        # Implementacja: NavContext, SimContext, SwathPlanner
└── app/                        # Flutter
    ├── pubspec.yaml
    └── lib/
        ├── main.dart           # Inicjalizacja FMTC ObjectBox
        ├── ffi/
        │   └── nav_bridge.dart # Dart: NavBridge, GnssSimulatorBridge, SwathPlannerBridge
        ├── offline/
        │   ├── offline_map_manager.dart  # FMTC: downloadRegion, stats, clearAll
        │   └── download_region_sheet.dart # BottomSheet: pobieranie map offline
        ├── models/
        │   └── field_model.dart          # FieldModel: granica, linia AB, szerokość robocza
        ├── services/
        │   └── field_service.dart        # Hive CRUD: save/get/delete pól uprawowych
        └── ui/
            ├── map_view.dart   # Główny ekran: mapa satelitarna, AB, swaths, ciągnik
            └── field_manager_screen.dart  # Ekran listy i zarządzania polami
```

---

## Warstwy

| Warstwa | Technologia | Odpowiedzialność |
|---|---|---|
| `core` | C++17, CMake 3.21 | GNSS, ENU cross-track, algorytm swath |
| `bridge` | C ABI | Czyste C API eksponowane przez `dart:ffi` (malloc/free, brak C++) |
| `app` | Flutter 3, Dart ≥3.3 | Mapa, UI nawigacji, offline cache |

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

// Planowanie ścieżek
FfiSwathList* agrinav_plan_swaths(
    const double* polygon, int32_t vertex_count,
    double ax, double ay, double bx, double by,
    double working_width   // [m]
);
void agrinav_free_swaths(FfiSwathList*);
```

---

## Zależności Flutter

```yaml
flutter_map: ^7.0.0
flutter_map_tile_caching: ^9.1.0   # ObjectBox backend, offline-first
latlong2: ^0.9.0
ffi: ^2.1.0
connectivity_plus: ^6.0.0
```

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

| Gest | Akcja |
|---|---|
| Dotknięcie mapy | Wyłącza tryb śledzenia ciągnika |
| Długie naciśnięcie | Dodaje wierzchołek granicy pola |
| Przycisk `crop_free` | Start/stop nagrywania granicy |
| Przycisk `grid` | Generuje ścieżki uprawowe (3 m) |
| Przycisk `gps_fixed` | Włącza/wyłącza śledzenie ciągnika |
| Przycisk satelita | Pobieranie map offline |
