# CMake script for building cpdn_credit executable
#
#   Developed by GPT-5.4, prompted & edited by Glenn Carver

cmake_minimum_required(VERSION 3.16)

project(cpdn_credit LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
include(CTest)

set(BOINC_SRC "$ENV{BOINC_SRC}" CACHE PATH "Path to BOINC source directory, contains headers not copied to install dir")

set(BOINC_SCHED_STATIC "${BOINC_SRC}/sched/libsched.a" CACHE FILEPATH "Path to BOINC static scheduler library")
set(BOINC_CRYPT_STATIC "${BOINC_SRC}/lib/libboinc_crypt.a" CACHE FILEPATH "Path to BOINC static crypto helper library")
set(BOINC_CORE_STATIC "${BOINC_SRC}/lib/libboinc.a" CACHE FILEPATH "Path to BOINC static core library")

set(MYSQL_INCLUDE_DIR "/usr/include/mysql" CACHE PATH "Path to MySQL headers")
set(MYSQL_LIBRARY_DIR "/usr/lib64" CACHE PATH "Path to MySQL/OpenSSL/system libraries")
set(MYSQL_EXTRA_LIBRARY_DIR "/usr/lib64/mysql" CACHE PATH "Optional extra MySQL library directory")

option(ENABLE_CPDN_TEST "Enable DB-backed CTest end-to-end example test" OFF)

if(NOT BOINC_SRC)
    message(FATAL_ERROR "Please set source location of BOINC: BOINC_SRC, e.g. -DBOINC_SRC=\$HOME/github/boinc")
endif()


if(NOT EXISTS "${BOINC_SRC}/config.h")
    message(FATAL_ERROR "Cannot find config.h under BOINC_SRC")
endif()

if(NOT EXISTS "${BOINC_SCHED_STATIC}")
    message(FATAL_ERROR "Cannot find BOINC static library: ${BOINC_SCHED_STATIC}")
endif()

if(NOT EXISTS "${BOINC_CRYPT_STATIC}")
    message(FATAL_ERROR "Cannot find BOINC static library: ${BOINC_CRYPT_STATIC}")
endif()

if(NOT EXISTS "${BOINC_CORE_STATIC}")
    message(FATAL_ERROR "Cannot find BOINC static library: ${BOINC_CORE_STATIC}")
endif()

add_executable(cpdn_credit
    cpdn_trickle_handler.cpp
    cpdn_credit.cpp
    cpdn_db.cpp
)

# Unfortunately as we include headers directly from the source, we have to specify
# all boinc src dirs so that child headers as also found. These child headers
# are not copied to the install directory, so we have to refer to the boinc src.
target_include_directories(cpdn_credit PRIVATE
    ${BOINC_SRC}
    ${BOINC_SRC}/lib
    ${BOINC_SRC}/db
    ${BOINC_SRC}/sched
    ${MYSQL_INCLUDE_DIR}
)

target_link_directories(cpdn_credit PRIVATE
    ${MYSQL_LIBRARY_DIR}
    ${MYSQL_EXTRA_LIBRARY_DIR}
)

target_link_libraries(cpdn_credit PRIVATE
    ${BOINC_SCHED_STATIC}
    ${BOINC_CRYPT_STATIC}
    ${BOINC_CORE_STATIC}
    mysqlclient
    pthread
    z
    m
    rt
    ssl
    crypto
    dl
)

if(BUILD_TESTING AND ENABLE_CPDN_TEST)
    add_test(
        NAME credit_varieties
        COMMAND "${CMAKE_SOURCE_DIR}/test/run_test.sh" "$<TARGET_FILE:cpdn_credit>"
    )
    set_tests_properties(credit_varieties PROPERTIES
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        TIMEOUT 300
    )
endif()
