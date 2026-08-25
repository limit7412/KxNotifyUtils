require "./models"

module WinNotification
  # NotifListenerShim（C++/WinRT 静的ライブラリ）の C API 宣言（仕様書 3.2 節）。
  #
  # WinRT は COM ベースの ABI であり、Crystal の C FFI から直接呼ぶには
  # HSTRING 操作や vtable 定義や非同期ハンドラ登録が必要になる。
  # それらをシム側に閉じ込めているため、ここはポインタと整数だけの宣言で済む。
  # この lib 宣言を参照するのは同じコンテキストの ffi_client.cr だけとする。
  #
  # windowsapp と runtimeobject と ole32 は、C++/WinRT が要求するシステムライブラリである。
  @[Link("NotifListenerShim")]
  @[Link("windowsapp")]
  @[Link("runtimeobject")]
  @[Link("ole32")]
  lib LibShim
    fun init = nls_init : Int32
    fun shutdown = nls_shutdown : Void
    fun get_access_status = nls_get_access_status : Int32
    fun request_access = nls_request_access : Int32
    fun get_notifications = nls_get_notifications : UInt8*
    fun free_string = nls_free_string(p : UInt8*) : Void
    fun last_error = nls_last_error : UInt8*
  end
end
