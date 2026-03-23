#pragma once
#include <vector>

namespace agrinav {

/// Para współrzędnych WGS-84.
struct LatLon {
    double lat;
    double lon;
};

/// Jeden przejazd (swath): odcinek od punktu startowego do końcowego.
struct Swath {
    LatLon start;
    LatLon end;
};

/// Wynik planowania ścieżek uprawowych.
struct SwathPlan {
    std::vector<Swath> swaths;
};

/// Algorytm generowania równoległych ścieżek uprawowych (parallel swath lines).
///
/// Dane wejściowe są w WGS-84. Obliczenia wykonywane w lokalnym układzie ENU
/// (East-North-Up) z punktem A jako początkiem układu — minimalizuje błędy
/// projekcji dla typowych pól do ~10 km.
///
/// Algorytm:
///  1. Wyznacz wektor kierunkowy AB i prostopadły (p).
///  2. Rzutuj wierzchołki wielokąta na oś p → zakres [t_min, t_max].
///  3. Dla każdego t_k = t_min + k * working_width:
///     a. Dla każdej krawędzi wielokąta wyznacz punkt przecięcia z linią.
///     b. Posortuj przecięcia wzdłuż kierunku d → pary wejście/wyjście.
///     c. Każda para to jeden swath.
///  4. Konwertuj punkty z powrotem na WGS-84.
class SwathPlanner {
public:
    /// @param polygon        Wierzchołki granic pola (WGS-84, kolejność CW lub CCW).
    ///                       Nie musi być zamknięty (ostatni = pierwszy).
    /// @param a              Punkt A linii odniesienia (WGS-84).
    /// @param b              Punkt B linii odniesienia (WGS-84).
    /// @param workingWidthM  Szerokość robocza maszyny [m] — odstęp między liniami.
    /// @return               Lista ścieżek gotowa do przesłania przez FFI.
    static SwathPlan plan(
        const std::vector<LatLon>& polygon,
        LatLon                     a,
        LatLon                     b,
        double                     workingWidthM
    );
};

} // namespace agrinav
