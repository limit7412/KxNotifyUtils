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
  VERSION = "0.1.0"

  Log = ::Log.for("main")

  class Application
    def initialize
      @icons = Runtime::IconRepository.new
      @errors = Error::Usecase.new
      @tray = Runtime::Tray.new
      @config = ::Config::Usecase.new(::Config::FileRepository.new(Runtime::Paths.config_path))
      @first_run = !@config.repository.exists?

      @win_client = WinNotification::FfiClient.new
      @win_source = WinNotification::Repository.new(@win_client, WinNotification::Settings.new)
      @sinks = [] of Notify::PostRepository
      @sink_transport = nil.as(XSOverlay::Transport?)
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
      Runtime::Logging.setup
      Log.info { "KxNotifyUtils #{VERSION} を起動する: #{Runtime::Paths.executable_path}" }

      register_validators
      load_config
      build_sources
      build_sinks
      start_tray
      start_ui
      start_steamvr
      @relay.start
      main_loop
    ensure
      shutdown
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
      Log.error { "設定の検証エラー: #{errors.join(" / ")}" } unless errors.empty?
      @config.on_apply = ->(root : ::Config::Root) { apply(root) }
      apply(@config.current)
    end

    # 設定スナップショットを各所へ配る。
    # 差し替えは代入 1 回で終わるため、ポーリング周期の途中で新旧が混ざらない。
    private def apply(root : ::Config::Root) : Nil
      Runtime::Logging.setup(level: root.log_level)
      @relay.config = root
      @win_source.settings = WinNotification::Settings.from_section(root.source(WinNotification::SOURCE_ID))
      @icons.clear
      rebuild_sinks(root)
    end

    # 設定の sources セクションから監視対象を組み立てる。
    private def build_sources : Nil
      settings = WinNotification::Settings.from_section(@config.current.source(WinNotification::SOURCE_ID))
      @win_source.settings = settings
      return unless settings.enabled

      @relay.sources << @win_source
      @errors.guard("Windows 通知ソースの初期化") do
        @win_source.start
        guide_notification_access unless @win_source.access_status.allowed?
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

    private def rebuild_sinks(root : ::Config::Root) : Nil
      settings = XSOverlay::Settings.from_section(root.sink(XSOverlay::SINK_ID))
      desired = settings.enabled ? settings.transport : nil

      return if desired == @sink_transport

      @sinks.each(&.stop)
      @sinks.clear
      @sink_transport = desired
      return unless desired

      sink = case desired
             in XSOverlay::Transport::Websocket then XSOverlay::WebsocketRepository.new(settings)
             in XSOverlay::Transport::Udp       then XSOverlay::UdpRepository.new(settings)
             end
      @sinks << sink
      sink.start
      Log.info { "通知先を組み立てた: #{sink.sink_id} (#{desired.to_s.downcase})" }
    end

    private def start_tray : Nil
      @tray.on_command = ->(command : Runtime::Tray::Command) { handle(command) }
      @errors.guard("トレイの初期化") { @tray.start }
      @errors.notifier = ->(title : String, body : String) { @tray.show_balloon(title, body) }
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
          register_steamvr if @first_run
          sync_steamvr
        end
        update_tray_state
      end
    end

    private def sync_steamvr : Nil
      updated = @steamvr.sync(@config.current.steamvr)
      return unless updated
      @config.save(@config.current.with_steamvr(updated.auto_launch_registered, updated.last_exe_path))
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
        next unless @steamvr.unregister
        @config.save(@config.current.with_steamvr(false, ""))
        update_tray_state
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
      until @stopping
        @errors.guard("トレイのメッセージ処理") { @tray.pump }
        break if @tray.quit_requested?

        step_ui
        retry_steamvr unless @openvr.opened?
        @scheduler.step
        break if @scheduler.quit_requested?

        sleep 10.milliseconds
      end
    end

    # SteamVR を後から起動した場合に備え、初期化を一定間隔でやり直す。
    private def retry_steamvr : Nil
      return unless @scheduler.retry_openvr?
      start_steamvr
    end

    private def step_ui : Nil
      return unless @settings_window
      UIng.main_step(false)
    rescue exception
      @errors.handle("設定ウィンドウの処理", exception)
    end

    private def shutdown : Nil
      Log.info { "KxNotifyUtils を終了する" }
      @relay.stop rescue nil
      @tray.stop rescue nil
      @openvr.close rescue nil
      UIng.uninit rescue nil
    end
  end
end

KxNotifyUtils::Application.new.run
