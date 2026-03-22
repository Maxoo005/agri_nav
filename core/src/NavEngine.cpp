#include "NavEngine.h"

namespace agrinav {

struct NavEngine::Impl {
    GnssProcessor& gnss;
    Vec2 A{}, B{};
    GuidanceCallback cb;

    explicit Impl(GnssProcessor& g) : gnss(g) {}
};

NavEngine::NavEngine(GnssProcessor& gnss) : d(new Impl(gnss)) {}
NavEngine::~NavEngine() { delete d; }

void NavEngine::setAbLine(Vec2 a, Vec2 b) { d->A = a; d->B = b; }

void NavEngine::setCallback(GuidanceCallback cb) { d->cb = std::move(cb); }

GuidanceOutput NavEngine::update() {
    // TODO: cross-track error relative to AB line
    GuidanceOutput out{};
    out.isValid = d->gnss.hasFixRTK();
    if (d->cb) d->cb(out);
    return out;
}

} // namespace agrinav
