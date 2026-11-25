#include "GeometryProcessor.h"
#include "ParcelMerger.h"
#include "test_support.h"

#include <algorithm>

using namespace agrinav;
using namespace testutil;

namespace {

struct ParcelTest : ::testing::Test {
    Frame f;
    double outer(const MergeResult& r) const {
        double a = 0;
        for (const auto& x : r.rings)
            if (x.type == RingType::OuterPrimary || x.type == RingType::OuterSecondary)
                a += f.area(x.points);
        return a;
    }
    long count(const MergeResult& r, RingType t) const {
        return static_cast<long>(std::count_if(r.rings.begin(), r.rings.end(),
                                               [t](const MergeRing& x) { return x.type == t; }));
    }
    /// Rama 200x200 z otworem 100x100, złożona z 4 stykających się prostokątów.
    std::vector<Ring> frame() const {
        return {f.rect(200, 50), f.rect(200, 50, 0, 150),
                f.rect(50, 100, 0, 50), f.rect(50, 100, 150, 50)};
    }
};

TEST_F(ParcelTest, EmptyAndDegenerateInput) {
    EXPECT_TRUE(ParcelMerger::merge({}).rings.empty());
    const std::vector<Ring> bad = {Ring{}, Ring{f.at(0, 0)}, Ring{f.at(0, 0), f.at(1, 1)}};
    EXPECT_TRUE(ParcelMerger::merge(bad).rings.empty());
    EXPECT_TRUE(GeometryProcessor::processLpis({}).rings.empty());
    EXPECT_TRUE(GeometryProcessor::processLpis(bad).rings.empty());
}

TEST_F(ParcelTest, SingleParcelKeepsAreaWithinBuffer) {
    const auto r = ParcelMerger::merge({f.rect(100, 100)});
    ASSERT_EQ(r.rings.size(), 1u);
    EXPECT_FALSE(r.isMultipart);
    EXPECT_NEAR(outer(r), 10020.0, 3.0);  // 10000 + obwód·0.05
}

TEST_F(ParcelTest, AdjacentParcelsMerge) {
    const auto r = ParcelMerger::merge({f.rect(100, 100), f.rect(100, 100, 100, 0)});
    ASSERT_EQ(r.rings.size(), 1u);
    EXPECT_NEAR(outer(r), 20030.0, 5.0);
}

TEST_F(ParcelTest, MicroGapIsClosedButLargerIsNot) {
    auto r = ParcelMerger::merge({f.rect(100, 100), f.rect(100, 100, 100.05, 0)});
    EXPECT_FALSE(r.isMultipart);
    r = ParcelMerger::merge({f.rect(100, 100), f.rect(100, 100, 101, 0)});
    EXPECT_TRUE(r.isMultipart);
    EXPECT_EQ(count(r, RingType::OuterPrimary), 1);
    EXPECT_EQ(count(r, RingType::OuterSecondary), 1);
}

TEST_F(ParcelTest, OverlappingParcelsCountedOnce) {
    const auto r = ParcelMerger::merge({f.rect(100, 100), f.rect(100, 100, 50, 0)});
    EXPECT_NEAR(outer(r), 15000.0, 35.0);
}

TEST_F(ParcelTest, LargestPartIsPrimary) {
    const std::vector<Ring> in = {f.rect(20, 20, 500, 0), f.rect(100, 100)};
    for (const auto& r : {ParcelMerger::merge(in), GeometryProcessor::processLpis(in)}) {
        ASSERT_EQ(count(r, RingType::OuterPrimary), 1);
        for (const auto& x : r.rings) {
            if (x.type == RingType::OuterPrimary) {
                EXPECT_NEAR(f.area(x.points), 10000.0, 30.0);
            }
        }
    }
}

TEST_F(ParcelTest, HoleIsDetected) {
    for (const auto& r : {ParcelMerger::merge(frame()), GeometryProcessor::processLpis(frame())}) {
        EXPECT_FALSE(r.isMultipart);
        EXPECT_EQ(count(r, RingType::HolePrimary), 1);
        EXPECT_NEAR(outer(r), 40000.0, 50.0);
    }
}

TEST_F(ParcelTest, LpisSimplifiesNearlyCollinearVertices) {
    LpisProcessOptions opt;
    opt.bufferM = 0;
    const auto out = GeometryProcessor::processLpis(
        {f.ring({{0, 0}, {25, 0.05}, {50, 0}, {75, -0.05}, {100, 0}, {100, 100}, {0, 100}})}, opt);
    ASSERT_EQ(out.rings.size(), 1u);
    EXPECT_LE(out.rings[0].points.size(), 5u);
    EXPECT_NEAR(outer(out), 10000.0, 15.0);
}

TEST_F(ParcelTest, LpisWithoutSimplifyKeepsVertices) {
    LpisProcessOptions opt;
    opt.bufferM = 0;
    opt.simplifyEpsilonM = 0;
    const auto out = GeometryProcessor::processLpis(
        {f.ring({{0, 0}, {50, 5}, {100, 0}, {100, 100}, {0, 100}})}, opt);
    ASSERT_EQ(out.rings.size(), 1u);
    EXPECT_EQ(out.rings[0].points.size(), 5u);
}

TEST_F(ParcelTest, LpisMinRingVerticesFilters) {
    LpisProcessOptions opt;
    opt.bufferM = 0;
    opt.minRingVertices = 10;
    EXPECT_TRUE(GeometryProcessor::processLpis({f.rect(10, 10)}, opt).rings.empty());
}

TEST_F(ParcelTest, SelfIntersectingInputStaysFinite) {
    const auto r = ParcelMerger::merge({f.ring({{0, 0}, {100, 100}, {100, 0}, {0, 100}})});
    for (const auto& x : r.rings)
        for (const auto& p : x.points)
            EXPECT_TRUE(std::isfinite(p.lat) && std::isfinite(p.lon));
}

TEST_F(ParcelTest, AllClockwiseInputWorks) {
    Ring a = f.rect(100, 100), b = f.rect(100, 100, 100, 0);
    std::reverse(a.begin(), a.end());
    std::reverse(b.begin(), b.end());
    EXPECT_NEAR(outer(ParcelMerger::merge({a, b})), 20030.0, 5.0);
}

// ── Znane błędy ──────────────────────────────────────────────────────────────

TEST_F(ParcelTest, XfailMixedWindingLosesParcel) {
    Ring cw = f.rect(100, 100, 100, 0);
    std::reverse(cw.begin(), cw.end());
    const double a = outer(ParcelMerger::merge({f.rect(100, 100), cw}));
    AGRINAV_XFAIL("działki o różnym kierunku obiegu: odwrotna traktowana jak otwór",
                  EXPECT_NEAR(a, 20030.0, 30.0));
}

TEST_F(ParcelTest, XfailHoleAssignedToWrongPart) {
    auto parcels = frame();
    parcels.push_back(f.rect(20, 20, 500, -100));
    parcels.push_back(f.rect(20, 20, 500, 400));
    const auto r = ParcelMerger::merge(parcels);
    EXPECT_EQ(count(r, RingType::HolePrimary) + count(r, RingType::HoleSecondary), 1);
    AGRINAV_XFAIL("otwór przypisywany po indeksie, nie po położeniu",
                  EXPECT_EQ(count(r, RingType::HolePrimary), 1));
}

}  // namespace
