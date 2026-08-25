require "log"
require "./win32"

module Runtime
  # トレイ常駐 UI（仕様書 4.7 節）。
  #
  # メニュー項目のハンドラは対応する usecase を呼ぶだけで、tray 自身はロジックを持たない。
  # 呼び出し先は composition root が on_command に登録する。
  class Tray
    Log = ::Log.for("runtime")

    CLASS_NAME  = "KxNotifyUtilsTrayWindow"
    WINDOW_NAME = "KxNotifyUtils"
    ICON_ID     = 1_u32
    # リソースに埋め込むアプリケーションアイコンの ID。
    APP_ICON_RESOURCE = 1_u32

    # メニュー項目。数値はメニューの項目 ID として使う。
    enum Command
      TogglePause       = 1
      SendTestMessage   = 2
      OpenSettings      = 3
      OpenConfigFile    = 4
      ReloadConfig      = 5
      RegisterSteamVR   = 6
      UnregisterSteamVR = 7
      OpenLogDirectory  = 8
      Quit              = 9
    end

    # メニューが選ばれたときに呼ぶフック。
    property on_command : Proc(Command, Nil) = ->(_command : Command) {}
    # メニュー表示中に一定間隔で呼ぶフック。composition root が主ループ 1 拍分を登録する。
    property on_idle : Proc(Nil) = -> { }
    # 中継の一時停止の状態。メニューのチェック表示に使う。
    property paused : Bool = false
    # SteamVR 連携が使えるか。使えないときは登録と解除を選べなくする。
    property steamvr_available : Bool = false
    property steamvr_registered : Bool = false

    getter? quit_requested : Bool = false

    # メニュー表示中に主ループを進めるためのタイマー。
    # 間隔は主ループの 1 拍（10 ミリ秒）に合わせる。
    IDLE_TIMER_ID          =  1_u64
    IDLE_TIMER_INTERVAL_MS = 10_u32

    # ウィンドウプロシージャは C の関数ポインタとして渡すためクロージャを作れない。
    # 実体へ戻るための参照をクラス変数に置く。
    @@instance : Tray?

    def initialize
      @hwnd = Pointer(Void).null
      @instance_handle = Pointer(Void).null
      @icon = Pointer(Void).null
      @added = false
      # Explorer が再起動するとシェル側のアイコンだけが消える。
      # このメッセージを受け取ったら登録し直す。
      @taskbar_created = 0_u32
      # メニューを表示している間だけ真。入れ子で開かないための印である。
      @menu_open = false
    end

    # メッセージ専用ウィンドウを作り、トレイアイコンを登録する。
    def start : Nil
      @@instance = self
      @instance_handle = LibWin32.get_module_handle_w(Pointer(UInt16).null)

      register_window_class
      create_window
      @taskbar_created = LibWin32.register_window_message_w(Win32.utf16("TaskbarCreated").to_unsafe)
      load_icon
      add_icon
    end

    def stop : Nil
      if @added
        data = notify_icon_data(LibWin32::NIF_MESSAGE)
        LibWin32.shell_notify_icon_w(LibWin32::NIM_DELETE, pointerof(data))
        @added = false
      end
      LibWin32.destroy_window(@hwnd) unless @hwnd.null?
      @hwnd = Pointer(Void).null
      @@instance = nil
    end

    # 溜まっているメッセージを処理する。
    # 常駐の主ループから繰り返し呼ぶため、メッセージが無ければすぐ戻る。
    def pump : Nil
      message = uninitialized LibWin32::Msg
      while LibWin32.peek_message_w(pointerof(message), Pointer(Void).null, 0, 0, LibWin32::PM_REMOVE) != 0
        if message.message == LibWin32::WM_QUIT
          @quit_requested = true
          return
        end
        LibWin32.translate_message(pointerof(message))
        LibWin32.dispatch_message_w(pointerof(message))
      end
    end

    # バルーン通知。許可の誘導とエラーの通知に使う。
    def show_balloon(title : String, body : String, level : UInt32 = LibWin32::NIIF_INFO) : Nil
      return unless @added

      data = notify_icon_data(LibWin32::NIF_INFO)
      Win32.copy_utf16(data.info_title.to_unsafe, 64, title)
      Win32.copy_utf16(data.info.to_unsafe, 256, body)
      data.info_flags = level
      LibWin32.shell_notify_icon_w(LibWin32::NIM_MODIFY, pointerof(data))
    end

    private def register_window_class : Nil
      class_name = Win32.utf16(CLASS_NAME)
      wnd_class = LibWin32::WndClassEx.new
      wnd_class.cb_size = sizeof(LibWin32::WndClassEx).to_u32
      wnd_class.wnd_proc = ->Tray.window_proc(LibWin32::Handle, UInt32, LibWin32::WParam, LibWin32::LParam).pointer
      wnd_class.instance = @instance_handle
      wnd_class.cursor = LibWin32.load_cursor_w(Pointer(Void).null, Win32.int_resource(LibWin32::IDC_ARROW))
      wnd_class.class_name = class_name.to_unsafe

      raise "トレイのウィンドウクラスを登録できなかった" if LibWin32.register_class_ex_w(pointerof(wnd_class)) == 0
    end

    # 画面に出さないトップレベルウィンドウを作る。
    #
    # メッセージ専用ウィンドウ（HWND_MESSAGE を親にしたもの）にはブロードキャストが届かない。
    # Explorer の再起動を知らせる TaskbarCreated はブロードキャストで飛ぶため、
    # それを受け取れるトップレベルウィンドウにしておく必要がある。
    # 表示はしないので、利用者から見た振る舞いはメッセージ専用ウィンドウと変わらない。
    private def create_window : Nil
      class_name = Win32.utf16(CLASS_NAME)
      window_name = Win32.utf16(WINDOW_NAME)
      @hwnd = LibWin32.create_window_ex_w(
        0_u32, class_name.to_unsafe, window_name.to_unsafe, 0_u32,
        0, 0, 0, 0,
        Pointer(Void).null, Pointer(Void).null, @instance_handle, Pointer(Void).null,
      )
      raise "トレイのウィンドウを作れなかった" if @hwnd.null?
    end

    # 埋め込んだアプリケーションアイコンを使い、取れなければ既定のアイコンで代用する。
    private def load_icon : Nil
      @icon = LibWin32.load_icon_w(@instance_handle, Win32.int_resource(APP_ICON_RESOURCE))
      return unless @icon.null?
      @icon = LibWin32.load_icon_w(Pointer(Void).null, Win32.int_resource(LibWin32::IDI_APPLICATION))
    end

    private def add_icon : Nil
      raise "トレイアイコンを登録できなかった" unless try_add_icon
    end

    private def try_add_icon : Bool
      data = notify_icon_data(LibWin32::NIF_MESSAGE | LibWin32::NIF_ICON | LibWin32::NIF_TIP)
      Win32.copy_utf16(data.tip.to_unsafe, 128, WINDOW_NAME)
      @added = LibWin32.shell_notify_icon_w(LibWin32::NIM_ADD, pointerof(data)) != 0
    end

    private def notify_icon_data(flags : UInt32) : LibWin32::NotifyIconData
      data = LibWin32::NotifyIconData.new
      data.cb_size = sizeof(LibWin32::NotifyIconData).to_u32
      data.hwnd = @hwnd
      data.id = ICON_ID
      data.flags = flags
      data.callback_message = LibWin32::WM_TRAY_CALLBACK
      data.icon = @icon
      data
    end

    # 右クリックとダブルクリックでメニューを出す。
    # TPM_RETURNCMD を使い、選ばれた項目 ID をその場で受け取る。
    private def show_menu : Nil
      # メニュー表示中の on_idle から間接的にメッセージが配られることがある。
      # 入れ子で開くと、内側が閉じるまで外側が戻らない。
      return if @menu_open

      menu = LibWin32.create_popup_menu
      return if menu.null?

      @menu_open = true
      begin
        append(menu, Command::TogglePause, @paused ? "中継を再開" : "中継を一時停止", checked: @paused)
        append(menu, Command::SendTestMessage, "テスト通知を送信")
        separator(menu)
        append(menu, Command::OpenSettings, "設定")
        append(menu, Command::OpenConfigFile, "設定ファイルを開く")
        append(menu, Command::ReloadConfig, "設定を再読み込み")
        separator(menu)
        if @steamvr_registered
          append(menu, Command::UnregisterSteamVR, "SteamVR 自動起動を解除", enabled: @steamvr_available)
        else
          append(menu, Command::RegisterSteamVR, "SteamVR 自動起動を登録", enabled: @steamvr_available)
        end
        append(menu, Command::OpenLogDirectory, "ログフォルダを開く")
        separator(menu)
        append(menu, Command::Quit, "終了")

        point = uninitialized LibWin32::Point
        LibWin32.get_cursor_pos(pointerof(point))
        # メニューを出す前に前面化しないと、メニュー外をクリックしても閉じない。
        LibWin32.set_foreground_window(@hwnd)

        # TrackPopupMenu は選択かキャンセルまで戻らず、その間 pump も主ループも止まる。
        # 通知のポーリングと WebSocket の接続維持まで止まってしまうため、
        # タイマーを仕掛けておく。WM_TIMER はメニューのメッセージループが配ってくれる。
        LibWin32.set_timer(@hwnd, IDLE_TIMER_ID, IDLE_TIMER_INTERVAL_MS, Pointer(Void).null)

        selected = LibWin32.track_popup_menu(
          menu,
          LibWin32::TPM_RIGHTBUTTON | LibWin32::TPM_NONOTIFY | LibWin32::TPM_RETURNCMD,
          point.x, point.y, 0, @hwnd, Pointer(Void).null,
        )
        return if selected == 0

        command = Command.from_value?(selected)
        @on_command.call(command) if command
      ensure
        LibWin32.kill_timer(@hwnd, IDLE_TIMER_ID)
        LibWin32.destroy_menu(menu)
        @menu_open = false
      end
    end

    private def append(menu : LibWin32::Handle, command : Command, label : String, checked = false, enabled = true) : Nil
      flags = LibWin32::MF_STRING
      flags |= LibWin32::MF_CHECKED if checked
      flags |= LibWin32::MF_GRAYED unless enabled
      LibWin32.append_menu_w(menu, flags, command.value.to_u64, Win32.utf16(label).to_unsafe)
    end

    private def separator(menu : LibWin32::Handle) : Nil
      LibWin32.append_menu_w(menu, LibWin32::MF_SEPARATOR, 0_u64, Pointer(UInt16).null)
    end

    protected def handle(message : UInt32, w_param : LibWin32::WParam, l_param : LibWin32::LParam) : Bool
      if @taskbar_created != 0 && message == @taskbar_created
        # Explorer が再起動した。シェル側のアイコンだけが消えているので登録し直す。
        @added = false
        Log.info { "タスクバーの再作成を検知したためトレイアイコンを登録し直す" } if try_add_icon
        return true
      end

      case message
      when LibWin32::WM_TIMER
        return false unless w_param == IDLE_TIMER_ID
        # メニューを閉じたあとに取り残されたタイマーで動かないよう、表示中だけ進める。
        @on_idle.call if @menu_open
        true
      when LibWin32::WM_TRAY_CALLBACK
        event = l_param.to_u32!
        show_menu if event == LibWin32::WM_RBUTTONUP || event == LibWin32::WM_LBUTTONDBLCLK
        true
      when LibWin32::WM_ENDSESSION
        # セッション終了が確定した。w_param が偽なら他のアプリが拒否している。
        # 問い合わせ（WM_QUERYENDSESSION）の時点で終了すると、
        # 拒否された場合にこのアプリだけが落ちたままになる。
        @quit_requested = true if w_param != 0
        true
      when LibWin32::WM_CLOSE, LibWin32::WM_DESTROY
        @quit_requested = true
        false
      else
        false
      end
    end

    # C の関数ポインタとして渡すため、クロージャを持たないクラスメソッドとして定義する。
    def self.window_proc(
      hwnd : LibWin32::Handle,
      message : UInt32,
      w_param : LibWin32::WParam,
      l_param : LibWin32::LParam,
    ) : LibWin32::LResult
      instance = @@instance
      if instance && instance.handle(message, w_param, l_param)
        return 0_i64
      end
      LibWin32.def_window_proc_w(hwnd, message, w_param, l_param)
    rescue exception
      Log.error(exception: exception) { "ウィンドウプロシージャで例外が出た" }
      0_i64
    end
  end
end
