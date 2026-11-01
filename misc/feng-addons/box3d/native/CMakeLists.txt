cmake_minimum_required(VERSION 3.22)
project(feng-box3d LANGUAGES C CXX)

# Reuse the repository's SDK; do not download another copy of godot-cpp.
set(FENG_GODOT_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../../feng-idweight-terrain/native/godot-cpp"
    CACHE PATH "Path to godot-cpp 4.5")
if(NOT EXISTS "${FENG_GODOT_CPP}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp is missing. Set -DFENG_GODOT_CPP=/path/to/godot-cpp")
endif()
set(GODOTCPP_TARGET template_release CACHE STRING "" FORCE)
set(GODOTCPP_PRECISION single CACHE STRING "" FORCE)
set(GODOTCPP_BUILD_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/build_profile.json" CACHE FILEPATH "" FORCE)
set(GODOTCPP_USE_HOT_RELOAD OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>" CACHE STRING "" FORCE)
add_subdirectory("${FENG_GODOT_CPP}" "${CMAKE_CURRENT_BINARY_DIR}/godot-cpp")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BOX3D_DOUBLE_PRECISION OFF CACHE BOOL "" FORCE)
set(BOX3D_PROFILE OFF CACHE BOOL "" FORCE)
add_subdirectory(thirdparty/box3d)

file(GLOB_RECURSE ADAPTER_SOURCES CONFIGURE_DEPENDS "thirdparty/godot-box3d/src/*.cpp")
add_library(feng-box3d SHARED ${ADAPTER_SOURCES})
target_include_directories(feng-box3d PRIVATE thirdparty/godot-box3d/src)
target_precompile_headers(feng-box3d PRIVATE thirdparty/godot-box3d/src/precompiled.hpp)
target_link_libraries(feng-box3d PRIVATE box3d::box3d godot-cpp)
target_compile_features(feng-box3d PRIVATE cxx_std_17)
if(MSVC)
    target_compile_options(feng-box3d PRIVATE /utf-8)
endif()
if(MINGW)
    target_link_options(feng-box3d PRIVATE -static-libgcc -static-libstdc++ -static)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(feng-box3d PRIVATE -Wl,--exclude-libs,ALL)
endif()
set_target_properties(feng-box3d PROPERTIES
    PREFIX ""
    OUTPUT_NAME "box3d"
    CXX_VISIBILITY_PRESET hidden
    VISIBILITY_INLINES_HIDDEN ON
    RUNTIME_OUTPUT_DIRECTORY "$<1:${CMAKE_CURRENT_SOURCE_DIR}/../bin>"
    LIBRARY_OUTPUT_DIRECTORY "$<1:${CMAKE_CURRENT_SOURCE_DIR}/../bin>"
)
