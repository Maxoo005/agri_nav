#include "SectionControl.h"
#include "test_support.h"

using namespace agrinav;
using namespace testutil;

namespace {

struct SectionControlTest : ::testing::Test {
    Frame f;
    SectionControl s;
    void SetUp() override { s.setOrigin(f.lat0, f.lon0); }
    float add(double e, double n, double hdg, double w) {
        const auto p = f.at(e, n);
        return s.addStrip(p.lat, p.lon, hdg, w);
    }
    float check(double e, double n, double hdg, double w) {
        const auto p = f.at(e, n);
        return s.checkOverlap(p.lat, p.lon, hdg, w);
    }
};

TEST(SectionControlNoOrigin, IsNoOp) {
    SectionControl s;
    EXPECT_FALSE(s.hasOrigin());
    EXPECT_FLOAT_EQ(s.addStrip(52, 17, 0, 10), 0.f);
    EXPECT_FLOAT_EQ(s.checkOverlap(52, 17, 0, 10), 0.f);
    EXPECT_NEAR(s.coveredAreaHa(), 0.0, 1e-12);
}

TEST_F(SectionControlTest, FirstStripIsNewSecondIsFullOverlap) {
    EXPECT_FLOAT_EQ(add(50.3, 50.5, 0, 10), 0.f);
    EXPECT_EQ(s.newCellsLastStrip(), 11);  // 10 m ↦ 11 dotkniętych komórek
    EXPECT_NEAR(s.newAreaHaLastStrip(), 11e-4, 1e-12);
    EXPECT_FLOAT_EQ(add(50.3, 50.5, 0, 10), 1.f);
    EXPECT_EQ(s.newCellsLastStrip(), 0);
    EXPECT_NEAR(s.coveredAreaHa(), 11e-4, 1e-12);
}

TEST_F(SectionControlTest, CheckOverlapIsReadOnly) {
    EXPECT_FLOAT_EQ(check(0.5, 0.5, 0, 6), 0.f);
    EXPECT_NEAR(s.coveredAreaHa(), 0.0, 1e-12);
}

TEST_F(SectionControlTest, HalfOverlapReportsAboutHalf) {
    add(50.3, 50.5, 0, 20);
    EXPECT_NEAR(check(60.3, 50.5, 0, 20), 0.5, 0.06);
}

TEST_F(SectionControlTest, DisjointPassesDoNotOverlap) {
    add(10.5, 10.5, 0, 6);
    EXPECT_FLOAT_EQ(check(100.5, 10.5, 0, 6), 0.f);
    EXPECT_FLOAT_EQ(check(10.5, 20.5, 0, 6), 0.f);
}

TEST_F(SectionControlTest, FootprintIsPerpendicularToHeading) {
    add(0.5, 0.5, 90, 9);  // jazda na wschód → narzędzie N-S
    EXPECT_FLOAT_EQ(check(0.5, 4.5, 90, 1e-6), 1.f);
    EXPECT_FLOAT_EQ(check(4.5, 0.5, 90, 1e-6), 0.f);
}

TEST_F(SectionControlTest, NegativeCoordinatesWork) {
    add(-100.5, -200.5, 0, 4);
    EXPECT_FLOAT_EQ(check(-100.5, -200.5, 0, 4), 1.f);
    EXPECT_FLOAT_EQ(check(100.5, 200.5, 0, 4), 0.f);
}

TEST_F(SectionControlTest, ClearKeepsOrigin) {
    add(0, 0, 0, 10);
    s.clear();
    EXPECT_NEAR(s.coveredAreaHa(), 0.0, 1e-12);
    EXPECT_EQ(s.newCellsLastStrip(), 0);
    EXPECT_TRUE(s.hasOrigin());
}

TEST(SectionControlCell, InvalidCellSizeFallsBackToOneMetre) {
    for (double bad : {0.0, -1.0, kNaN}) {
        SectionControl s(bad);
        s.setOrigin(52, 17);
        s.addStrip(52.00001, 17.00001, 0, 1e-6);
        EXPECT_NEAR(s.coveredAreaHa(), 1e-4, 1e-12);
    }
}

TEST(SectionControlCell, FinerGridConvergesToTrueArea) {
    const Frame f;
    SectionControl s(0.1);
    s.setOrigin(f.lat0, f.lon0);
    for (int i = 0; i < 1000; ++i) {
        const auto p = f.at(50.03, 0.05 + i * 0.1);
        s.addStrip(p.lat, p.lon, 0, 3.0);
    }
    EXPECT_NEAR(s.coveredAreaHa(), 0.03, 0.03 * 0.05);  // 100 m × 3 m
}

TEST_F(SectionControlTest, InvalidInputMarksNothingAndDoesNotThrow) {
    const double inf = INFINITY;
    add(0.5, 0.5, 0, 4);
    const double before = s.coveredAreaHa();
    for (double w : {0.0, -10.0, -1e-9, kNaN, inf, -inf}) {
        EXPECT_NO_THROW({
            EXPECT_FLOAT_EQ(add(50, 50, 0, w), 0.f);
            EXPECT_FLOAT_EQ(check(0.5, 0.5, 0, w), 0.f);
        }) << w;
        EXPECT_EQ(s.newCellsLastStrip(), 0);
    }
    for (double bad : {kNaN, inf}) {
        EXPECT_FLOAT_EQ(add(bad, 50, 0, 4), 0.f);
        EXPECT_FLOAT_EQ(add(50, 50, bad, 4), 0.f);
    }
    EXPECT_NEAR(s.coveredAreaHa(), before, 1e-12);
}

// ── Znane błędy ──────────────────────────────────────────────────────────────

TEST_F(SectionControlTest, XfailNarrowToolAreaOverestimated) {
    // 100 m × 3 m = 0.03 ha, kratka produkcyjna 1 m: zaznaczane są wszystkie
    // dotknięte komórki (4 zamiast 3) → +33 %.
    for (int i = 0; i < 100; ++i) add(50.3, i + 0.5, 0, 3.0);
    AGRINAV_XFAIL("pojedynczy przejazd zawyża powierzchnię o ok. 1 kolumnę komórek",
                  EXPECT_NEAR(s.coveredAreaHa(), 0.03, 0.003));
}

}  // namespace
