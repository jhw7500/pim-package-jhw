cmake_minimum_required(VERSION 3.0)
project(ord)
set(SOURCE main.cpp tcpServer.cpp util.cpp)
SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")

# Remove hardcoded host paths - let CMake find libs in SDK sysroot
# include_directories(/usr/include/json-c)
# include_directories(/usr/include/hiredis)

# Use pkg-config to find libraries in SDK sysroot
find_package(PkgConfig REQUIRED)
pkg_check_modules(JSON_C REQUIRED json-c)
pkg_check_modules(HIREDIS REQUIRED hiredis)

include_directories(${JSON_C_INCLUDE_DIRS} ${HIREDIS_INCLUDE_DIRS})

add_executable(${PROJECT_NAME} ${SOURCE})

# Static linking for json-c and hiredis to avoid runtime dependency
target_link_libraries(${PROJECT_NAME} -l:libjson-c.a -l:libhiredis.a pthread)
