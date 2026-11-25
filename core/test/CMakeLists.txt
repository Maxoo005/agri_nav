include(FetchContent)
# Wersja i skrót przypięte — build jest powtarzalny.
FetchContent_Declare(googletest
    URL      https://github.com/google/googletest/releases/download/v1.15.2/googletest-1.15.2.tar.gz
    URL_HASH SHA256=7b42b4d6ed48810c5362c265a17faebe90dc2373c885e5216439d37927f02926
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
set(BUILD_GMOCK   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF)
FetchContent_MakeAvailable(googletest)
find_package(Threads REQUIRED)

add_executable(agri_nav_tests
    nav_engine_test.cpp
    swath_planner_test.cpp
    guidance_test.cpp
    section_control_test.cpp
    parcel_test.cpp
    gnss_simulator_test.cpp
    ffi_test.cpp
    integration_test.cpp
    # Most C-API wkompilowany wprost: DLL MinGW eksportuje też symbole Clipper2,
    # co daje konflikt z biblioteką statyczną.
    ${PROJECT_SOURCE_DIR}/bridge/agri_nav_ffi.cpp
    # Symulator jest odłączony od agri_nav_core, ale zachowany w repo —
    # kompilujemy go wyłącznie do testów, żeby nie zgnił.
    ${PROJECT_SOURCE_DIR}/core/src/GnssSimulator.cpp
)
target_link_libraries(agri_nav_tests PRIVATE
    agri_nav_core GTest::gtest_main Threads::Threads)
target_include_directories(agri_nav_tests PRIVATE ${PROJECT_SOURCE_DIR}/bridge)
target_compile_definitions(agri_nav_tests PRIVATE
    AGRINAV_FIXTURES="${CMAKE_CURRENT_SOURCE_DIR}/fixtures")
if(AGRINAV_COVERAGE)
    target_compile_options(agri_nav_tests PRIVATE --coverage -O0 -g)
endif()
if(AGRINAV_SANITIZE)
    target_compile_options(agri_nav_tests PRIVATE -fsanitize=address,undefined -fno-omit-frame-pointer -g)
endif()
if(WIN32)
    # DLL-ka obok exe; runtime MinGW statycznie — testy nie zależą od PATH.
    set_target_properties(agri_nav_ffi agri_nav_tests PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
    if(MINGW)
        target_link_options(agri_nav_ffi   PRIVATE -static)
        target_link_options(agri_nav_tests PRIVATE -static)
    endif()
endif()

include(GoogleTest)
gtest_discover_tests(agri_nav_tests DISCOVERY_TIMEOUT 60 PROPERTIES TIMEOUT 60)
