cmake_minimum_required(VERSION 3.20)
project(NotifListenerShim CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CRT は Crystal 本体に合わせて動的 CRT (/MD) で統一する。
# Crystal の Windows 向けリンク行が msvcrt.lib と ucrt.lib と vcruntime.lib を渡すため、
# ここを静的 CRT にすると defaultlib が混在してリンクが通らない。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL")

add_library(NotifListenerShim STATIC src/notif_listener_shim.cpp)
target_include_directories(NotifListenerShim PUBLIC include)
target_compile_options(NotifListenerShim PRIVATE /EHsc /W4 /utf-8)
target_link_libraries(NotifListenerShim PUBLIC windowsapp runtimeobject ole32)

# 配布物ではない。シムの C API を叩いて挙動を確かめるためだけの実行ファイルである。
add_executable(shim_harness test/harness.cpp)
target_link_libraries(shim_harness PRIVATE NotifListenerShim)
target_compile_options(shim_harness PRIVATE /EHsc /utf-8)
