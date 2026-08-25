require "log"
require "uing"

require "./config/models"
require "./config/repository"
require "./config/usecase"
require "./error/usecase"
require "./notify/models"
require "./notify/repository"
require "./notify/usecase"
require "./runtime/icon_repository"
require "./runtime/logging"
require "./runtime/paths"
require "./runtime/scheduler"
require "./runtime/settings_window"
require "./runtime/tray"
require "./runtime/win32"
require "./steamvr/openvr_repository"
require "./steamvr/repository"
require "./steamvr/usecase"
require "./win_notification/ffi_client"
require "./win_notification/models"
require "./win_notification/repository"
require "./win_notification/usecase"
require "./xsoverlay/models"
require "./xsoverlay/udp_repository"
require "./xsoverlay/websocket_repository"

# composition root。
# 設定の解決、アダプタの選択、usecase への依存注入をここで一度だけ行う（仕様書 2.1 節）。
module KxNotifyUtils
  # リリースのワークフローが、タグから決めた値を KXNOTIFYUTILS_VERSION で渡す。
  # 手元のビルドでは渡らないため、リリース版と見分けが付く既定値を使う。
  VERSION = {{ (env("KXNOTIFYUTILS_VERSION") || "") == "" ? "0.1.0-dev" : env("KXNOTIFYUTILS_VERSION") }}

  Log = ::Log.for("main")

  class Application
    def initialize
      @icons = Runtime::IconRepository.new
      @log_backend = Runtime::DailyFileBackend.new(Runtime::Paths.log_directory)
      @errors = Error::Usecase.new
      @tray = Runtime::Tray.new
      @config = ::Config::Usecase.new(::Config::FileRepository.new(Runtime::Paths.config_path))

      @win_client = WinNotification::FfiClient.new
      @win_source = WinNotification::Repository.new(@win_client, WinNotification::Settings.new)
      @sinks = [] of Notify::PostRepository
      # 通知先を組み直すかどうかの判断に使う、直前に適用したシンク設定。
      @sink_signature = ""
      # 監視対象を開始済みか。設定で有効と無効が切り替わったときの判断に使う。
      @source_started = false
      # 設定上は有効か。開始に失敗したまま止まっていないかの判断に使う。
      @source_enabled = false
      # 開始の失敗を利用者へ知らせたか。再試行のたびに同じ通知を出さないために持つ。
      @source_start_notified = false
      # SteamVR の同期が必要だったのに終わっていないか。再試行の判断に使う。
      @steamvr_sync_pending = false
      @relay = Notify::RelayUsecase.new(
        sources: [] of Notify::SourceRepository,
        sinks: @sinks,
        builders: [WinNotification::MessageBuilder.new(@icons).as(Notify::MessageBuilder)],
        config: @config.current,
      )

      @openvr = SteamVR::OpenVRRepository.new
      @steamvr = SteamVR::Usecase.new(
        @openvr,
        SteamVR::FileManifestStore.new,
        Runtime::Paths.manifest_path,
        Runtime::Paths.executable_path,
      )
      @scheduler = Runtime::Scheduler.new(@relay, @steamvr, @errors)
      @settings_window = nil.as(Runtime::SettingsWindow?)
      @stopping = false
    end

    def run : Nil
      Runtime::Logging.setup(@log_backend)
      {% if flag?(:windows) %}
        Runtime::Win32.enable_per_monitor_dpi_awareness
      {% end %}

      # 手動起動と SteamVR の自動起動が重なると、同じ通知を 2 つのプロセスが取得し、
      # 同じクライアント名で XSOverlay へ送ることになる。
      # 通知が重複するため、後から起動したほうは何もせず終了する。
      unless single_instance?
        Log.info { "KxNotifyUtils は既に起動している。このプロセスは終了する" }
        return
      end

      Log.info { "KxNotifyUtils #{VERSION} を起動する: #{Runtime::Paths.executable_path}" }

      # トレイを先に立てる。
      # 通知アクセスの誘導など、設定の読み込みの途中で利用者へ伝えたいことがあるためである。
      #
      # 立てられなければ起動を終える。
      # トレイはこのアプリの唯一の操作面であり、無いまま常駐すると
      # 設定も終了もできないプロセスが、多重起動の抑止によって置き換えもできずに残る。
      unless start_tray
        Log.error { "トレイを作れなかった。操作する手立てが無いため起動を終える" }
        return
      end
      register_validators
      load_config
      build_sources
      build_sinks
      start_ui
      start_steamvr
      main_loop
    ensure
      shutdown
    end

    private def single_instance? : Bool
      {% if flag?(:windows) %}
        Runtime::Win32.acquire_single_instance("Local\\KxNotifyUtils")
      {% else %}
        true
      {% end %}
    end

    # sources と sinks の各セクションは、そのアダプタ自身に検証させる。
    private def register_validators : Nil
      @config.register_validator("sources.#{WinNotification::SOURCE_ID}") do |section|
        WinNotification::Settings.validate(section)
      end
      @config.register_validator("sinks.#{XSOverlay::SINK_ID}") do |section|
        XSOverlay::Settings.validate(section)
      end
    end

    private def load_config : Nil
      errors = @config.load
      unless errors.empty?
        Log.error { "設定の検証エラー: #{errors.join(" / ")}" }
        # 読めなかった設定は既定値で置き換わる。
        # 黙って始めると、たとえば whitelist が壊れていた場合に、
        # 除外していたはずの通知が流れ始めたことへ利用者が気付けない。
        @errors.notify("設定を読めなかった", errors.map(&.to_s).join("\n"))
      end
      @config.on_apply = ->(root : ::Config::Root) { apply(root) }
      apply(@config.current)
    end

    # 設定スナップショットを各所へ配る。
    # 差し替えは代入 1 回で終わるため、ポーリング周期の途中で新旧が混ざらない。
    private def apply(root : ::Config::Root) : Nil
      Runtime::Logging.setup(@log_backend, root.log_level)
      @relay.config = root
      @icons.clear
      build_sources(root)
      rebuild_sinks(root)
    end

    # 設定の sources セクションから監視対象を組み立てる。
    #
    # 有効と無効の切り替えは設定の保存や再読み込みでも起きるため、
    # 起動時だけでなく反映のたびに、追加と開始、停止と削除まで行う。
    private def build_sources(root : ::Config::Root = @config.current) : Nil
      settings = WinNotification::Settings.from_section(root.source(WinNotification::SOURCE_ID))
      @win_source.settings = settings
      @source_enabled = settings.enabled

      if settings.enabled && !@source_started
        # 初期化に失敗したソースを並べると毎周期ポーリングに失敗し続けるため、
        # 開始できたものだけを中継の対象にする。
        begin
          @win_source.start
          @source_started = true
          @source_start_notified = false
          @relay.sources << @win_source unless @relay.sources.includes?(@win_source)
          guide_notification_access unless @win_source.access_status.allowed?
        rescue exception
          # 開始できるまで一定間隔で試し直すため、知らせるのは最初の 1 回だけとする。
          # 同じ失敗のたびにトレイ通知を出すと、利用者の手が止まる。
          if @source_start_notified
            Log.error(exception: exception) { "Windows 通知ソースの初期化" }
          else
            @source_start_notified = true
            @errors.handle("Windows 通知ソースの初期化", exception)
          end
        end
      elsif !settings.enabled && @source_started
        @relay.sources.delete(@win_source)
        @errors.guard("Windows 通知ソースの停止") { @win_source.stop }
        @source_started = false
        Log.info { "Windows 通知ソースを無効にした" }
      end
    end

    # パッケージ化されていない Win32 アプリでは許可要求が失敗し続ける既知の問題があるため、
    # 失敗したときは Windows の設定画面へ誘導する。
    private def guide_notification_access : Nil
      @errors.notify(
        "通知へのアクセスが許可されていない",
        "Windows の設定 > プライバシーとセキュリティ > 通知 から、KxNotifyUtils に許可する。",
      )
      {% if flag?(:windows) %}
        Runtime::Win32.open_with_shell("ms-settings:privacy-notifications")
      {% end %}
    end

    # 設定の sinks セクションから通知先を組み立てる。
    # 想定外の値は設定の検証で弾いているため、ここでは有効なものを並べるだけとする。
    private def build_sinks : Nil
      rebuild_sinks(@config.current)
    end

    # 送信経路もポートも接続の張り直しが要るため、設定が変わったら通知先を作り直す。
    # 変わっていなければ何もしない。設定を保存するたびに接続が切れるのを避けるためである。
    private def rebuild_sinks(root : ::Config::Root) : Nil
      settings = XSOverlay::Settings.from_section(root.sink(XSOverlay::SINK_ID))
      signature = settings.enabled ? settings.to_json : ""
      return if signature == @sink_signature

      @sinks.each(&.stop)
      @sinks.clear
      @sink_signature = signature
      return unless settings.enabled

      sink = case settings.transport
             in XSOverlay::Transport::Websocket then XSOverlay::WebsocketRepository.new(settings)
             in XSOverlay::Transport::Udp       then XSOverlay::UdpRepository.new(settings)
             end
      @sinks << sink
      sink.start
      Log.info { "通知先を組み立てた: #{sink.sink_id} (#{settings.transport.to_s.downcase})" }
    end

    private def start_tray : Bool
      @tray.on_command = ->(command : Runtime::Tray::Command) { handle(command) }
      @tray.start
      @errors.notifier = ->(title : String, body : String) { @tray.show_balloon(title, body) }
      true
    rescue exception
      # notifier をまだ登録していないため、ここで伝えられるのはログだけである。
      Log.error(exception: exception) { "トレイの初期化" }
      false
    end

    # libui-ng の初期化に失敗しても常駐は続ける。設定は JSON の手編集でも行える。
    private def start_ui : Nil
      UIng.init
      UIng.main_steps
      @settings_window = build_settings_window
    rescue exception
      Log.error(exception: exception) { "設定編集ウィンドウを使えない" }
    end

    private def build_settings_window : Runtime::SettingsWindow
      window = Runtime::SettingsWindow.new(
        @config,
        @relay,
        VERSION,
        access_status: -> { access_status_label },
        steamvr_status: -> { steamvr_status_label },
      )
      window.on_request_steamvr_register = -> { register_steamvr }
      window.on_request_steamvr_unregister = -> { unregister_steamvr }
      window.on_open_notification_settings = -> { open_notification_settings }
      window
    end

    # SteamVR が起動していない状態で手動起動された場合も常駐を続け、scheduler が再試行する。
    private def start_steamvr : Nil
      @errors.guard("SteamVR の初期化") do
        if @openvr.open
          register_steamvr unless @config.current.steamvr.auto_launch_configured
          sync_steamvr
        end
        update_tray_state
      end
    end

    private def sync_steamvr : Nil
      # 印は呼ぶ前に立てる。
      # 同期の途中で例外が出ると外側の guard が握り、この先の行に届かない。
      # 印が下りたままだと、設定に残る過去の決着によって再試行の条件も外れ、
      # 移動した実行ファイルのパスが次の起動まで直らない。
      @steamvr_sync_pending = true

      result = @steamvr.sync(@config.current.steamvr)
      @steamvr_sync_pending = result.outcome.failed?

      section = result.section
      return unless section
      @config.save(@config.current.with_steamvr(section.auto_launch_registered, section.last_exe_path))
    end

    private def register_steamvr : Nil
      @errors.guard("SteamVR への登録") do
        next unless @steamvr.register
        @config.save(@config.current.with_steamvr(true, Runtime::Paths.executable_path))
        update_tray_state
      end
    end

    private def unregister_steamvr : Nil
      @errors.guard("SteamVR 登録の解除") do
        result = @steamvr.unregister
        next if result.failed?

        # 自動起動を無効にできた時点で設定へ書き戻す。
        # マニフェストの登録解除だけが失敗した場合に「登録済み」を残すと、
        # 次回起動時の同期が自動起動を有効に戻してしまう。
        @config.save(@config.current.with_steamvr(false, "", configured: true))
        update_tray_state

        if result.auto_launch_only?
          @errors.notify(
            "SteamVR の登録解除が途中で止まった",
            "自動起動は無効にした。vrmanifest の登録解除に失敗したため、SteamVR 側にアプリの登録が残っている。",
          )
        end
      end
    end

    private def handle(command : Runtime::Tray::Command) : Nil
      case command
      in .toggle_pause?
        @relay.paused = !@relay.paused
        update_tray_state
        Log.info { @relay.paused ? "中継を一時停止した" : "中継を再開した" }
      in .send_test_message?
        @relay.send_test(@config.current.defaults.to_resolved)
      in .open_settings?
        @settings_window.try(&.open)
      in .open_config_file?
        open_with_shell(@config.repository.path)
      in .reload_config?
        reload_config
      in .register_steam_vr?
        register_steamvr
      in .unregister_steam_vr?
        unregister_steamvr
      in .open_log_directory?
        open_with_shell(Runtime::Paths.log_directory)
      in .quit?
        @stopping = true
      end
    rescue exception
      @errors.handle("トレイの操作", exception)
    end

    private def reload_config : Nil
      errors = @config.reload
      if errors.empty?
        @errors.notify("設定を再読み込みした", "編集した設定を反映した。")
      else
        @errors.notify("設定を読めなかった", errors.map(&.to_s).join("\n"))
      end
      @settings_window.try(&.notify_external_change)
    end

    private def open_notification_settings : Nil
      open_with_shell("ms-settings:privacy-notifications")
    end

    private def open_with_shell(target : String) : Nil
      {% if flag?(:windows) %}
        Runtime::Win32.open_with_shell(target)
      {% else %}
        Log.info { "開く対象: #{target}" }
      {% end %}
    end

    private def update_tray_state : Nil
      @tray.paused = @relay.paused
      @tray.steamvr_available = @openvr.opened?
      @tray.steamvr_registered = @steamvr.registered?
    end

    private def access_status_label : String
      case @win_source.access_status
      in WinNotification::AccessStatus::Allowed     then "許可されている"
      in WinNotification::AccessStatus::Denied      then "拒否されている"
      in WinNotification::AccessStatus::Unspecified then "未設定"
      in WinNotification::AccessStatus::Unknown     then "不明"
      end
    end

    private def steamvr_status_label : String
      return "SteamVR に接続していない" unless @openvr.opened?
      @steamvr.registered? ? "登録済み" : "未登録"
    end

    # 常駐の主ループ。
    #
    # トレイのメッセージポンプ、libui-ng のステップ、ポーリングを 1 本のスレッドで回す。
    # sleep を挟むことで、WebSocket の接続維持など他のファイバへ実行が渡る。
    private def main_loop : Nil
      # トレイメニューを開いている間、TrackPopupMenu は選択かキャンセルまで戻らない。
      # その間もポーリングと WebSocket の接続維持を進めるため、
      # トレイのタイマーからも 1 拍分を回す。
      @tray.on_idle = -> { background_step }

      until @stopping
        @errors.guard("トレイのメッセージ処理") { @tray.pump }
        break if @tray.quit_requested?

        background_step
        break if @scheduler.quit_requested?

        sleep 10.milliseconds
      end
    end

    # 主ループ 1 拍のうち、トレイのメッセージ処理以外。
    # 主ループからも、トレイメニュー表示中のタイマーからも呼ぶ。
    private def background_step : Nil
      step_ui
      retry_source if @source_enabled && !@source_started
      retry_steamvr if steamvr_retry_needed?
      @scheduler.step
      # 他のファイバへ実行を渡す。WebSocket の接続維持はここで進む。
      Fiber.yield
    end

    # OpenVR につながっていないか、自動登録の決着がついていない間は試し直す。
    #
    # 接続だけを見るわけにはいかない。
    # 初期化に成功しても登録が一時的に失敗することはあり、そのまま諦めると
    # 一度も登録しないまま SteamVR の終了に合わせて終わってしまうためである。
    #
    # 同期の失敗も同じである。設定には過去の決着が残っているため、
    # そこだけを見ると、移動した実行ファイルのパスが次の起動まで直らない。
    private def steamvr_retry_needed? : Bool
      return true unless @openvr.opened?
      return true if @steamvr_sync_pending
      !@config.current.steamvr.auto_launch_configured
    end

    # 通知ソースの開始に失敗したままにしない。
    #
    # 起動直後は WinRT の初期化が一時的に失敗することがある。
    # 設定の保存や再読み込みを待つと、その間の通知をすべて取りこぼすため、
    # 有効なのに開始できていない間は一定間隔でやり直す。
    private def retry_source : Nil
      return unless @scheduler.retry_source?
      build_sources
    end

    # SteamVR を後から起動した場合に備え、初期化を一定間隔でやり直す。
    private def retry_steamvr : Nil
      return unless @scheduler.retry_openvr?
      start_steamvr
    end

    private def step_ui : Nil
      window = @settings_window
      return unless window
      UIng.main_step(false)
      window.tick
    rescue exception
      @errors.handle("設定ウィンドウの処理", exception)
    end

    # アダプタの生存期間は composition root が持つ。
    private def shutdown : Nil
      Log.info { "KxNotifyUtils を終了する" }
      @sinks.each { |sink| sink.stop rescue nil }
      @win_source.stop rescue nil if @source_started
      @tray.stop rescue nil
      @openvr.close rescue nil
      UIng.uninit rescue nil
    end
  end
end

KxNotifyUtils::Application.new.run
