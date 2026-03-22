#pragma once
#include "GnssProcessor.h"
#include <cstdint>
#include <functional>

namespace agrinav {

// Punkt 2D w lokal­nym układzie metrycznym (ENU)
struct Vec2 { double x, y; };

// Wynik prowadzenia po linii AB
struct GuidanceOutput {
    float crossTrackError;  // [m] odchylenie od linii (+ prawo, – lewo)
    float headingError;     // [deg]
    bool  isValid;
};

// Główny silnik nawigacji: przyjmuje pozycję, zwraca sygnał prowadzenia
class NavEngine {
public:
    explicit NavEngine(GnssProcessor& gnss);
    ~NavEngine();

    // Ustaw linię AB (dwa punkty na polu)
    void setAbLine(Vec2 pointA, Vec2 pointB);

    // Wywołaj z każdą nową pozycją GNSS
    GuidanceOutput update();

    // Callback wywoływany przy każdym update()
    using GuidanceCallback = std::function<void(const GuidanceOutput&)>;
    void setCallback(GuidanceCallback cb);

private:
    struct Impl;
    Impl* d;
};

} // namespace agrinav
