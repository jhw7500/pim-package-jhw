cmake_minimum_required(VERSION 3.5)

PROJECT(mcp_trust_test)

find_package (Threads)

set(SOURCES mcp_trust_test.cc udrv_mcp.cc my_i2c.cc)

set(CMAKE_CURRENT_BINARY_DIR  ./build)
set(OUTPUT ${CMAKE_PROJECT_NAME})

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS "-Wall -Wextra -lstdc++fs")
set(CMAKE_CXX_FLAGS_DEBUG "-g")
set(CMAKE_CXX_FLAGS_RELEASE "-Os")

ADD_EXECUTABLE(${OUTPUT} ${SOURCES})
target_link_libraries (${OUTPUT} ${CMAKE_THREAD_LIBS_INIT})