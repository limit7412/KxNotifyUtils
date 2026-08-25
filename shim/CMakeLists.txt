cmake_minimum_required(VERSION 3.20)
project(NotifListenerShim CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# CRT は libui-ng に合わせて静的 CRT (/MT) にする。
#
# リンク時に RuntimeLibrary の食い違いを見るのは、その記録を持つオブジェクト同士である。
# Crystal が生成するオブジェクトはこの記録を持たず、CRT はリンク行の msvcrt.lib で決まる。
# 記録を持つのは uing が配る ui.lib とこのライブラリだけで、ui.lib は静的 CRT でビルドされている。
# そのため合わせる相手は Crystal ではなく ui.lib になる。
#
# 静的 CRT を指定すると libcmt.lib と libcpmt.lib が既定ライブラリとして要求されるが、
# uing がリンク行に /NODEFAULTLIB:LIBCMT を足すため、C ランタイムは msvcrt.lib から解決される。
# C++ ランタイムは ui.lib と同じく libcpmt.lib から取る。
#
# Debug 構成でも静的 CRT の Release 版に合わせる。
# uing が配る ui.lib は debug 構成のものも MT_StaticRelease でビルドされているためである。
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")

add_library(NotifListenerShim STATIC src/notif_listener_shim.cpp)
target_include_directories(NotifListenerShim PUBLIC include)
target_compile_options(NotifListenerShim PRIVATE /EHsc /W4 /utf-8)
target_link_libraries(NotifListenerShim PUBLIC windowsapp runtimeobject ole32)

# 配布物ではない。シムの C API を叩いて挙動を確かめるためだけの実行ファイルである。
add_executable(shim_harness test/harness.cpp)
target_link_libraries(shim_harness PRIVATE NotifListenerShim)
target_compile_options(shim_harness PRIVATE /EHsc /utf-8)
