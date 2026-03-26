#pragma once
#include "SwathPlanner.h"  // for agrinav::LatLon
#include <vector>

namespace agrinav {

/// Typ pierścienia w wyniku scalania działek.
enum class RingType : int32_t {
    OuterPrimary    = 0,  ///< Zewnętrzna granica głównej części pola.
    HolePrimary     = 1,  ///< Otwór (np. las) w głównej części.
    OuterSecondary  = 2,  ///< Kolejna część (pole wieloczęściowe).
    HoleSecondary   = 3,  ///< Otwór w kolejnej części.
};

/// Pojedynczy pierścień wynikowy.
struct MergeRing {
    std::vector<LatLon> points;
    RingType type;
};

/// Wynik scalania działek katastralnych.
struct MergeResult {
    std::vector<MergeRing> rings;
    /// true  — działki nie stykają się; wynik to pole wieloczęściowe.
    bool isMultipart = false;
};

/// Scala wiele wielokątów działkowych w jeden obrys pola.
///
/// Algorytm:
///   1. Konwersja WGS-84 → lokalne ENU [m] (punkt referencyjny = centroida).
///   2. Outward buffer +bufferM (domyślnie 5 cm) → eliminacja mikroszczelin.
///   3. Union Boolean (Clipper2, FillRule::NonZero).
///   4. Konwersja ENU → WGS-84.
///   5. Klasyfikacja pierścieni: CCW = outer, CW = hole.
///   6. Wykrywanie pola wieloczęściowego (wiele zewnętrznych granic).
class ParcelMerger {
public:
    /// @param parcels   Lista wielokątów wejściowych (WGS-84).
    /// @param bufferM   Outward buffer w metrach (domyślnie 0.05 = 5 cm).
    /// @return          Wynik scalania.
    static MergeResult merge(
        const std::vector<std::vector<LatLon>>& parcels,
        double bufferM = 0.05
    );
};

} // namespace agrinav
