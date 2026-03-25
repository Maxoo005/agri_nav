cmake_minimum_required(VERSION 3.21)
project(agri_nav_core VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Rdzeń nawigacyjny (statyczna biblioteka) ──────────────────────────────────
add_library(agri_nav_core STATIC
    core/src/NavEngine.cpp
    core/src/GnssProcessor.cpp
    core/src/GnssSimulator.cpp
    core/src/SwathPlanner.cpp
    core/src/SwathGuidance.cpp
    core/src/SectionControl.cpp
)
target_include_directories(agri_nav_core PUBLIC core/include)

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
