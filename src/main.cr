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
require "./update/installer"
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
    # 多重起動の抑止に使う名前付きミューテックス。
    SINGLE_INSTANCE_NAME = "Local\\KxNotifyUtils"

    # 置き換えた実行ファイルが落ち着くのを待つ時間（issue #10 第 2 段階）。
    # トレイを作るところまでは一瞬で着く。そこで落ちるものをここで拾う。
    LAUNCH_SETTLE = 2.seconds

    def initialize
      # ログを最初に立てる。
      # 配布物はコンソールを持たないため、ここから下で落ちたものは
      # ファイルへ書けなければどこにも残らない（issue #19）。
      # 読み込んだ設定のレベルへは load_config が改めて差し替える。
      @log_backend = Runtime::DailyFileBackend.new(Runtime::Paths.log_directory)
      Runtime::Logging.setup(@log_backend)

      @icons = Runtime::IconRepository.new
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
      # 設定へ書けなかった SteamVR の記録。書ける機会に書き直すために持つ。
      @steamvr_record_pending = nil.as({Bool, String}?)
      # 設定を書く役目を別のプロセスへ渡したか（issue #10 第 2 段階）。
      # 渡した後は書かない。同じ一時ファイルを 2 つのプロセスが使うことになる。
      @config_handed_over = false
      # 置き換えに失敗して実行ファイルが正規のパスに無いか（issue #10 第 2 段階）。
      # 復旧は利用者が手で行うため、常駐している間は下がらない。
      @update_broken = false
      # その旨を知らせ済みか。起動時に起きた場合はトレイがまだ無いので、後で知らせ直す。
      @update_broken_notified = false
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
      # 確認と取得は同じ境界を使う。相手は同じ GitHub である。
      update_repository = Update::GitHubRepository.new("KxNotifyUtils/#{VERSION}")
      @update = Update::Usecase.new(update_repository)
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
      # 知らせた版を設定へ書けていないか。書けた機会に書き直すために持つ。
      @update_record_pending = false
      # 取得と置き換え（issue #10 第 2 段階）。
      @installer = Update::Installer.new(
        update_repository,
        VERSION,
        Runtime::Paths.executable_path,
        Runtime::Paths.staged_executable_path,
        Runtime::Paths.previous_executable_path,
      )
      # 取得が走っている間か。押し直しで二重に取りに行かないために持つ。
      @update_downloading = false
      # 取得して検証まで済んだ版のタグ。表示と適用の判断に使う。
      @update_staged_tag = nil.as(String?)
      # 覚えてある結末がどのチャンネルのものか。今の設定と突き合わせるために持つ。
      @update_last_channel = nil.as(String?)
      @scheduler = Runtime::Scheduler.new(@relay, @steamvr, @errors)
      @settings_window = nil.as(Runtime::SettingsWindow?)
      @stopping = false
    end

    def run : Nil
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
      # 置き換えたときに残る古い実行ファイルは、次の起動、つまりここで消す。
      @installer.discard_previous
      # 取得の途中で終了した場合、片方だけが残る。ここで片付ける。
      @installer.discard_incomplete
      register_validators
      load_config

      # 取得しておいた更新があれば、ここで置き換えて新しい exe へ渡す（issue #10 第 2 段階）。
      #
      # 多重起動の抑止より後に置く。既に常駐しているプロセスがある状態で置き換えると、
      # 起動した新しい側が抑止に当たって即座に終わり、置き換えだけが済んだ形になる。
      # 抑止を通ってから、ミューテックスを手放して渡す。
      #
      # 設定を読んだ後に置く。取得しておいたものが今のチャンネルの対象かを見るためである。
      # 取得と置き換えの間には、設定を変えて再起動するだけの間がある。
      # トレイと設定を持っていても退避の妨げにはならない。どちらもファイルを開いたままにしない。
      return if hand_over_to_staged.finished?

      # 置き換えに失敗して実行ファイルが無いままなら、ここで知らせる。
      notify_update_broken
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
        Runtime::Win32.acquire_single_instance(SINGLE_INSTANCE_NAME)
      {% else %}
        true
      {% end %}
    end

    # 置き換えのために手放した抑止を取り直す。
    # 手放した後で新しい exe を起動できなかった場合に呼ぶ。
    # 取り直せたかを返す。取れなければ別のプロセスが常駐に入っている。
    private def reacquire_single_instance : Bool
      {% if flag?(:windows) %}
        Runtime::Win32.acquire_single_instance(SINGLE_INSTANCE_NAME)
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
        update_action: -> { update_action_label },
      )
      window.on_request_steamvr_register = -> { register_steamvr }
      window.on_request_steamvr_unregister = -> { unregister_steamvr }
      window.on_open_notification_settings = -> { open_notification_settings }
      window.on_request_update_action = -> { request_update_action }
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
    #
    # 逆に、切っている間はチャンネルを変えても確かめ直さない。
    # 「こちらから見に行かない」という指定であり、選択を変えたことは
    # それ自体では確認の要求ではないためである。
    # このとき情報タブは別のチャンネルの結果を出さず、確認が無効である旨を表示する。
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
          # 見つけた版はトレイの項目を変える。確認はファイバで進むため、
          # ここで写し直さないと、次に何かが状態を触るまで「更新を取得する」が出ない。
          update_tray_state
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
        # 取得できるかどうかで案内を分ける。
        # アセットが無いか digest が付いていないリリースでは取得の項目を出さないため、
        # 「取得できる」と書くと、押す先の無い案内になる。
        body = release.asset ? "notify.update_available.body" : "notify.update_available.body_release_page"
        shown = @errors.notify(
          Runtime::I18n.t("notify.update_available.title"),
          Runtime::I18n.t(body, {"version" => release.tag}),
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
      in .incomplete?
        # 自動の確認は黙る。押されたときだけ、言い切れないことを返す。
        return false unless manual
        @errors.notify(
          Runtime::I18n.t("notify.update_unsure.title"),
          Runtime::I18n.t("notify.update_unsure.body"),
        )
      in .unknown?
        # 手元ビルドでは比べる相手が無い。押しても何も言わない。
        Log.info { "実行中の版を比べられないため確認しない: #{VERSION}" }
        false
      end
    end

    # 知らせた版を設定へ残す。
    # 本体は SteamVR の自動起動で立ち上がるため、覚えておかないと
    # VR を始めるたびに同じ更新のバルーンが出る。
    #
    # 書けなかった場合は覚えておき、後で書き直す。
    # 知らせたことはメモリ上では記録済みであり、以後の確認は抑止される。
    # ここで諦めると、利用者が設定を直しても書かれないまま次の起動を迎える。
    private def remember_notified_update : Nil
      tag = @update.notified_tag
      if tag.empty?
        @update_record_pending = false
        return
      end

      # 設定を書く役目を渡した後は書かない。常駐している側と重なる。
      #
      # ただし保留には残す。知らせたことはメモリ上で記録済みであり、
      # ここで落とすと、渡しに失敗して常駐を続けた場合に以後の確認が抑止され、
      # ディスクへも残らないまま次の起動で同じ版をまた知らせることになる。
      if @config_handed_over
        @update_record_pending = true
        return
      end

      # 見送った理由は record が記録する。
      @update_record_pending = !@config.record(&.with_update_notified(tag))
    end

    # 見つけた版を先に見る。
    # check_enabled が false でも手動の確認はできるため、
    # 無効の表示を先に返すと、見つけた版とリリースページのボタンだけが出て文言が食い違う。
    private def update_status_label : String
      settings = @config.current.update

      # 実行ファイルが無い状態を先に出す。
      # 取得したものは残っているが、置き換えは進まない。
      # 手で戻すまで更新は止まっており、「次の起動で置き換わる」とは書けない。
      return Runtime::I18n.t("settings.about.update_broken") if @update_broken

      # 取得の進み具合を先に見る。
      # ここまで来ていれば、新しい版があることは利用者に伝わっている。
      if tag = @update_staged_tag
        return Runtime::I18n.t("settings.about.update_staged", {"version" => tag})
      end
      return Runtime::I18n.t("settings.about.update_downloading") if @update_downloading

      if release = @update.available(settings.channel)
        return Runtime::I18n.t("settings.about.update_available", {"version" => release.tag})
      end
      if @update.checked?(settings.channel)
        # 集めきれていない確認では「最新である」と言い切らない。
        return Runtime::I18n.t("settings.about.update_unsure") unless @update.complete?
        return Runtime::I18n.t("settings.about.update_latest")
      end
      return Runtime::I18n.t("settings.about.update_disabled") unless settings.check_enabled

      Runtime::I18n.t("settings.about.update_unchecked")
    end

    # 引き渡しの結末。
    #
    # 真偽で返していたが、それでは 3 つの失敗が同じ「偽」に潰れる。
    # 置き換えは済んでいるのに「取得し直す」と案内したり、
    # 復旧の案内を出した直後に、無効化した操作を勧めたりすることになる。
    enum HandOver
      # 取得しておいたものが無く、何もしなかった。
      None
      # 置き換えて新しい実行ファイルへ渡した。呼び出し側は終わる。
      Handed
      # 置き換えは済んだが起動できなかった。次の起動から新しい版になる。
      Replaced
      # 置き換えに失敗した。取得しておいたものは捨ててある。取り直せる。
      Failed
      # 退避を戻せなかった。実行ファイルが正規のパスに無い。
      Broken
      # 書き切れていない記録があるため見送った。取得しておいたものは残っている。
      Postponed
      # 抑止を取り直せず、別のプロセスが常駐に入った。このプロセスは終わる。
      Superseded

      # このプロセスが常駐へ進まず終わるべきか。
      def finished? : Bool
        handed? || superseded?
      end
    end

    # 取得しておいた更新を置き換えて、新しい実行ファイルへ渡す。
    #
    # 結末を返す。呼び出し側は自分の終わり方と、利用者への伝え方を決める。
    # 起動時は常駐に入らずそのまま終わり、常駐中は主ループを抜ける。
    #
    # ミューテックスは置き換えが済んでから手放す。
    # 握ったまま起動すると、新しい側が「既に起動している」と判断して終わってしまう。
    # 一方、置き換えの前に手放すと、置き換えに失敗したときに抑止だけが解けた状態が残る。
    private def hand_over_to_staged : HandOver
      staged = @installer.staged(@config.current.update.channel)
      return HandOver::None unless staged

      # 保留している記録は、置き換えより前に書き切る。
      #
      # 渡した後は、子が起動の途中で SteamVR の同期から設定を書き始める。
      # こちらの終了処理にも flush_records があり、そちらと重なると、
      # 同じ config.json.tmp を 2 つのプロセスが使うことになる。
      # 書きかけが混ざったものがそのまま設定として置かれる。
      retry_records

      # 書き切れなかった記録を抱えたまま渡さない。
      #
      # 渡した後はこちらが書かないため、その記録は失われる。
      # 登録解除の記録であれば、子はディスクの古い「登録済み」を読んで自動起動を戻す。
      #
      # 判定は置き換えより前に行う。後に置くと、実行ファイルは入れ替わり
      # 取得しておいたものも消えた後で「適用しなかった」と伝えることになる。
      if records_pending?
        Log.error { "保留している記録を書き切れないため置き換えを見送る" }
        return HandOver::Postponed
      end

      return HandOver::Failed unless @installer.apply(staged)

      # ここから先は設定を書かない。
      #
      # 待ちの間も、このプロセスのファイバは進む。起動時の更新の確認がこれにあたり、
      # 新しい版を見つけて知らせると、知らせた版の記録を設定へ書きに行く。
      # 子はその頃には起動して SteamVR の同期から設定を書き始めており、
      # 同じ config.json.tmp を 2 つのプロセスが使うことになる。
      @config_handed_over = true

      Runtime::Win32.release_single_instance
      if launch_replacement
        Log.info { "置き換えた実行ファイルへ渡した: #{staged.tag}" }
        return HandOver::Handed
      end

      # 起動できなかった。置き換えそのものは済んでいるので、
      # 次に起動されるのは新しい実行ファイルである。壊れた状態は残らない。
      # 抑止だけが解けたまま常駐を続けるわけにはいかないので取り直す。
      # 抑止を取り直せなければ、手放した隙に別のプロセスが常駐へ入っている。
      # そのまま続けると、同じ通知を 2 つのプロセスが中継することになる。
      # 抑止そのものが避けようとしている状態であり、こちらが引く。
      unless reacquire_single_instance
        # 常駐は別のプロセスのものになった。設定を書く役目もそちらへ渡ったままにする。
        Log.error { "抑止を取り直せなかった。別のプロセスが常駐しているため、こちらは終わる" }
        return HandOver::Superseded
      end

      # 常駐を続ける。子は落ちているので、設定を書く役目も戻る。
      @config_handed_over = false
      Log.error { "置き換えた実行ファイルを起動できなかった。次の起動から新しい版になる" }
      HandOver::Replaced
    rescue exception : Update::Installer::RollbackFailed
      # 正規のパスに実行ファイルが無い。取得しておいたものは捨てない。
      # 捨てると復旧の材料が .old だけになり、そちらも戻せなかったからここへ来ている。
      # 常駐はメモリ上で続くが、次の起動には実行ファイルが要る。利用者へ伝える。
      Log.error(exception: exception) { "置き換えに失敗し、退避した実行ファイルも戻せなかった" }
      @update_broken = true
      notify_update_broken
      HandOver::Broken
    rescue exception
      # 置き換えに失敗しても常駐は続ける。
      # 退避したものは Installer が戻しており、実行ファイルは元のままである。
      # 取得しておいたものは捨てる。同じものでまた失敗するだけである。
      Log.error(exception: exception) { "取得しておいた更新を適用できなかった" }
      @installer.discard
      HandOver::Failed
    end

    # 実行ファイルが正規のパスに無いことを利用者へ伝える。
    #
    # 起動時に起きた場合、この時点ではトレイも言語の設定もまだ無い。
    # 印だけ立てておき、設定を読んだ後に呼び直す。
    # 手で戻してもらう案内であり、選んだ言語で出す必要がある。
    private def notify_update_broken : Nil
      return unless @update_broken
      return if @update_broken_notified
      return unless @errors.notify(
                      Runtime::I18n.t("notify.update_broken.title"),
                      Runtime::I18n.t("notify.update_broken.body"),
                    )

      @update_broken_notified = true
    end

    # 利用者の操作で、その場で置き換えて入れ替わる。
    #
    # 押した人へは結末に合うものだけを返す。
    # 置き換えが済んでいるのに取り直しを勧めたり、
    # 無効にした操作を勧めたりすると、その場で確かめようがない。
    private def apply_update_now : Nil
      if @update_broken
        Log.info { "実行ファイルが正規のパスに無いため適用しない" }
        notify_update_broken
        return
      end

      # 適用は再起動を伴う。設定ウィンドウに未保存の編集があれば、先に知らせて止める。
      # 通常の終了では警告しているのに、更新の再起動だけ黙って捨てるわけにはいかない。
      # トレイから押した場合も同じ経路を通る。
      return if @settings_window.try(&.warn_if_unsaved?)

      case hand_over_to_staged
      in .handed?, .superseded?
        @stopping = true
      in .replaced?
        # 置き換えは済んでいる。起動し直せなかっただけであり、取り直す必要は無い。
        @errors.notify(
          Runtime::I18n.t("notify.update_relaunch_failed.title"),
          Runtime::I18n.t("notify.update_relaunch_failed.body"),
        )
      in .failed?
        @errors.notify(
          Runtime::I18n.t("notify.update_apply_failed.title"),
          Runtime::I18n.t("notify.update_apply_failed.body"),
        )
      in .broken?
        # 復旧の案内は hand_over_to_staged が出している。重ねない。
      in .postponed?
        @errors.notify(
          Runtime::I18n.t("notify.update_postponed.title"),
          Runtime::I18n.t("notify.update_postponed.body"),
        )
      in .none?
        Log.info { "取得しておいた更新が無いため適用しない" }
      end

      @update_staged_tag = @installer.staged(@config.current.update.channel).try(&.tag)
      update_tray_state
    end

    # 置き換えた実行ファイルを起動し、すぐに落ちなかったことまでを見る。
    #
    # 起動そのものが通っても、新しい側がトレイを作れないなどで run の途中で終わることがある。
    # そこでこちらも終わると、常駐するプロセスが 1 つも残らない。
    # 落ちていれば偽を返し、呼び出し側が抑止を取り直して常駐を続ける。
    #
    # 見られるのはここまでである。新しい側が常駐へ入るのは SteamVR の初期化の後であり、
    # あれは VR を立ち上げることもあって数秒では終わらない。
    # そこまで見届けるには準備完了を伝え合う仕組みが要るが、
    # この待ちで拾えるのはトレイの失敗のような、常駐に入る前の早い失敗である。
    private def launch_replacement : Bool
      process = Process.new(Runtime::Paths.executable_path, [] of String)
      sleep LAUNCH_SETTLE
      return true unless process.terminated?

      Log.error { "置き換えた実行ファイルが起動の直後に終わった" }
      false
    rescue exception
      Log.error(exception: exception) { "置き換えた実行ファイルを起動できなかった" }
      false
    end

    # 見つけている版のアセットを取得して、次の起動に備える。
    #
    # 取得は利用者が押したときだけ行う。数 MB を黙って運ばない。
    # 待ちは別のファイバで行う。主ループの中で待つと中継も接続維持も止まる。
    private def download_update : Nil
      return if @update_downloading

      channel = @config.current.update.channel
      release = @update.available(channel)
      unless release
        Log.info { "取得の対象になる版が見つかっていない" }
        return
      end

      unless release.asset
        @errors.notify(
          Runtime::I18n.t("notify.update_no_asset.title"),
          Runtime::I18n.t("notify.update_no_asset.body"),
        )
        return
      end

      @update_downloading = true
      update_tray_state
      @errors.notify(
        Runtime::I18n.t("notify.update_downloading.title"),
        Runtime::I18n.t("notify.update_downloading.body", {"version" => release.tag}),
      )

      spawn do
        begin
          if @installer.download(release)
            # 取得の最中にチャンネルが変わっていないかを見る。
            #
            # 変わっていれば、取ってきたのは今の設定に無い版である。
            # 置き換えは次の起動で走るため、そのまま残すと、stable を選び直した後に
            # プレリリースが入る。実行中より新しいかどうかでは、これを止められない。
            if channel == @config.current.update.channel
              @update_staged_tag = release.tag
              @errors.notify(
                Runtime::I18n.t("notify.update_downloaded.title"),
                Runtime::I18n.t("notify.update_downloaded.body", {"version" => release.tag}),
              )
            else
              Log.info do
                "取得の最中にチャンネルが変わったため取得したものを捨てる: " \
                "#{release.tag}（#{channel} → #{@config.current.update.channel}）"
              end
              @installer.discard
              @update_staged_tag = nil
            end
          end
        rescue exception
          # 取ってきたものは Installer が捨てている。押し直せば取り直せる。
          Log.error(exception: exception) { Runtime::I18n.log_text("error.update_download") }
          @errors.notify(
            Runtime::I18n.t("notify.update_download_failed.title"),
            Runtime::I18n.t("notify.update_download_failed.body"),
          )
        ensure
          @update_downloading = false
          update_tray_state
        end
      end
    end

    # 情報タブのボタンに出す見出しと、押せるかどうか。
    #
    # 押せないときも見出しは返す。隠して出し直すと、
    # 押そうとした瞬間にボタンの位置が動く。
    private def update_action_label : {String, Bool}
      case update_progress
      in .available?
        {Runtime::I18n.t("settings.about.update_download"), true}
      in .staged?
        {Runtime::I18n.t("settings.about.update_apply"), true}
      in .downloading?
        # 取得の最中は押せない。押しても何も起きないものを押せるように見せない。
        {Runtime::I18n.t("settings.about.update_downloading"), false}
      in .none?
        {Runtime::I18n.t("settings.about.update_download"), false}
      end
    end

    # 情報タブのボタンを押したときの動作。見出しと同じ判断で選ぶ。
    private def request_update_action : Nil
      case update_progress
      in .available?
        download_update
      in .staged?
        apply_update_now
      in .downloading?, .none?
        # 押せない状態のはずなので何もしない。
      end
    end

    # トレイと情報タブに出す、更新の進み具合。
    private def update_progress : Runtime::Tray::UpdateState
      # 実行ファイルが無い間は何も出さない。
      # 取得済みは残っているが、もう一度適用させると apply の先頭で
      # 退避しておいた .old を消すことになり、復旧の材料を両方とも失う。
      return Runtime::Tray::UpdateState::None if @update_broken
      return Runtime::Tray::UpdateState::Downloading if @update_downloading
      return Runtime::Tray::UpdateState::Staged if @update_staged_tag
      release = @update.available(@config.current.update.channel)
      return Runtime::Tray::UpdateState::Available if release && release.asset

      Runtime::Tray::UpdateState::None
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
      record_steamvr(section.auto_launch_registered, section.last_exe_path)
    end

    private def register_steamvr : Nil
      @errors.guard("error.steamvr_register") do
        next unless @steamvr.register
        record_steamvr(true, Runtime::Paths.executable_path)
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
        record_steamvr(false, "")
        update_tray_state

        if result.auto_launch_only?
          @errors.notify(
            Runtime::I18n.t("notify.steamvr_unregister_partial.title"),
            Runtime::I18n.t("notify.steamvr_unregister_partial.body"),
          )
        end
      end
    end

    # SteamVR の決着を設定へ書き戻す。
    #
    # 書けなかった場合は内容を覚えておき、後で書き直す。
    # 記録そのものは record が動作へ反映しているため、
    # 常駐している間は保留のままでも表示や再試行の判断は正しい。
    # 落とすと次回の起動でディスク側の古い決着を読むことになり、
    # 登録を解除した直後であれば、同期がそれを登録の消失と読んで有効に戻す。
    #
    # 自動起動の決着（auto_launch_configured）は、この経路ではつねに真である。
    # 登録も解除も同期も、SteamVR 側の操作が済んだ後にだけここへ来る。
    private def record_steamvr(registered : Bool, exe_path : String) : Nil
      # 設定を書く役目を渡した後は書かない。常駐している側と重なる。
      #
      # ただし保留には残す。渡しに失敗して常駐を続けた場合、
      # ここで落とすと決着がディスクへ残らないまま次の起動を迎える。
      if @config_handed_over
        @steamvr_record_pending = {registered, exe_path}
        return
      end

      if @config.record(&.with_steamvr(registered, exe_path))
        @steamvr_record_pending = nil
        return
      end

      # 見送った理由は record が記録する。
      @steamvr_record_pending = {registered, exe_path}
    end

    # 書けなかった記録を書き直す。
    #
    # SteamVR 側の操作はやり直さない。登録も解除も済んでおり、
    # 残っているのは決着を設定へ残すことだけである。
    # 書けなかった原因は外部の編集や一時的な書き込みの失敗であり、
    # 利用者が直したり、編集が終わったりすれば次の機会に書ける。
    # 書き切れていない記録があるか。
    private def records_pending? : Bool
      !@steamvr_record_pending.nil? || @update_record_pending
    end

    private def retry_records : Nil
      if pending = @steamvr_record_pending
        record_steamvr(pending[0], pending[1])
      end

      remember_notified_update if @update_record_pending
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
      in .download_update?
        download_update
      in .apply_update?
        apply_update_now
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
      @tray.update_state = update_progress
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
        # メニューから終わりを選ばれた後に 1 拍を回さない。
        # 更新の適用がこれにあたり、この拍で中継すると、
        # 既に常駐へ入っている子と同じ通知を 2 つのプロセスが送る。
        break if @stopping
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
      retry_records if @scheduler.retry_record?
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

    # 書けていない記録を終了の前に書き切る。
    #
    # 周期の書き直しは 60 秒ごとであり、その間に終了されると記録はメモリごと消える。
    # 登録を解除した記録であれば、次の起動でディスク側の古い「登録済み」を読んだ
    # 同期が自動起動を有効に戻す。更新の通知であれば同じ版のバルーンがまた出る。
    #
    # 例外は握る。終了の途中であり、ここで抜けると残りの後始末が走らない。
    private def flush_records : Nil
      # 設定を書く役目を渡した後は書かない。
      # 渡す前に書き切ってあり、ここで書くと常駐している側と重なる。
      return if @config_handed_over

      retry_records
    rescue exception
      Log.error(exception: exception) { "終了時の記録の書き戻しに失敗した" }
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
      flush_records
      @sinks.each { |sink| sink.stop rescue nil }
      @win_source.stop rescue nil if @source_started
      @tray.stop rescue nil
      @openvr.close rescue nil
      UIng.uninit rescue nil
    end
  end
end

# 漏れた例外をログへ残してから終える。
#
# 配布物は /SUBSYSTEM:WINDOWS でリンクしており、コンソールを持たない（issue #19）。
# 標準出力と標準エラーは閉じたハンドルになるため、ここで漏れた例外はどこにも出ない。
# 囲わないと「起動したのに何も起こらない」だけが残り、原因を追う手掛かりが無くなる。
#
# ログの設定は Application の生成が最初に行う。生成の途中で落ちたものも残すためである。
begin
  KxNotifyUtils::Application.new.run
rescue exception
  # ログの設定より前で落ちた場合は、既定のバックエンドが閉じた標準エラーへ書こうとして
  # ここでも失敗する。そこまでは面倒を見ず、終了コードだけ残して終える。
  KxNotifyUtils::Log.fatal(exception: exception) { "起動を続けられないため終了する" } rescue nil
  exit 1
end
