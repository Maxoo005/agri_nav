#include "HeadlandGuidance.h"
#include "SwathGuidance.h"
#include "test_support.h"

using namespace agrinav;
using namespace testutil;

namespace {

struct SwathGuidanceTest : ::testing::Test {
    Frame f;
    SwathGuidance g;
    SnapResult q(double e, double n, double hdg) {
        const auto p = f.at(e, n);
        return g.query(p.lat, p.lon, hdg);
    }
    void loadThree() {  // pasy N-S w E = 0, 10, 20
        g.setSwaths({{f.at(0, 0), f.at(0, 100)},
                     {f.at(10, 0), f.at(10, 100)},
                     {f.at(20, 0), f.at(20, 100)}}, f.at(0, 0));
    }
};

TEST_F(SwathGuidanceTest, EmptyReturnsMinusOne) {
    EXPECT_FALSE(g.hasSwaths());
    EXPECT_EQ(q(0, 0, 0).swathIndex, -1);
}

TEST_F(SwathGuidanceTest, PicksNearestSwathAndSide) {
    loadThree();
    EXPECT_TRUE(g.hasSwaths());
    auto r = q(11.5, 50, 0);
    EXPECT_EQ(r.swathIndex, 1);
    EXPECT_NEAR(r.distanceM, 1.5, 1e-3);
    EXPECT_EQ(r.side, 1);
    r = q(8, 50, 0);
    EXPECT_EQ(r.swathIndex, 1);
    EXPECT_EQ(r.side, -1);
}

TEST_F(SwathGuidanceTest, OnLineHasSideZero) {
    loadThree();
    EXPECT_EQ(q(10, 50, 0).side, 0);
}

TEST_F(SwathGuidanceTest, HeadingErrorSignedAndBidirectional) {
    loadThree();
    EXPECT_NEAR(q(0, 50, 5).headingErrorDeg, 5.0, 1e-6);
    EXPECT_NEAR(q(0, 50, 355).headingErrorDeg, -5.0, 1e-6);
    // Jazda w przeciwną stronę — błąd względem kierunku odwrotnego.
    EXPECT_NEAR(q(0, 50, 180).headingErrorDeg, 0.0, 1e-6);
    EXPECT_NEAR(q(0, 50, 187).headingErrorDeg, 7.0, 1e-6);
}

TEST_F(SwathGuidanceTest, BeyondSearchRadiusReturnsMinusOne) {
    loadThree();
    EXPECT_EQ(q(70.5, 50, 0).swathIndex, -1);
    EXPECT_EQ(q(0, 150.5, 0).swathIndex, -1);
    EXPECT_EQ(q(69.5, 50, 0).swathIndex, 2);
}

TEST_F(SwathGuidanceTest, PastEndReportsLateralOffset) {
    loadThree();
    EXPECT_NEAR(q(1, 110, 0).distanceM, 1.0, 1e-3);
    EXPECT_NEAR(q(1, -10, 0).distanceM, 1.0, 1e-3);
}

TEST_F(SwathGuidanceTest, HeadingBreaksTieBetweenCrossingSwaths) {
    g.setSwaths({{f.at(0, 0), f.at(0, 100)}, {f.at(-50, 50), f.at(50, 50)}}, f.at(0, 0));
    EXPECT_EQ(q(1, 51, 0).swathIndex, 0);
    EXPECT_EQ(q(1, 51, 90).swathIndex, 1);
}

TEST_F(SwathGuidanceTest, ZeroLengthSwathIsSafe) {
    g.setSwaths({{f.at(0, 0), f.at(0, 0)}}, f.at(0, 0));
    const auto r = q(0, 0, 45);
    EXPECT_EQ(r.swathIndex, 0);
    EXPECT_TRUE(std::isfinite(r.distanceM));
}

TEST_F(SwathGuidanceTest, EmptyListClears) {
    loadThree();
    g.setSwaths({}, f.at(0, 0));
    EXPECT_FALSE(g.hasSwaths());
}

TEST_F(SwathGuidanceTest, NaNPositionFindsNothing) {
    loadThree();
    EXPECT_EQ(g.query(kNaN, kNaN, 0).swathIndex, -1);
}

// poza zakresem: obsługiwane tylko współrzędne w Polsce
TEST_F(SwathGuidanceTest, XfailDateline) {
    f = Frame{0, 179.99999};
    g.setSwaths({{f.at(0, 0), f.at(0, 100)}}, f.at(0, 0));
    const auto p = f.at(2, 50);
    const int idx = g.query(p.lat, p.lon - 360.0, 0).swathIndex;
    AGRINAV_XFAIL("brak zawijania długości geograficznej na 180°", EXPECT_EQ(idx, 0));
}

struct HeadlandGuidanceTest : ::testing::Test {
    Frame f;
    HeadlandGuidance g;
    HeadlandSnapResult q(double e, double n, double hdg) {
        const auto p = f.at(e, n);
        return g.query(p.lat, p.lon, hdg);
    }
    void load() { g.setRings({f.rect(100, 100), f.rect(80, 80, 10, 10)}, f.at(0, 0)); }
};

TEST_F(HeadlandGuidanceTest, EmptyReturnsMinusOne) {
    EXPECT_FALSE(g.hasRings());
    EXPECT_EQ(q(0, 0, 0).ringIndex, -1);
    g.setRings({{}, {f.at(0, 0)}}, f.at(0, 0));  // pierścienie < 2 pkt pomijane
    EXPECT_FALSE(g.hasRings());
}

TEST_F(HeadlandGuidanceTest, PicksRingAndSegment) {
    load();
    EXPECT_TRUE(g.hasRings());
    auto r = q(50, 1, 90);
    EXPECT_EQ(r.ringIndex, 0);
    EXPECT_EQ(r.segmentIndex, 0);
    EXPECT_NEAR(r.crossTrackM, -1.0, 1e-3);  // CCW: wnętrze po lewej
    r = q(50, 9, 90);
    EXPECT_EQ(r.ringIndex, 1);
    EXPECT_NEAR(r.crossTrackM, 1.0, 1e-3);
}

TEST_F(HeadlandGuidanceTest, ClosingEdgeIsIncluded) {
    load();
    const auto r = q(0.5, 50, 180);  // ostatni bok (0,100)->(0,0)
    EXPECT_EQ(r.ringIndex, 0);
    EXPECT_EQ(r.segmentIndex, 3);
}

TEST_F(HeadlandGuidanceTest, HeadingErrorBothDirections) {
    load();
    EXPECT_NEAR(q(50, 0, 100).headingErrorDeg, 10.0, 1e-4);
    EXPECT_NEAR(q(50, 0, 260).headingErrorDeg, -10.0, 1e-4);
}

TEST_F(HeadlandGuidanceTest, FarAwayAndNaNFindNothing) {
    load();
    EXPECT_EQ(q(500, 500, 0).ringIndex, -1);
    EXPECT_EQ(g.query(kNaN, kNaN, 0).ringIndex, -1);
}

TEST_F(HeadlandGuidanceTest, DuplicateVerticesAreSafe) {
    Ring r = f.rect(100, 100);
    r.push_back(r.front());  // jawnie zamknięty → odcinek zerowej długości
    g.setRings({r}, f.at(0, 0));
    EXPECT_TRUE(std::isfinite(q(0, 0, 45).crossTrackM));
}

TEST_F(HeadlandGuidanceTest, OutsideCornerIsFinite) {
    load();
    const auto r = q(-3, -4, 45);
    EXPECT_EQ(r.ringIndex, 0);
    EXPECT_LE(std::abs(r.crossTrackM), 5.0 + 1e-3);
}

}  // namespace
