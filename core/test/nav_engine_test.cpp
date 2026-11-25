#include "NavEngine.h"
#include "test_support.h"

using namespace agrinav;
using namespace testutil;

namespace {

struct FakeGnss : GnssProcessor {
    GnssPosition pos{52.0, 17.0, 100.0, 0.02f, 0.0};
    void processNmea(const char*) override {}
    GnssPosition currentPosition() const override { return pos; }
    bool hasFixRTK() const override { return pos.accuracy < 0.05f; }
    void moveTo(LatLon p) { pos.latitude = p.lat; pos.longitude = p.lon; }
};

struct NavEngineTest : ::testing::Test {
    Frame f;
    FakeGnss gnss;
    NavEngine nav{gnss};

    void line(double ae, double an, double be, double bn) {
        const auto a = f.at(ae, an), b = f.at(be, bn);
        nav.setAbLine({a.lat, a.lon}, {b.lat, b.lon});  // Vec2: x=lat, y=lon
    }
    GuidanceOutput at(double e, double n) {
        gnss.moveTo(f.at(e, n));
        return nav.update();
    }
};

TEST_F(NavEngineTest, NoLineIsInvalid) { EXPECT_FALSE(at(0, 0).isValid); }

TEST_F(NavEngineTest, OnLineHasZeroError) {
    line(0, 0, 0, 100);
    const auto g = at(0, 50);
    EXPECT_TRUE(g.isValid);
    EXPECT_NEAR(g.crossTrackError, 0.0, 1e-3);
}

TEST_F(NavEngineTest, RightIsPositiveLeftIsNegative) {
    line(0, 0, 0, 100);  // na północ
    EXPECT_NEAR(at(2.5, 50).crossTrackError, 2.5, 1e-3);
    EXPECT_NEAR(at(-2.5, 50).crossTrackError, -2.5, 1e-3);
}

TEST_F(NavEngineTest, ReversingLineFlipsSign) {
    line(0, 100, 0, 0);
    EXPECT_NEAR(at(2.5, 50).crossTrackError, -2.5, 1e-3);
}

TEST_F(NavEngineTest, DiagonalLineReferenceValue) {
    line(0, 0, 100, 100);
    // Punkt (10,0): odległość od prostej N=E wynosi 10/√2, po prawej.
    EXPECT_NEAR(at(10, 0).crossTrackError, 10.0 / std::sqrt(2.0), 1e-3);
}

TEST_F(NavEngineTest, LineIsInfiniteBeyondEndpoints) {
    line(0, 0, 0, 100);
    EXPECT_NEAR(at(1, 500).crossTrackError, 1.0, 1e-3);
    EXPECT_NEAR(at(1, -500).crossTrackError, 1.0, 1e-3);
}

TEST_F(NavEngineTest, CoincidentPointsAreInvalid) {
    line(0, 0, 0, 0);
    EXPECT_FALSE(at(1, 1).isValid);
    line(0, 0, 0.005, 0);  // poniżej progu 1 cm
    EXPECT_FALSE(at(1, 1).isValid);
}

TEST_F(NavEngineTest, ValidityFollowsRtkFix) {
    line(0, 0, 0, 100);
    gnss.pos.accuracy = 2.0f;
    const auto g = at(1, 0);
    EXPECT_FALSE(g.isValid);
    EXPECT_NEAR(g.crossTrackError, 1.0, 1e-3);  // wartość nadal policzona
}

TEST_F(NavEngineTest, ResetInvalidatesLine) {
    line(0, 0, 0, 100);
    nav.resetAbLine();
    EXPECT_FALSE(at(1, 1).isValid);
}

TEST_F(NavEngineTest, CallbackReceivesOutput) {
    int calls = 0;
    float last = 0;
    nav.setCallback([&](const GuidanceOutput& o) { ++calls; last = o.crossTrackError; });
    at(3, 0);  // bez linii callback nie jest wołany
    EXPECT_EQ(calls, 0);
    line(0, 0, 0, 100);
    at(3, 0);
    EXPECT_EQ(calls, 1);
    EXPECT_NEAR(last, 3.0, 1e-3);
}

// headingError to na razie stałe 0 (opisane w kodzie) — pilnujemy kontraktu.
TEST_F(NavEngineTest, HeadingErrorIsCurrentlyAlwaysZero) {
    line(0, 0, 100, 0);
    EXPECT_NEAR(at(0, 0).headingError, 0.0, 1e-6);
}

TEST_F(NavEngineTest, SouthernAndWesternHemisphere) {
    f = Frame{-33.5, -60.25};
    line(0, 0, 0, 100);
    EXPECT_NEAR(at(4, 20).crossTrackError, 4.0, 1e-3);
}

// Projekt nie używa UTM — lokalne ENU musi być ciągłe na granicach stref UTM.
TEST_F(NavEngineTest, ContinuousAcrossUtmZoneBoundaries) {
    for (double lon : {18.0, 24.0}) {
        f = Frame{52.0, lon};
        line(0, 0, 0, 100);
        EXPECT_NEAR(at(-0.5, 50).crossTrackError, -0.5, 1e-3) << lon;
        EXPECT_NEAR(at(0.5, 50).crossTrackError, 0.5, 1e-3) << lon;
    }
}

TEST_F(NavEngineTest, NearPoleIsFinite) {
    f = Frame{89.999, 10.0};
    line(0, 0, 0, 50);
    EXPECT_NEAR(at(1, 10).crossTrackError, 1.0, 1e-3);
}

// ── Znane błędy ──────────────────────────────────────────────────────────────

TEST_F(NavEngineTest, XfailDatelineCrossing) {
    // A tuż przed 180°E, ciągnik 2 m dalej na wschód (po drugiej stronie).
    f = Frame{0.0, 179.99999};
    line(0, 0, 0, 100);
    auto p = f.at(2, 50);
    p.lon -= 360.0;
    gnss.moveTo(p);
    const auto g = nav.update();
    AGRINAV_XFAIL("brak zawijania długości geograficznej na 180°",
                  EXPECT_NEAR(g.crossTrackError, 2.0, 1e-2));
}

TEST_F(NavEngineTest, XfailNaNPositionReportedAsValid) {
    line(0, 0, 0, 100);
    gnss.moveTo({kNaN, kNaN});
    const auto g = nav.update();
    AGRINAV_XFAIL("pozycja NaN daje isValid=true i XTE=NaN", EXPECT_FALSE(g.isValid));
}

}  // namespace
