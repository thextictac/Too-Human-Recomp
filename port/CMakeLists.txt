# toohuman - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(toohuman LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(generated/rexglue.cmake)

# Sources
set(TOOHUMAN_SOURCES
    src/main.cpp
)

if(WIN32)
    add_executable(toohuman WIN32 ${TOOHUMAN_SOURCES})
else()
    add_executable(toohuman ${TOOHUMAN_SOURCES})
endif()

rexglue_setup_target(toohuman)
