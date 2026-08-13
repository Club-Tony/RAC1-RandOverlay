# RandOverlay implicit Vulkan layer — cross-platform build.
#
# Builds the same sources on Windows (RandOverlay_layer.dll) and Linux
# (libVkLayer_RandOverlay.so). The injected-DLL fallback (overlay.cpp,
# injector.cpp, MinHook) is deliberately NOT built here: it is Windows-only by
# construction and is superseded by the layer. Use build.bat for that path.
#
#   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j
#
cmake_minimum_required(VERSION 3.16)
project(RandOverlay VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

option(RANDOVERLAY_BUILD_TESTS "Build the headless unit tests" ON)
option(RANDOVERLAY_FETCH_DEPS  "Download Dear ImGui when deps/imgui is absent" ON)

# ── Dear ImGui ────────────────────────────────────────────────────────────────
# Pinned to the same commit the release workflow uses, so a local Linux build
# and CI produce identical rendering.
set(RANDOVERLAY_IMGUI_TAG "8314fc3e5a10f7c6b670225065fce1dc8cfd396b")
set(IMGUI_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps/imgui")

if(NOT EXISTS "${IMGUI_DIR}/imgui.cpp")
    if(RANDOVERLAY_FETCH_DEPS)
        include(FetchContent)
        FetchContent_Declare(imgui
            GIT_REPOSITORY https://github.com/ocornut/imgui.git
            GIT_TAG        ${RANDOVERLAY_IMGUI_TAG}
            GIT_SHALLOW    FALSE)
        FetchContent_MakeAvailable(imgui)
        set(IMGUI_DIR "${imgui_SOURCE_DIR}")
    else()
        message(FATAL_ERROR
            "Dear ImGui not found at ${IMGUI_DIR}.\n"
            "Either clone it:\n"
            "  git clone https://github.com/ocornut/imgui.git deps/imgui\n"
            "  git -C deps/imgui checkout ${RANDOVERLAY_IMGUI_TAG}\n"
            "or re-run with -DRANDOVERLAY_FETCH_DEPS=ON")
    endif()
endif()

set(IMGUI_SOURCES
    "${IMGUI_DIR}/imgui.cpp"
    "${IMGUI_DIR}/imgui_draw.cpp"
    "${IMGUI_DIR}/imgui_tables.cpp"
    "${IMGUI_DIR}/imgui_widgets.cpp"
    "${IMGUI_DIR}/backends/imgui_impl_vulkan.cpp")

# ── Vulkan headers ────────────────────────────────────────────────────────────
# Headers only — the layer resolves every entry point through the dispatch
# chain (VK_NO_PROTOTYPES), so there is nothing to link against.
find_path(VULKAN_INCLUDE_DIR
    NAMES vulkan/vulkan.h
    HINTS "$ENV{VULKAN_SDK}/Include" "$ENV{VULKAN_SDK}/include"
    PATHS /usr/include /usr/local/include)
if(NOT VULKAN_INCLUDE_DIR)
    message(FATAL_ERROR
        "Vulkan headers not found. Install libvulkan-dev (Linux) or set "
        "VULKAN_SDK (Windows).")
endif()

find_path(VULKAN_LAYER_HEADER_DIR
    NAMES vulkan/vk_layer.h
    HINTS "${VULKAN_INCLUDE_DIR}")
if(NOT VULKAN_LAYER_HEADER_DIR)
    message(FATAL_ERROR "vulkan/vk_layer.h not found alongside vulkan.h.")
endif()

# ── fontconfig (Linux font resolution) ────────────────────────────────────────
set(RANDOVERLAY_FONTCONFIG_LIBS "")
if(NOT WIN32)
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
        pkg_check_modules(FONTCONFIG QUIET fontconfig)
    endif()
    if(FONTCONFIG_FOUND)
        set(RANDOVERLAY_FONTCONFIG_LIBS ${FONTCONFIG_LIBRARIES})
        message(STATUS "fontconfig ${FONTCONFIG_VERSION} — family lookup enabled")
    else()
        # Not fatal: font_resolver.h falls back to scanning the standard font
        # directories, which covers the common layouts.
        message(WARNING
            "fontconfig not found — falling back to a font-directory scan. "
            "Install libfontconfig1-dev for proper family resolution.")
    endif()
endif()

# ── The layer ─────────────────────────────────────────────────────────────────
add_library(RandOverlayLayer SHARED src/layer.cpp ${IMGUI_SOURCES})

target_include_directories(RandOverlayLayer PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/src"
    "${IMGUI_DIR}"
    "${IMGUI_DIR}/backends"
    "${VULKAN_INCLUDE_DIR}")

target_compile_definitions(RandOverlayLayer PRIVATE
    VK_NO_PROTOTYPES
    IMGUI_IMPL_VULKAN_NO_PROTOTYPES)

if(WIN32)
    # Match build.bat's artifact name so the existing RandOverlay_layer.json
    # manifest and installer keep working.
    set_target_properties(RandOverlayLayer PROPERTIES
        PREFIX "" OUTPUT_NAME "RandOverlay_layer")
    target_compile_definitions(RandOverlayLayer PRIVATE WIN32_LEAN_AND_MEAN)
    target_link_libraries(RandOverlayLayer PRIVATE kernel32 user32 shell32 advapi32)
    if(MINGW)
        target_link_options(RandOverlayLayer PRIVATE
            -static -static-libgcc -static-libstdc++ -Wl,--kill-at)
    endif()
else()
    # Khronos naming convention for layer libraries.
    set_target_properties(RandOverlayLayer PROPERTIES
        OUTPUT_NAME "VkLayer_RandOverlay"
        CXX_VISIBILITY_PRESET hidden
        VISIBILITY_INLINES_HIDDEN ON)
    # glibc only declares dladdr() under _GNU_SOURCE. g++ normally defines it
    # already, but -std=c++17 (extensions off) makes that worth not assuming.
    target_compile_definitions(RandOverlayLayer PRIVATE _GNU_SOURCE)
    # An implicit layer is loaded into every Vulkan process on the system.
    # Hiding everything but the three negotiated entry points keeps our symbols
    # from colliding with the host's.
    target_link_options(RandOverlayLayer PRIVATE
        -Wl,--exclude-libs,ALL -Wl,--no-undefined)
    target_link_libraries(RandOverlayLayer PRIVATE dl pthread)
    if(FONTCONFIG_FOUND)
        target_compile_definitions(RandOverlayLayer PRIVATE RANDOVERLAY_HAVE_FONTCONFIG)
        target_include_directories(RandOverlayLayer PRIVATE ${FONTCONFIG_INCLUDE_DIRS})
        target_link_libraries(RandOverlayLayer PRIVATE ${RANDOVERLAY_FONTCONFIG_LIBS})
    endif()
endif()

# ── Headless unit tests ───────────────────────────────────────────────────────
if(RANDOVERLAY_BUILD_TESTS)
    enable_testing()
    add_executable(randoverlay_tests tests/test_units.cpp)
    target_include_directories(randoverlay_tests PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/src" "${VULKAN_INCLUDE_DIR}")
    if(NOT WIN32)
        target_compile_definitions(randoverlay_tests PRIVATE _GNU_SOURCE)
        target_link_libraries(randoverlay_tests PRIVATE dl pthread)
        if(FONTCONFIG_FOUND)
            target_compile_definitions(randoverlay_tests PRIVATE RANDOVERLAY_HAVE_FONTCONFIG)
            target_include_directories(randoverlay_tests PRIVATE ${FONTCONFIG_INCLUDE_DIRS})
            target_link_libraries(randoverlay_tests PRIVATE ${RANDOVERLAY_FONTCONFIG_LIBS})
        endif()
    endif()
    # Pass the shared ini explicitly. The test can also find it by walking up
    # from its own directory, but that assumes a build dir exactly one level
    # below the project, which is not true for e.g. -B build/linux.
    add_test(NAME units
             COMMAND randoverlay_tests "${CMAKE_CURRENT_SOURCE_DIR}/../RandOverlay.ini")
endif()

# ── Layer manifest ────────────────────────────────────────────────────────────
# Generated rather than committed so library_path always matches the artifact
# this build actually produced.
if(WIN32)
    set(RANDOVERLAY_LIBRARY_NAME "RandOverlay_layer.dll")
else()
    set(RANDOVERLAY_LIBRARY_NAME "libVkLayer_RandOverlay.so")
endif()
# Absolute, so the generated manifest works from wherever the loader reads it.
# install_layer.sh regenerates this for the installed location.
set(RANDOVERLAY_LIBRARY_PATH "${CMAKE_CURRENT_BINARY_DIR}/${RANDOVERLAY_LIBRARY_NAME}")
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/RandOverlay_layer.json.in"
    "${CMAKE_CURRENT_BINARY_DIR}/RandOverlay_layer.json"
    @ONLY)

message(STATUS "RandOverlay layer  -> ${RANDOVERLAY_LIBRARY_NAME}")
message(STATUS "Vulkan headers     -> ${VULKAN_INCLUDE_DIR}")
