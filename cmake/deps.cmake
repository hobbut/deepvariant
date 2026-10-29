# deps.cmake — All external C++ dependencies (no TensorFlow).
#
# All major deps come from Homebrew (default) or from one prefix given as
# DV_DEPS_PREFIX (cmake cache variable or environment), e.g. a conda-forge
# environment: htslib libabseil libprotobuf re2 libboost-headers libdeflate.
# Only libssw (not in Homebrew) uses FetchContent.
#
# Homebrew versions on this machine:
#   htslib  1.18        (req: 1.18)
#   abseil  20260107.1  (req: ≥ 20240722; API-compatible)
#   protobuf 34.1       (req: 21.9; API-compatible for generated code)
#
# Pangenome deps (gbwt, gbwtgraph, sdsl-lite, libdivsufsort, libhandlegraph)
# are deferred until Phase 3 (pangenome-aware DeepVariant port).

include(FetchContent)
set(FETCHCONTENT_QUIET OFF)
set(FETCHCONTENT_UPDATES_DISCONNECTED ON)

# ---------------------------------------------------------------------------
# Dependency prefixes: one prefix for all (DV_DEPS_PREFIX, e.g. a conda
# environment with htslib, libabseil, libprotobuf, re2, libboost-headers,
# libdeflate) or, when it is unset, Homebrew's per-package prefixes.
# ---------------------------------------------------------------------------
set(DV_DEPS_PREFIX "$ENV{DV_DEPS_PREFIX}" CACHE PATH
    "single prefix holding htslib, abseil, protobuf, re2, boost and libdeflate (empty: use Homebrew)")
if(DV_DEPS_PREFIX)
  if(NOT IS_DIRECTORY "${DV_DEPS_PREFIX}")
    message(FATAL_ERROR "DV_DEPS_PREFIX is not a directory: ${DV_DEPS_PREFIX}")
  endif()
  message(STATUS "deps prefix: ${DV_DEPS_PREFIX}")
else()
  find_program(BREW_EXECUTABLE brew REQUIRED)
endif()

