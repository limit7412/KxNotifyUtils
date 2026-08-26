require "log"
require "uing"

require "./config/models"
require "./config/repository"
require "./config/usecase"
require "./error/usecase"
require "./notify/models"
require "./notify/repository"
require "./notify/usecase"
require "./runtime/i18n"
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
require "./update/models"
require "./update/repository"
require "./update/usecase"
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
      # User-Agent の無い要求を GitHub API は拒む。実行中の版が分かる形にしておく。
      @update = Update::Usecase.new(
        Update::GitHubRepository.new("KxNotifyUtils/#{VERSION}"))
      # 確認が走っている間か。押し直しや周期の重なりで多重に投げないために持つ。
      @update_checking = false
      # 確認の最中に来た要求。終わってから改めて確認するために覚える。
      @update_recheck = false
      @update_recheck_manual = false
      # 直近の確認の結末（抑止前）。
      # 保留していた手動の要求へ、確認を投げ直さずに応えるために持つ。
      @update_last_result = nil.as(Update::CheckResult?)
      # 直近の確認でバルーンを出せたか。押した側への応答が済んでいるかの判断に使う。
      @update_last_notified = false
      # 覚えてある結末がどのチャンネルのものか。今の設定と突き合わせるために持つ。
      @update_last_channel = nil.as(String?)
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

      # UI の言語は起動時に一度だけ決める。
      # 画面は起動時に組み立てるため、動作中の設定変更には追従させない（issue #4）。
      # 設定を読めなかった場合は既定値の "auto" が使われ、OS の表示言語に従う。
      Runtime::I18n.locale = Runtime::I18n.resolve(@config.current.language)

      # 知らせ済みの版を復元してから最初の確認を行う。
      # 先に確認すると、前回知らせた版をもう一度知らせてしまう。
      @update.notified_tag = @config.current.update.notified_version

      unless errors.empty?
        Log.error { "設定の検証エラー: #{errors.join(" / ")}" }
        # 読めなかった設定は既定値で置き換わる。
        # 黙って始めると、たとえば whitelist が壊れていた場合に、
        # 除外していたはずの通知が流れ始めたことへ利用者が気付けない。
        @errors.notify(Runtime::I18n.t("notify.config_invalid.title"), errors.map(&.to_s).join("\n"))
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
      # チャンネルを変えたら確かめ直す。
      # 直前の結果は別のチャンネルのものであり、次の確認まで表示に残すわけにはいかない。
      check_update unless @update.checked?(root.update.channel)
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
            Log.error(exception: exception) { Runtime::I18n.log_text("error.source_start") }
          else
            @source_start_notified = true
            @errors.handle("error.source_start", exception)
          end
        end
      elsif !settings.enabled && @source_started
        @relay.sources.delete(@win_source)
        @errors.guard("error.source_stop") { @win_source.stop }
        @source_started = false
        Log.info { "Windows 通知ソースを無効にした" }
      end
    end

    # パッケージ化されていない Win32 アプリでは許可要求が失敗し続ける既知の問題があるため、
    # 失敗したときは Windows の設定画面へ誘導する。
    private def guide_notification_access : Nil
      @errors.notify(
        Runtime::I18n.t("notify.access_denied.title"),
        Runtime::I18n.t("notify.access_denied.body"),
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
      @errors.log_text = ->(key : String) { Runtime::I18n.log_text(key) }
      @errors.display_text = ->(key : String) { Runtime::I18n.t(key) }
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
        update_status: -> { update_status_label },
        update_url: -> { @update.available(@config.current.update.channel).try(&.url) },
      )
      window.on_request_steamvr_register = -> { register_steamvr }
      window.on_request_steamvr_unregister = -> { unregister_steamvr }
      window.on_open_notification_settings = -> { open_notification_settings }
      window
    end

    # 更新の確認（issue #10）。
    #
    # HTTP の応答待ちは別のファイバで行う。
    # 主ループの中で待つと、その間は通知の中継も WebSocket の接続維持も止まる。
    # ファイバは主ループの Fiber.yield で進むため、待っている間も常駐は動き続ける。
    #
    # 手動の確認は check_enabled を無視する。
    # 自動の確認を切っている利用者でも、押したときは確かめたいはずである。
    private def check_update(manual : Bool = false) : Nil
      return unless manual || @config.current.update.check_enabled

      # 確認の最中に来た要求は捨てずに保留する。
      # チャンネルを変えた直後がこれにあたり、捨てると新しいチャンネルは
      # 次の 24 時間の周期まで未確認のままになる。
      if @update_checking
        @update_recheck = true
        @update_recheck_manual ||= manual
        return
      end

      @update_checking = true
      channel = @config.current.update.channel
      spawn do
        begin
          # 抑止前の結末を覚える。保留していた手動の要求へはこちらを返す。
          # 自動のために UpToDate へ倒した結末を返すと、情報タブに新しい版が
          # 出ているのにバルーンだけ「最新である」と言うことになる。
          result = @update.check(VERSION, channel)

          if channel == @config.current.update.channel
            @update_last_channel = channel
            @update_last_result = result
            @update_last_notified =
              notify_update(manual ? result : @update.suppress_notified(result), manual)
          else
            # 覚えてある結末は今のチャンネルのものではなくなった。
            # 保留した要求へこれを返すわけにはいかない。
            @update_last_channel = nil
            # 確認の最中にチャンネルが変わっていた。この結果は今の設定のものではない。
            # stable を選び直した利用者へプレリリースのバルーンを出すわけにはいかない。
            #
            # 捨てるだけでは足りない。check は checked_channel を旧チャンネルへ
            # 書き換えており、今のチャンネルは未確認の扱いに変わっている。
            # 予約しないと、次の 24 時間の周期まで戻らない。
            @update_recheck = true
            @update_recheck_manual ||= manual
          end
        rescue exception
          @errors.handle("error.update_check", exception)
        ensure
          @update_checking = false
          flush_pending_update_check
        end
      end
    end

    # 確認の最中に来ていた要求をここで片付ける。
    private def flush_pending_update_check : Nil
      return unless @update_recheck

      @update_recheck = false
      manual = @update_recheck_manual
      @update_recheck_manual = false

      # 走っていた確認が今のチャンネルのものだったかで判断する。
      # Usecase#checked? では判断できない。あれは「これまでに確認できたか」であり、
      # 今しがた走った確認とは別のことを言う。
      # 失敗した確認は checked_channel を書き換えないため、チャンネルを変えて戻した後に
      # 失敗が返ると、古い確認の checked? が真のまま残って取り直しを飛ばしてしまう。
      unless @update_last_channel == @config.current.update.channel
        check_update(manual: manual)
        return
      end

      # 今のチャンネルの確認が終わっている。保留していたのは手動の要求だけなので、
      # 同じ確認をもう一度投げずに、終わった結果をそのまま知らせる。
      return unless manual

      # 待っている間にバルーンが出ていれば、押した側への応答は済んでいる。
      # 結末が Available かどうかでは判断できない。
      # 既に知らせた版は自動の側で抑止され、バルーンが出ないまま Available で残る。
      return if @update_last_notified

      result = @update_last_result
      return unless result

      @update_last_notified = notify_update(result, manual: true)
    end

    # 自動の確認は、新しい版が出ていたときだけ知らせる。
    # 手動で押したときは結末をそのまま返す。黙ると無反応と区別が付かないためである。
    #
    # バルーンを出せたかどうかを返す。
    # 保留していた手動の要求へ応答が済んでいるかの判断に使う。
    private def notify_update(result : Update::CheckResult, manual : Bool) : Bool
      case result.outcome
      in .available?
        release = result.release
        return false unless release
        shown = @errors.notify(
          Runtime::I18n.t("notify.update_available.title"),
          Runtime::I18n.t("notify.update_available.body", {"version" => release.tag}),
        )
        # 出せたときだけ覚える。
        # 出ていない版を覚えると、利用者が一度も見ないまま以後の確認で抑止される。
        # 自動と手動のどちらの経路でも、覚えるのはここだけである。
        return false unless shown
        @update.mark_notified(release)
        remember_notified_update
        true
      in .up_to_date?
        return false unless manual
        @errors.notify(
          Runtime::I18n.t("notify.update_none.title"),
          Runtime::I18n.t("notify.update_none.body"),
        )
      in .unreachable?
        return false unless manual
        @errors.notify(
          Runtime::I18n.t("notify.update_failed.title"),
          Runtime::I18n.t("notify.update_failed.body"),
        )
      in .unknown?
        # 手元ビルドでは比べる相手が無い。押しても何も言わない。
        Log.info { "実行中の版を比べられないため確認しない: #{VERSION}" }
        false
      end
    end

    # 見つけた版を先に見る。
    # check_enabled が false でも手動の確認はできるため、
    # 無効の表示を先に返すと、見つけた版とリリースページのボタンだけが出て文言が食い違う。
    # 知らせた版を設定へ残す。
    # 本体は SteamVR の自動起動で立ち上がるため、覚えておかないと
    # VR を始めるたびに同じ更新のバルーンが出る。
    private def remember_notified_update : Nil
      tag = @update.notified_tag
      return if tag.empty? || tag == @config.current.update.notified_version

      errors = @config.save(@config.current.with_update_notified(tag))
      return if errors.empty?

      # 書けなくても常駐は続ける。次の起動で同じ版をもう一度知らせるだけである。
      Log.warn { "知らせ済みの版を設定へ残せなかった: #{errors.join(" / ")}" }
    end

    private def update_status_label : String
      settings = @config.current.update
      if release = @update.available(settings.channel)
        return Runtime::I18n.t("settings.about.update_available", {"version" => release.tag})
      end
      return Runtime::I18n.t("settings.about.update_latest") if @update.checked?(settings.channel)
      return Runtime::I18n.t("settings.about.update_disabled") unless settings.check_enabled

      Runtime::I18n.t("settings.about.update_unchecked")
    end

    # SteamVR が起動していない状態で手動起動された場合も常駐を続け、scheduler が再試行する。
    private def start_steamvr : Nil
      @errors.guard("error.steamvr_start") do
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
      @errors.guard("error.steamvr_register") do
        next unless @steamvr.register
        @config.save(@config.current.with_steamvr(true, Runtime::Paths.executable_path))
        update_tray_state
      end
    end

    private def unregister_steamvr : Nil
      @errors.guard("error.steamvr_unregister") do
        result = @steamvr.unregister
        next if result.failed?

        # 自動起動を無効にできた時点で設定へ書き戻す。
        # マニフェストの登録解除だけが失敗した場合に「登録済み」を残すと、
        # 次回起動時の同期が自動起動を有効に戻してしまう。
        @config.save(@config.current.with_steamvr(false, "", configured: true))
        update_tray_state

        if result.auto_launch_only?
          @errors.notify(
            Runtime::I18n.t("notify.steamvr_unregister_partial.title"),
            Runtime::I18n.t("notify.steamvr_unregister_partial.body"),
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
        @relay.send_test(
          @config.current.defaults.to_resolved,
          Runtime::I18n.t("notify.test.title"),
          Runtime::I18n.t("notify.test.body"),
        )
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
      in .check_update?
        check_update(manual: true)
      in .quit?
        @stopping = true
      end
    rescue exception
      @errors.handle("error.tray_action", exception)
    end

    private def reload_config : Nil
      errors = @config.reload
      if errors.empty?
        @errors.notify(
          Runtime::I18n.t("notify.config_reloaded.title"),
          Runtime::I18n.t("notify.config_reloaded.body"),
        )
      else
        @errors.notify(Runtime::I18n.t("notify.config_invalid.title"), errors.map(&.to_s).join("\n"))
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
      in WinNotification::AccessStatus::Allowed     then Runtime::I18n.t("status.access.allowed")
      in WinNotification::AccessStatus::Denied      then Runtime::I18n.t("status.access.denied")
      in WinNotification::AccessStatus::Unspecified then Runtime::I18n.t("status.access.unspecified")
      in WinNotification::AccessStatus::Unknown     then Runtime::I18n.t("status.access.unknown")
      end
    end

    private def steamvr_status_label : String
      return Runtime::I18n.t("status.steamvr.disconnected") unless @openvr.opened?
      Runtime::I18n.t(@steamvr.registered? ? "status.steamvr.registered" : "status.steamvr.unregistered")
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
        @errors.guard("error.tray_pump") { @tray.pump }
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
      check_update if @scheduler.check_update?
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
      @errors.handle("error.settings_window", exception)
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
