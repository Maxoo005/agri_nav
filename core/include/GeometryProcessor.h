#pragma once
#include "ParcelMerger.h"  // for agrinav::LatLon, MergeResult
#include <vector>

namespace agrinav {

/// Opcje przetwarzania geometrii LPIS.
struct LpisProcessOptions {
    /// Outward buffer [m] eliminujący mikroszczelin między działkami.
    /// Domyślnie 0.02 m (2 cm) — mniejszy niż dla danych katastralnych (5 cm),
    /// bo granice ARiMR są z natury nieco luźniejsze.
    double bufferM = 0.02;

    /// Epsilon uproszczenia Ramer-Douglas-Peucker [m] w układzie ENU.
    /// 0.0 = brak uproszczenia.
    /// Zalecane: 0.3 m dla LPIS (granice agrarne nie potrzebują centymetrowej
    /// precyzji, a mniejsza liczba wierzchołków przyspiesza SwathPlanner).
    double simplifyEpsilonM = 0.3;

    /// Minimalna liczba wierzchołków pierścienia po uproszczeniu.
    /// Pierścienie z mniejszą liczbą wierzchołków są odrzucane.
    int32_t minRingVertices = 3;
};

/// Procesor geometrii LPIS — używany przez ArimrImportSheet w Flutterze.
///
/// Algorytm (wszystkie operacje w lokalnym ENU [m]):
///   1. Centroida wejściowych wielokątów → radam ENU.
///   2. Outward buffer +bufferM (opcja) → eliminacja mikroszczelin.
///   3. Union Boolean (Clipper2, FillRule::NonZero).
///   4. Simplify (Ramer–Douglas–Peucker przez Clipper2::SimplifyPaths).
///   5. Konwersja ENU → WGS-84.
///   6. Klasyfikacja pierścieni + wykrywanie multipart (jak w ParcelMerger).
class GeometryProcessor {
public:
    /// Scala i upraszcza wielokąty LPIS.
    ///
    /// @param parcels  Lista wielokątów wejściowych (WGS-84).
    /// @param opts     Opcje przetwarzania (buffer, simplify epsilon).
    /// @return         Wynik zgodny z MergeResult — identyczna struktura
    ///                 jak w ParcelMerger, reużywana przez FFI.
    static MergeResult processLpis(
        const std::vector<std::vector<LatLon>>& parcels,
        const LpisProcessOptions& opts = {}
    );
};

} // namespace agrinav