# dv_dep_prefix(<out-var> <homebrew-formula>): DV_DEPS_PREFIX or `brew --prefix <formula>`.
function(dv_dep_prefix out_var formula)
  if(DV_DEPS_PREFIX)
    set(${out_var} "${DV_DEPS_PREFIX}" PARENT_SCOPE)
    return()
  endif()
  execute_process(
    COMMAND ${BREW_EXECUTABLE} --prefix ${formula}
    OUTPUT_VARIABLE prefix
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  if(NOT prefix)
    message(FATAL_ERROR "${formula} not found — run: brew install ${formula} (or set DV_DEPS_PREFIX)")
  endif()
  set(${out_var} "${prefix}" PARENT_SCOPE)
endfunction()

# ---------------------------------------------------------------------------
# htslib 1.18 — Homebrew (avoids autoconf complexity on macOS)
# ---------------------------------------------------------------------------
dv_dep_prefix(HTSLIB_PREFIX htslib)

add_library(htslib::htslib STATIC IMPORTED)
find_library(HTSLIB_LIB NAMES libhts.a hts PATHS "${HTSLIB_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
dv_dep_prefix(DEFLATE_PREFIX libdeflate)
find_library(DEFLATE_LIB NAMES libdeflate.a deflate PATHS "${DEFLATE_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
set_target_properties(htslib::htslib PROPERTIES
  IMPORTED_LOCATION "${HTSLIB_LIB}"
  INTERFACE_INCLUDE_DIRECTORIES "${HTSLIB_PREFIX}/include"
)
target_link_libraries(htslib::htslib INTERFACE
  "-framework CoreFoundation"
  "${DEFLATE_LIB}"
  z bz2 lzma curl
)
message(STATUS "htslib: ${HTSLIB_LIB}")

# ---------------------------------------------------------------------------
# abseil — Homebrew (no FetchContent; avoids hash management)
# ---------------------------------------------------------------------------
dv_dep_prefix(ABSL_PREFIX abseil)
list(APPEND CMAKE_PREFIX_PATH "${ABSL_PREFIX}")
find_package(absl REQUIRED)
message(STATUS "abseil: ${ABSL_PREFIX}")

# ---------------------------------------------------------------------------
# protobuf — Homebrew (no FetchContent; avoids hash management)
# ---------------------------------------------------------------------------
dv_dep_prefix(PROTOBUF_PREFIX protobuf)
list(APPEND CMAKE_PREFIX_PATH "${PROTOBUF_PREFIX}")
find_package(protobuf REQUIRED)
message(STATUS "protobuf: ${PROTOBUF_PREFIX}")

# Homebrew's protoc.
find_program(PROTOC protoc HINTS "${PROTOBUF_PREFIX}/bin" REQUIRED)
message(STATUS "protoc: ${PROTOC}")

# ---------------------------------------------------------------------------
# libssw 1.2.5 — Smith-Waterman aligner (realigner/)
# ---------------------------------------------------------------------------
FetchContent_Declare(
  libssw
  URL      https://github.com/mengyao/Complete-Striped-Smith-Waterman-Library/archive/v1.2.5.tar.gz
  URL_HASH SHA256=b294c0cb6f0f3d578db11b4112a88b20583b9d4190b0a9cf04d83bb6a8704d9a
)
FetchContent_GetProperties(libssw)
if(NOT libssw_POPULATED)
  FetchContent_Populate(libssw)
endif()

# OVERLAY: replace the vendored sse2neon.h (Ratcliff/NVIDIA early version,
# 8798 lines, missing fixes) with the modern DLTcollab fork (11744 lines,
# improved fidelity for edge cases like _mm_slli_si128 byte-shifts).
# This reduces realigner SSW score drift between native arm64 (compile-time
# SSE→NEON) and Docker on Rosetta (runtime SSE→ARM translation), which
# was the source of 105/120 PASS-flips on chr20:26-31Mb pericentromere.
# See PORT_LOG 2026-05-07 "PASS-flip root-cause analysis".
if(EXISTS "${CMAKE_SOURCE_DIR}/release/vendored/sse2neon.h")
  configure_file(
    "${CMAKE_SOURCE_DIR}/release/vendored/sse2neon.h"
    "${libssw_SOURCE_DIR}/src/sse2neon.h"
    COPYONLY)
  message(STATUS "libssw: overlaid modern sse2neon.h from release/vendored/")
endif()

# libssw has no CMakeLists — define targets here.
add_library(ssw STATIC
  "${libssw_SOURCE_DIR}/src/ssw.c"
  "${libssw_SOURCE_DIR}/src/ssw.h"
  "${libssw_SOURCE_DIR}/src/ssw_cpp.cpp"
  "${libssw_SOURCE_DIR}/src/ssw_cpp.h"
)
# deepvariant/realigner/ssw.h uses #include "src/ssw_cpp.h",
# so the PARENT of src/ must be on the include path, not just src/.
target_include_directories(ssw PUBLIC "${libssw_SOURCE_DIR}")
# Apple Clang/arm64: SSW uses SSE2 intrinsics guarded by __SSE2__ —
# arm64 does not have SSE2; the fallback scalar path is used automatically.
set(DV_LIBSSW_DIR "${libssw_SOURCE_DIR}" CACHE INTERNAL "libssw source root")

# ---------------------------------------------------------------------------
# re2 — Homebrew
# ---------------------------------------------------------------------------
dv_dep_prefix(RE2_PREFIX re2)
add_library(re2::re2 STATIC IMPORTED)
find_library(RE2_LIB NAMES libre2.a re2 PATHS "${RE2_PREFIX}/lib" NO_DEFAULT_PATH REQUIRED)
set_target_properties(re2::re2 PROPERTIES
  IMPORTED_LOCATION "${RE2_LIB}"
  INTERFACE_INCLUDE_DIRECTORIES "${RE2_PREFIX}/include"
)
message(STATUS "re2: ${RE2_LIB}")

# ---------------------------------------------------------------------------
# Boost — Homebrew (for debruijn_graph.h in realigner/)
# ---------------------------------------------------------------------------
dv_dep_prefix(BOOST_PREFIX boost)
message(STATUS "boost: ${BOOST_PREFIX}")
set(BOOST_INCLUDE_DIR "${BOOST_PREFIX}/include" CACHE INTERNAL "")

# ---------------------------------------------------------------------------
# GoogleTest — FetchContent (no standalone Homebrew package)
# ---------------------------------------------------------------------------
FetchContent_Declare(
  googletest
  URL      https://github.com/google/googletest/archive/refs/tags/v1.14.0.tar.gz
  URL_HASH SHA256=8ad598c73ad796e0d8280b082cebd82a630d73e73cd3c70057938a6501bba5d7
)
set(INSTALL_GTEST OFF)
FetchContent_MakeAvailable(googletest)
set(GTEST_PREFIX "${googletest_SOURCE_DIR}" CACHE INTERNAL "")

# ---------------------------------------------------------------------------
# zlib — guaranteed present on macOS (from Xcode SDK)
# ---------------------------------------------------------------------------
find_package(ZLIB REQUIRED)
