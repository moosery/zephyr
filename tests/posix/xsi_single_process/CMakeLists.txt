# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(xsi_single_process)

FILE(GLOB app_sources src/*.c)

target_sources(app PRIVATE ${app_sources})

target_compile_options(app PRIVATE -U_POSIX_C_SOURCE -D_POSIX_C_SOURCE=200809L)
target_compile_options(app PRIVATE -U_XOPEN_SOURCE -D_XOPEN_SOURCE=700)
target_include_directories(app PRIVATE ${ZEPHYR_BASE}/lib/posix/options)
