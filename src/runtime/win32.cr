module Runtime
  # トレイ常駐に必要な Win32 API の宣言（仕様書 4.7 節）。
  #
  # GUI ツールキットを使わず Win32 を直に叩くのは、トレイアイコンとメニューだけのために
  # ツールキットを 1 つ増やしたくないためである。設定ウィンドウ側は libui-ng を使う。
  lib LibWin32
    alias Handle = Void*
    alias WParam = UInt64
    alias LParam = Int64
    alias LResult = Int64

    WM_DESTROY         = 0x0002_u32
    WM_CLOSE           = 0x0010_u32
    WM_QUERYENDSESSION = 0x0011_u32
    WM_ENDSESSION      = 0x0016_u32
    WM_QUIT            = 0x0012_u32
    WM_TIMER           = 0x0113_u32
    WM_RBUTTONUP       = 0x0205_u32
    WM_LBUTTONDBLCLK   = 0x0203_u32
    WM_APP             = 0x8000_u32

    # トレイアイコンからの通知を受け取るための独自メッセージ。
    WM_TRAY_CALLBACK = 0x8001_u32

    PM_REMOVE = 0x0001_u32

    NIM_ADD    = 0x0000_u32
    NIM_MODIFY = 0x0001_u32
    NIM_DELETE = 0x0002_u32

    NIF_MESSAGE = 0x0001_u32
    NIF_ICON    = 0x0002_u32
    NIF_TIP     = 0x0004_u32
    NIF_INFO    = 0x0010_u32

    NIIF_INFO    = 0x0001_u32
    NIIF_WARNING = 0x0002_u32
    NIIF_ERROR   = 0x0003_u32

    MF_STRING    = 0x0000_u32
    MF_GRAYED    = 0x0001_u32
    MF_CHECKED   = 0x0008_u32
    MF_SEPARATOR = 0x0800_u32

    TPM_LEFTALIGN   = 0x0000_u32
    TPM_RIGHTBUTTON = 0x0002_u32
    TPM_NONOTIFY    = 0x0080_u32
    TPM_RETURNCMD   = 0x0100_u32

    IMAGE_ICON      =      1_u32
    LR_DEFAULTSIZE  = 0x0040_u32
    LR_SHARED       = 0x8000_u32
    IDI_APPLICATION =  32512_u32
    IDC_ARROW       =  32512_u32

    SW_SHOWNORMAL = 1_i32

    ERROR_ALREADY_EXISTS = 183_u32

    WAIT_OBJECT_0 = 0x00000000_u32

    struct Point
      x : Int32
      y : Int32
    end

    struct Msg
      hwnd : Handle
      message : UInt32
      w_param : WParam
      l_param : LParam
      time : UInt32
      pt : Point
      private_value : UInt32
    end

    struct WndClassEx
      cb_size : UInt32
      style : UInt32
      wnd_proc : Void*
      cb_cls_extra : Int32
      cb_wnd_extra : Int32
      instance : Handle
      icon : Handle
      cursor : Handle
      background : Handle
      menu_name : UInt16*
      class_name : UInt16*
      icon_small : Handle
    end

    # NOTIFYICONDATAW。配列の長さは Windows SDK の定義に合わせる。
    struct NotifyIconData
      cb_size : UInt32
      hwnd : Handle
      id : UInt32
      flags : UInt32
      callback_message : UInt32
      icon : Handle
      tip : UInt16[128]
      state : UInt32
      state_mask : UInt32
      info : UInt16[256]
      timeout_or_version : UInt32
      info_title : UInt16[64]
      info_flags : UInt32
      guid_item : UInt8[16]
      balloon_icon : Handle
    end

    fun get_module_handle_w = GetModuleHandleW(module_name : UInt16*) : Handle
    fun create_mutex_w = CreateMutexW(attributes : Void*, initial_owner : Int32, name : UInt16*) : Handle
    fun create_event_w = CreateEventW(
      attributes : Void*, manual_reset : Int32, initial_state : Int32, name : UInt16*
    ) : Handle
    fun set_event = SetEvent(handle : Handle) : Int32
    fun reset_event = ResetEvent(handle : Handle) : Int32
    fun wait_for_single_object = WaitForSingleObject(handle : Handle, milliseconds : UInt32) : UInt32
    fun close_handle = CloseHandle(handle : Handle) : Int32
    # タスクバーの再作成を知るためのブロードキャストメッセージ ID を得る。
    fun register_window_message_w = RegisterWindowMessageW(name : UInt16*) : UInt32
    fun get_user_default_ui_language = GetUserDefaultUILanguage : UInt16
    fun get_last_error = GetLastError : UInt32

    fun register_class_ex_w = RegisterClassExW(wnd_class : WndClassEx*) : UInt16
    fun create_window_ex_w = CreateWindowExW(
      ex_style : UInt32, class_name : UInt16*, window_name : UInt16*, style : UInt32,
      x : Int32, y : Int32, width : Int32, height : Int32,
      parent : Handle, menu : Handle, instance : Handle, param : Void*
    ) : Handle
    fun destroy_window = DestroyWindow(hwnd : Handle) : Int32
    fun def_window_proc_w = DefWindowProcW(hwnd : Handle, message : UInt32, w_param : WParam, l_param : LParam) : LResult
    fun post_quit_message = PostQuitMessage(exit_code : Int32) : Void
    fun peek_message_w = PeekMessageW(msg : Msg*, hwnd : Handle, filter_min : UInt32, filter_max : UInt32, remove : UInt32) : Int32
    fun translate_message = TranslateMessage(msg : Msg*) : Int32
    fun dispatch_message_w = DispatchMessageW(msg : Msg*) : LResult

    fun load_icon_w = LoadIconW(instance : Handle, icon_name : UInt16*) : Handle
    fun load_cursor_w = LoadCursorW(instance : Handle, cursor_name : UInt16*) : Handle

    fun create_popup_menu = CreatePopupMenu : Handle
    fun append_menu_w = AppendMenuW(menu : Handle, flags : UInt32, id : UInt64, item : UInt16*) : Int32
    fun destroy_menu = DestroyMenu(menu : Handle) : Int32
    fun track_popup_menu = TrackPopupMenu(
      menu : Handle, flags : UInt32, x : Int32, y : Int32,
      reserved : Int32, hwnd : Handle, rect : Void*
    ) : Int32
    fun set_timer = SetTimer(hwnd : Handle, id : UInt64, interval_ms : UInt32, callback : Void*) : UInt64
    fun kill_timer = KillTimer(hwnd : Handle, id : UInt64) : Int32

    fun get_cursor_pos = GetCursorPos(point : Point*) : Int32
    fun set_foreground_window = SetForegroundWindow(hwnd : Handle) : Int32

    # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2。
    # マニフェストではなく起動時の呼び出しで設定する。
    # libui-ng 側が Common Controls v6 のマニフェストを埋め込むため、
    # 同じ RT_MANIFEST リソースを本体からも足すと衝突するからである。
    fun set_process_dpi_awareness_context = SetProcessDpiAwarenessContext(context : Void*) : Int32

    fun shell_notify_icon_w = Shell_NotifyIconW(message : UInt32, data : NotifyIconData*) : Int32
    fun shell_execute_w = ShellExecuteW(
      hwnd : Handle, operation : UInt16*, file : UInt16*,
      parameters : UInt16*, directory : UInt16*, show : Int32
    ) : Handle
  end

  module Win32
    # 数値のリソース ID を LPCWSTR として渡すための MAKEINTRESOURCE 相当。
    def self.int_resource(id : UInt32) : UInt16*
      Pointer(UInt16).new(id.to_u64)
    end

    # 名前付きミューテックスを取り、このプロセスが最初の 1 つかを返す。
    #
    # ハンドルはプロセスが終わるまで保持する。
    # 閉じるとミューテックスが解放され、二重起動を防げなくなるためである。
    @@single_instance : LibWin32::Handle?

    def self.acquire_single_instance(name : String) : Bool
      handle = LibWin32.create_mutex_w(Pointer(Void).null, 0, utf16(name).to_unsafe)
      return false if handle.null?

      # 既にあるミューテックスを開いた場合、こちらのハンドルもそれを生かし続ける。
      # 抑止に掛かった側が終わるまで持っていると、その間は
      # 常駐している側がハンドルを手放しても、ミューテックスは残ったままになる。
      # 置き換えて起動した新しいプロセスが「既に起動している」と判断して終わり、
      # 渡した側も起動できたつもりで終わるため、どちらも残らない（issue #10 第 2 段階）。
      if LibWin32.get_last_error == LibWin32::ERROR_ALREADY_EXISTS
        LibWin32.close_handle(handle)
        return false
      end

      @@single_instance = handle
      true
    end

    # 多重起動の抑止を解く（issue #10 第 2 段階）。
    #
    # 置き換えて新しい exe を起動するときに使う。
    # 握ったまま起動すると、新しい側が「既に起動している」と判断して終わってしまう。
    # 解いた後に起動が失敗した場合は取り直せるよう、握っていたかどうかを返す。
    def self.release_single_instance : Bool
      handle = @@single_instance
      return false unless handle

      @@single_instance = nil
      LibWin32.close_handle(handle)
      true
    end

    # 置き換えた側が常駐へ入ったことを伝える名前付きイベントを用意する（issue #29）。
    #
    # 起動より前に作る。子が知らせた後に作ると、その SetEvent を取り落とし、
    # 常駐へ入っているのに期限まで待つことになる。
    #
    # 手動リセットにする。自動リセットだと、待ち始める前に来た知らせを
    # 最初に見に行った 1 回で消費してしまい、以降は非シグナルに戻る。
    #
    # 同じ名前のイベントが前の置き換えから残っている場合に備えて、作った後に落としておく。
    # シグナルのまま渡されると、子を起動する前から「常駐へ入った」と読めてしまう。
    def self.create_ready_event(name : String) : LibWin32::Handle?
      handle = LibWin32.create_event_w(Pointer(Void).null, 1, 0, utf16(name).to_unsafe)
      return nil if handle.null?

      LibWin32.reset_event(handle)
      handle
    end

    # 今シグナルになっているかだけを見る。
    #
    # 期限を渡して OS の中で待つことはしない。WaitForSingleObject はスレッドを止めるため、
    # 待っている間は他のファイバが進まず、WebSocket の接続維持まで止まる。
    # 呼ぶ側が Crystal の sleep を挟んで見に来る。
    def self.event_signaled?(handle : LibWin32::Handle) : Bool
      LibWin32.wait_for_single_object(handle, 0) == LibWin32::WAIT_OBJECT_0
    end

    def self.close_event(handle : LibWin32::Handle) : Nil
      LibWin32.close_handle(handle)
    end

    # 常駐へ入ったことを、置き換えて起動した側へ伝える（issue #29）。
    #
    # 渡された側かどうかは見ずに、常駐へ入るたびに知らせる。
    # 待っている親がいなければ、その場で作ったイベントを立てて閉じるだけで終わる。
    # 引数で渡された場合だけ知らせる形にすると、起動の経路を数えることになり、
    # 数え漏らしたほうが黙って期限まで待たされる。
    def self.signal_ready(name : String) : Nil
      handle = LibWin32.create_event_w(Pointer(Void).null, 1, 0, utf16(name).to_unsafe)
      return if handle.null?

      LibWin32.set_event(handle)
      LibWin32.close_handle(handle)
    end

    # 画面ごとの DPI に追従させる。Windows 10 バージョン 1703 以降で有効になる。
    def self.enable_per_monitor_dpi_awareness : Nil
      LibWin32.set_process_dpi_awareness_context(Pointer(Void).new(-4.to_u64!))
    end

    def self.utf16(value : String) : Slice(UInt16)
      value.to_utf16
    end

    # 固定長の UTF-16 配列へ、終端を残して詰める。
    def self.copy_utf16(target : Pointer(UInt16), capacity : Int32, value : String) : Nil
      encoded = value.to_utf16
      length = Math.min(encoded.size, capacity - 1)
      length.times { |i| target[i] = encoded[i] }
      target[length] = 0_u16
    end

    # 既定のアプリケーションで開く。設定ファイル、ログフォルダ、Windows 設定画面に使う。
    def self.open_with_shell(target : String) : Nil
      LibWin32.shell_execute_w(
        Pointer(Void).null,
        utf16("open").to_unsafe,
        utf16(target).to_unsafe,
        Pointer(UInt16).null,
        Pointer(UInt16).null,
        LibWin32::SW_SHOWNORMAL,
      )
    end
  end
end
