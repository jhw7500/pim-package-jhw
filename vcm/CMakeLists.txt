cmake_minimum_required(VERSION 3.0)
project(vcm)
set(SOURCE main.cpp ipc.cpp tcpServer.cpp util.cpp)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")

# Match the Makefile dependencies using the selected SDK sysroot.
find_package(PkgConfig REQUIRED)
pkg_check_modules(JSON_C REQUIRED json-c)
pkg_check_modules(HIREDIS REQUIRED hiredis)
include_directories(${JSON_C_INCLUDE_DIRS} ${HIREDIS_INCLUDE_DIRS})

add_executable(${PROJECT_NAME} ${SOURCE})
target_link_libraries(${PROJECT_NAME} -l:libjson-c.a -l:libhiredis.a pthread)
