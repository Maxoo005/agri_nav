cmake_minimum_required(VERSION 3.21)
project(agri_nav_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Clipper2 1.4.0 — vendored sources (no FetchContent / no network) ──────────
add_library(Clipper2 STATIC
    third_party/clipper2/src/clipper.engine.cpp
    third_party/clipper2/src/clipper.offset.cpp
    third_party/clipper2/src/clipper.rectclip.cpp
)
target_include_directories(Clipper2 PUBLIC third_party/clipper2/include)
target_compile_features(Clipper2 PUBLIC cxx_std_17)
add_library(Clipper2::Clipper2 ALIAS Clipper2)

# ── Rdzeń nawigacyjny (statyczna biblioteka) ──────────────────────────────────
add_library(agri_nav_core STATIC
    core/src/NavEngine.cpp
    core/src/GnssProcessor.cpp
    core/src/GnssSimulator.cpp
    core/src/SwathPlanner.cpp
    core/src/SwathGuidance.cpp
    core/src/SectionControl.cpp
    core/src/ParcelMerger.cpp
    core/src/GeometryProcessor.cpp
)
target_include_directories(agri_nav_core PUBLIC core/include)
target_link_libraries(agri_nav_core PUBLIC Clipper2::Clipper2)

# ── Biblioteka współdzielona eksponowana przez FFI do Fluttera ─────────────────
add_library(agri_nav_ffi SHARED
    bridge/agri_nav_ffi.cpp
)
target_link_libraries(agri_nav_ffi PRIVATE agri_nav_core)
target_include_directories(agri_nav_ffi
    PRIVATE
        bridge
        core/include
)
