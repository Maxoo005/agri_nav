#include "NavEngine.h"
#include <cmath>

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

namespace agrinav {

// ── Pomocnicza konwersja WGS-84 → lokalny układ ENU (origin = A) ─────────────

static constexpr double kMPerDegLat = 111320.0;

struct ENU2 { double e, n; }; // east [m], north [m]

static ENU2 toENU(double aLat, double aLon, double lat, double lon) {
    const double cosLat = std::cos(aLat * M_PI / 180.0);
    return {
        (lon - aLon) * kMPerDegLat * cosLat,   // east
        (lat - aLat) * kMPerDegLat              // north
    };
}

// ── Impl ─────────────────────────────────────────────────────────────────────

struct NavEngine::Impl {
    GnssProcessor& gnss;
    // Linia AB przechowywana jako WGS-84 (x=lat, y=lon — konwencja Vec2)
    double aLat{}, aLon{}, bLat{}, bLon{};
    bool hasLine{false};
    GuidanceCallback cb;

    explicit Impl(GnssProcessor& g) : gnss(g) {}
};

NavEngine::NavEngine(GnssProcessor& gnss) : d(new Impl(gnss)) {}
NavEngine::~NavEngine() { delete d; }

void NavEngine::setAbLine(Vec2 a, Vec2 b) {
    d->aLat = a.x; d->aLon = a.y;
    d->bLat = b.x; d->bLon = b.y;
    d->hasLine = true;
}
void NavEngine::resetAbLine() { d->hasLine = false; }

void NavEngine::setCallback(GuidanceCallback cb) { d->cb = std::move(cb); }

GuidanceOutput NavEngine::update() {
    GuidanceOutput out{};
    if (!d->hasLine) return out;

    auto pos = d->gnss.currentPosition();

    // Konwertuj B i ciągnik do ENU względem A
    const auto b = toENU(d->aLat, d->aLon, d->bLat, d->bLon);
    const auto p = toENU(d->aLat, d->aLon, pos.latitude, pos.longitude);

    const double abLen = std::sqrt(b.e * b.e + b.n * b.n);
    if (abLen < 0.01) return out; // guard: A == B

    // Poprawkowe odchylenie od linii AB (signed):
    //   + prawo gdy jedzie A→B, − lewo
    //   2D cross product: (AB × AP) z negacją znaku konwencji mat.
    //   ct = (b.n * p.e − b.e * p.n) / |AB|
    const double ct = (b.n * p.e - b.e * p.n) / abLen;

    // Kąt azymutu linii AB względem północy [deg]
    const double abBearing = std::atan2(b.e, b.n) * 180.0 / M_PI;
    // headingError = 0 dopóki nie mamy kursu z GNSS/kompasu
    out.headingError    = 0.0f;
    out.crossTrackError = static_cast<float>(ct);
    out.isValid         = d->hasLine && d->gnss.hasFixRTK();

    if (d->cb) d->cb(out);
    return out;
}

} // namespace agrinav

