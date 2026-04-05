cmake_minimum_required(VERSION 3.5)

PROJECT(vsd)

find_package (Threads)

set(SOURCES main.cc app.cc config.cc tcpsvr.cc file_search.cc util.cpp)

set(CMAKE_CURRENT_BINARY_DIR  ./build)
set(OUTPUT ${CMAKE_PROJECT_NAME})

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

set(CMAKE_CXX_FLAGS "-Wall -Wextra")
set(CMAKE_CXX_FLAGS_DEBUG "-g")
set(CMAKE_CXX_FLAGS_RELEASE "-Os")

ADD_EXECUTABLE(${OUTPUT} ${SOURCES})
target_link_directories(${OUTPUT} PRIVATE ${CMAKE_CURRENT_LIST})
target_link_libraries (${OUTPUT} ${CMAKE_THREAD_LIBS_INIT} yaml jsoncpp piencrypt)

