cmake_minimum_required(VERSION 3.16)
project(Grosznik CXX)
set(CMAKE_CXX_STANDARD 17)

# ── Paths to sibling projects ─────────────────────────────────────────────────
set(HTTPD_DIR    "${CMAKE_SOURCE_DIR}/../HTTPD"   CACHE PATH "HTTPD root")
set(TELEBOT_DIR  "${CMAKE_SOURCE_DIR}/../Telebot" CACHE PATH "Telebot root")

# ── Find system libraries ─────────────────────────────────────────────────────
find_package(OpenSSL REQUIRED)
find_library(SQLITE3_LIB  NAMES sqlite3  REQUIRED)
find_library(LUA54_LIB    NAMES lua5.4 lua54 lua REQUIRED)
find_path(LUA54_INC       NAMES lua.h PATH_SUFFIXES lua5.4 lua54 lua REQUIRED)

# ── Grosznik Lua C module (.so) ───────────────────────────────────────────────
add_library(grosznik_lua MODULE modules/grosznik/grosznik_module.cpp)
set_target_properties(grosznik_lua PROPERTIES
    OUTPUT_NAME  grosznik
    PREFIX       ""
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/modules"
)
target_include_directories(grosznik_lua PRIVATE ${LUA54_INC})
target_link_libraries(grosznik_lua PRIVATE
    ${SQLITE3_LIB}
    OpenSSL::Crypto
)

# ── Main binary ───────────────────────────────────────────────────────────────
add_executable(grosznik
    src/main.cpp
    src/Schema.cpp
    src/BotHandler.cpp
    src/Notifier.cpp
)
target_include_directories(grosznik PRIVATE
    include
    ${HTTPD_DIR}/include
    ${TELEBOT_DIR}/include
    ${TELEBOT_DIR}/build/_hugon
)
target_link_libraries(grosznik PRIVATE
    ${HTTPD_DIR}/build/libhttpd_core.a
    ${TELEBOT_DIR}/build/libtelebot.a
    ${TELEBOT_DIR}/build/_hugon/libhugon.a
    ${SQLITE3_LIB}
    OpenSSL::Crypto
    OpenSSL::SSL
    pthread curl
)
