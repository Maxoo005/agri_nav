#include "agri_nav_ffi.h"
#include "NavEngine.h"

// Prosta implementacja GnssProcessor oparta o dane przekazane z Fluttera
struct FfiGnssAdapter : agrinav::GnssProcessor {
    agrinav::GnssPosition pos{};

    void processNmea(const char*) override {}  // nieużywane przy FFI push
    agrinav::GnssPosition currentPosition() const override { return pos; }
    bool hasFixRTK() const override { return pos.accuracy < 0.05f; }
};

struct NavContext {
    FfiGnssAdapter  gnss;
    agrinav::NavEngine engine{gnss};
};

extern "C" {

NavHandle agrinav_create() { return new NavContext(); }
void      agrinav_destroy(NavHandle h) { delete static_cast<NavContext*>(h); }

void agrinav_set_ab_line(NavHandle h,
                          double ax, double ay,
                          double bx, double by) {
    auto* ctx = static_cast<NavContext*>(h);
    ctx->engine.setAbLine({ax, ay}, {bx, by});
}

FfiGuidance agrinav_update(NavHandle h, FfiPosition pos) {
    auto* ctx = static_cast<NavContext*>(h);
    ctx->gnss.pos.latitude  = pos.latitude;
    ctx->gnss.pos.longitude = pos.longitude;
    ctx->gnss.pos.accuracy  = pos.accuracy;

    auto out = ctx->engine.update();
    return FfiGuidance{out.crossTrackError, out.headingError,
                        out.isValid ? 1 : 0};
}

} // extern "C"
