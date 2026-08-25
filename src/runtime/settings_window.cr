require "log"
require "uing"
require "../config/models"
require "../config/usecase"
require "../notify/usecase"
require "../steamvr/usecase"
require "../win_notification/models"
require "../xsoverlay/models"
require "./paths"

module Runtime
  # 設定編集ウィンドウ（仕様書 4.8 節）。
  #
  # 入力値の受け渡しと表示だけを行い、検証と保存と反映は config/usecase に任せる。
  # 編集は設定スナップショットの複製に対して行い、保存が通ったときだけ現在の設定と入れ替わる。
  class SettingsWindow
    Log = ::Log.for("runtime")

    REPOSITORY_URL = "https://github.com/limit7412/KxNotifyUtils"

    # サードパーティライセンス表記をビルド時に実行ファイルへ取り込む。
    # 配布物は exe 1 ファイルで、同梱の LICENSE ファイルが存在しないため、
    # この画面が利用者から見えるライセンス表記の一次的な置き場所になる。
    THIRD_PARTY_NOTICES = {{ read_file("#{__DIR__}/../../THIRD-PARTY-NOTICES.md") }}

    TIMEOUT_MODES = %w[dynamic fixed]
    FILTER_MODES  = %w[blacklist whitelist]
    TRANSPORTS    = %w[websocket udp]
    LOG_LEVELS    = %w[trace debug info notice warn error fatal none]

    # rules の 1 項目で上書きできるフィールドのうち、単独の値を持つもの。
    # どれも「上書きするか」のチェックと入力欄の組で編集するため、同じ形で扱う。
    RULE_FIELDS = %w[
      timeout_mode timeout max_body_length title_template icon opacity volume sound
    ]

    # dynamic_timeout は 4 つの係数をまとめた 1 つの値である。
    # 画面では係数ごとに編集し、1 つでも上書きされていれば、
    # 残りを既定の通知設定から埋めて 1 つの値として持たせる。
    DYNAMIC_TIMEOUT_FIELDS = %w[base reading_speed min max]

    # 画面に並べる上書き行。
    RULE_OVERRIDE_ROWS = RULE_FIELDS + DYNAMIC_TIMEOUT_FIELDS.map { |field| "dynamic_timeout.#{field}" }

    property on_request_steamvr_register : Proc(Nil) = -> { }
    property on_request_steamvr_unregister : Proc(Nil) = -> { }
    property on_open_notification_settings : Proc(Nil) = -> { }

    def initialize(
      @config : ::Config::Usecase,
      @relay : Notify::RelayUsecase,
      @version : String,
      @access_status : Proc(String) = -> { "不明" },
      @steamvr_status : Proc(String) = -> { "不明" },
    )
      @window = nil.as(UIng::Window?)
      @draft = @config.current.dup_snapshot
      @rules = [] of ::Config::Rule
      @selected_rule = -1
      @controls = {} of String => UIng::Entry
      @checks = {} of String => UIng::Checkbox
      @combos = {} of String => UIng::Combobox
      @spins = {} of String => UIng::Spinbox
      @rule_list = nil.as(UIng::Combobox?)
      @filter_apps = nil.as(UIng::MultilineEntry?)
      @observed = nil.as(UIng::Combobox?)
      @external_change_label = nil.as(UIng::Label?)
      @access_label = nil.as(UIng::Label?)
      @steamvr_label = nil.as(UIng::Label?)
      # 未保存の変更があるまま閉じようとしたことを覚えておく。
      # 一度警告を出し、続けてもう一度閉じる操作をしたときに破棄する。
      @close_warned = false
    end

    # トレイメニューから開く。既に開いていれば前面化するだけとする。
    def open : Nil
      if window = @window
        refresh_status
        window.show
        return
      end

      @close_warned = false
      @window = build_window
      reset_draft
      refresh_status
      @window.try(&.show)
    end

    # 下書きと入力欄を現在の設定へ戻す。
    # 開いたときと、未保存の変更を破棄して閉じたときに呼ぶ。
    private def reset_draft : Nil
      @draft = @config.current.dup_snapshot
      @rules = @draft.rules.map { |rule| ::Config::Rule.from_json(rule.to_json) }
      @selected_rule = @rules.empty? ? -1 : 0
      load_draft
      @external_change_label.try { |label| label.text = "" }
    end

    def open? : Bool
      !@window.nil?
    end

    # 外部エディタでの編集を取り込んだときに呼ぶ。
    # 編集中の内容は破棄せず、変更があったことだけを知らせて利用者に選ばせる。
    def notify_external_change : Nil
      return unless @window
      @external_change_label.try do |label|
        label.text = "設定ファイルが変更されています。編集中の内容を保存すると上書きされます。"
      end
    end

    private def build_window : UIng::Window
      window = UIng::Window.new("KxNotifyUtils の設定", 640, 560, false)
      window.margined = true

      root = UIng::Box.new(:vertical, padded: true)
      tab = UIng::Tab.new
      tab.append("全般", build_general_tab)
      tab.append("監視対象", build_sources_tab)
      tab.append("通知先", build_sinks_tab)
      tab.append("既定の通知設定", build_defaults_tab)
      tab.append("アプリ別ルール", build_rules_tab)
      tab.append("SteamVR", build_steamvr_tab)
      tab.append("情報", build_about_tab)
      tab.num_pages.times { |index| tab.set_margined(index, true) }
      root.append(tab, true)

      external_change_label = UIng::Label.new("")
      @external_change_label = external_change_label
      root.append(external_change_label, false)
      root.append(build_footer(window), false)

      window.child = root
      window.on_closing do
        request_close(window)
        false
      end
      window
    end

    private def build_footer(window : UIng::Window) : UIng::Box
      footer = UIng::Box.new(:horizontal, padded: true)

      test = UIng::Button.new("テスト通知を送信")
      test.on_clicked { send_test(window) }
      footer.append(test, false)

      spacer = UIng::Label.new("")
      footer.append(spacer, true)

      save = UIng::Button.new("保存")
      save.on_clicked { save(window) }
      footer.append(save, false)

      close = UIng::Button.new("閉じる")
      close.on_clicked { request_close(window) }
      footer.append(close, false)
      footer
    end

    private def build_general_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)
      form = UIng::Form.new(padded: true)
      form.append("ログレベル", combo("log_level", LOG_LEVELS), false)
      box.append(form, false)
      box
    end

    private def build_sources_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)

      group = UIng::Group.new("Windows 通知", margined: true)
      inner = UIng::Box.new(:vertical, padded: true)
      inner.append(check("sources.windows.enabled", "このソースを有効にする"), false)

      form = UIng::Form.new(padded: true)
      form.append("ポーリング間隔 (ms)", spin("sources.windows.polling_interval_ms", 100, 5000), false)
      inner.append(form, false)

      access_label = UIng::Label.new("通知アクセスの許可状態: 不明")
      @access_label = access_label
      inner.append(access_label, false)

      open_settings = UIng::Button.new("Windows の通知設定を開く")
      open_settings.on_clicked { @on_open_notification_settings.call }
      inner.append(open_settings, false)

      group.child = inner
      box.append(group, false)
      box
    end

    private def build_sinks_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)

      group = UIng::Group.new("XSOverlay", margined: true)
      inner = UIng::Box.new(:vertical, padded: true)
      inner.append(check("sinks.xsoverlay.enabled", "このシンクを有効にする"), false)

      form = UIng::Form.new(padded: true)
      form.append("送信経路", combo("sinks.xsoverlay.transport", TRANSPORTS), false)
      form.append("WebSocket ポート", spin("sinks.xsoverlay.websocket_port", 1, 65535), false)
      form.append("UDP ポート (レガシー)", spin("sinks.xsoverlay.udp_port", 1, 65535), false)
      inner.append(form, false)

      group.child = inner
      box.append(group, false)
      box
    end

    private def build_defaults_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)

      form = UIng::Form.new(padded: true)
      mode = combo("defaults.timeout_mode", TIMEOUT_MODES)
      mode.on_selected { |_index| update_timeout_inputs }
      form.append("表示時間の決め方", mode, false)
      form.append("固定の表示時間 (秒)", entry("defaults.timeout"), false)
      form.append("dynamic: 基準 (秒)", entry("defaults.dynamic_timeout.base"), false)
      form.append("dynamic: 読字速度 (文字/秒)", entry("defaults.dynamic_timeout.reading_speed"), false)
      form.append("dynamic: 下限 (秒)", entry("defaults.dynamic_timeout.min"), false)
      form.append("dynamic: 上限 (秒)", entry("defaults.dynamic_timeout.max"), false)
      form.append(
        "本文の最大文字数",
        spin("defaults.max_body_length", ::Config::MAX_BODY_LENGTH_RANGE.begin, ::Config::MAX_BODY_LENGTH_RANGE.end),
        false,
      )
      form.append("title テンプレート", entry("defaults.title_template"), false)
      form.append("アイコン", entry("defaults.icon"), false)
      form.append("透明度 (0.0 から 1.0)", entry("defaults.opacity"), false)
      form.append("音量 (0.0 から 1.0)", entry("defaults.volume"), false)
      form.append("通知音", entry("defaults.sound"), false)
      box.append(form, false)

      box.append(UIng::Label.new(
        "アイコンは app / default / warning / error か PNG のパスを指定する。" \
        "通知音は default / warning / error か音声ファイルのパスで、空欄はミュートになる。"), false)
      box
    end

    private def build_rules_tab : UIng::Box
      box = UIng::Box.new(:horizontal, padded: true)

      left = UIng::Box.new(:vertical, padded: true)
      left.append(UIng::Label.new("ルール（上にあるものが優先される）"), false)
      rule_list = UIng::Combobox.new
      @rule_list = rule_list
      rule_list.on_selected do |index|
        flush_rule_form
        @selected_rule = index
        load_rule_form
      end
      left.append(rule_list, false)

      buttons = UIng::Box.new(:horizontal, padded: true)
      buttons.append(button("追加") { add_rule }, false)
      buttons.append(button("削除") { remove_rule }, false)
      buttons.append(button("上へ") { move_rule(-1) }, false)
      buttons.append(button("下へ") { move_rule(1) }, false)
      left.append(buttons, false)

      left.append(UIng::Label.new("観測した app_id"), false)
      observed = UIng::Combobox.new
      @observed = observed
      left.append(observed, false)
      left.append(button("選択した app_id を条件にする") { apply_observed_app }, false)

      filter_group = UIng::Group.new("フィルタ", margined: true)
      filter_box = UIng::Box.new(:vertical, padded: true)
      filter_form = UIng::Form.new(padded: true)
      filter_form.append("判定", combo("filter.mode", FILTER_MODES), false)
      filter_box.append(filter_form, false)
      filter_box.append(UIng::Label.new("対象の app_id（1 行に 1 つ、前方一致）"), false)
      filter_apps = UIng::MultilineEntry.new
      @filter_apps = filter_apps
      filter_box.append(filter_apps, true)
      filter_group.child = filter_box
      left.append(filter_group, true)

      box.append(left, true)
      box.append(build_rule_form, true)
      box
    end

    private def build_rule_form : UIng::Box
      right = UIng::Box.new(:vertical, padded: true)
      right.append(UIng::Label.new("選択中のルール"), false)

      form = UIng::Form.new(padded: true)
      form.append("match_app_id（前方一致）", entry("rule.match_app_id"), false)
      right.append(form, false)

      right.append(UIng::Label.new("チェックを外した項目は既定の通知設定を継承する"), false)
      RULE_OVERRIDE_ROWS.each do |field|
        row = UIng::Box.new(:horizontal, padded: true)
        override = check("rule.override.#{field}", field)
        override.on_toggled { |_checked| update_rule_field_state(field) }
        row.append(override, false)
        row.append(entry("rule.#{field}"), true)
        right.append(row, false)
      end
      right
    end

    private def build_steamvr_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)
      steamvr_label = UIng::Label.new("登録状態: 不明")
      @steamvr_label = steamvr_label
      box.append(steamvr_label, false)

      buttons = UIng::Box.new(:horizontal, padded: true)
      buttons.append(button("自動起動を登録") { @on_request_steamvr_register.call; refresh_status }, false)
      buttons.append(button("自動起動を解除") { @on_request_steamvr_unregister.call; refresh_status }, false)
      box.append(buttons, false)

      box.append(UIng::Label.new(
        "実行ファイルを移動した場合は、次回の起動時に vrmanifest を作り直して登録し直す。"), false)
      box
    end

    private def build_about_tab : UIng::Box
      box = UIng::Box.new(:vertical, padded: true)
      box.append(UIng::Label.new("KxNotifyUtils #{@version}"), false)
      box.append(button("リポジトリを開く: #{REPOSITORY_URL}") { open_repository }, false)
      box.append(UIng::Label.new("サードパーティライセンス表記"), false)

      notices = UIng::MultilineEntry.new
      notices.text = THIRD_PARTY_NOTICES
      notices.read_only = true
      box.append(notices, true)
      box
    end

    # 編集中の下書きを画面へ流し込む。
    private def load_draft : Nil
      set_combo("log_level", LOG_LEVELS, @draft.log_level)

      windows = WinNotification::Settings.from_section(@draft.source(WinNotification::SOURCE_ID))
      set_check("sources.windows.enabled", windows.enabled)
      set_spin("sources.windows.polling_interval_ms", windows.polling_interval_ms)

      xsoverlay = XSOverlay::Settings.from_section(@draft.sink(XSOverlay::SINK_ID))
      set_check("sinks.xsoverlay.enabled", xsoverlay.enabled)
      set_combo("sinks.xsoverlay.transport", TRANSPORTS, xsoverlay.transport.to_s.downcase)
      set_spin("sinks.xsoverlay.websocket_port", xsoverlay.websocket_port)
      set_spin("sinks.xsoverlay.udp_port", xsoverlay.udp_port)

      defaults = @draft.defaults
      set_combo("defaults.timeout_mode", TIMEOUT_MODES, defaults.timeout_mode.to_s.downcase)
      set_text("defaults.timeout", defaults.timeout.to_s)
      set_text("defaults.dynamic_timeout.base", defaults.dynamic_timeout.base.to_s)
      set_text("defaults.dynamic_timeout.reading_speed", defaults.dynamic_timeout.reading_speed.to_s)
      set_text("defaults.dynamic_timeout.min", defaults.dynamic_timeout.min.to_s)
      set_text("defaults.dynamic_timeout.max", defaults.dynamic_timeout.max.to_s)
      set_spin("defaults.max_body_length", defaults.max_body_length)
      set_text("defaults.title_template", defaults.title_template)
      set_text("defaults.icon", defaults.icon)
      set_text("defaults.opacity", defaults.opacity.to_s)
      set_text("defaults.volume", defaults.volume.to_s)
      set_text("defaults.sound", defaults.sound)
      update_timeout_inputs

      set_combo("filter.mode", FILTER_MODES, @draft.filter.mode.to_s.downcase)
      @filter_apps.try { |control| control.text = @draft.filter.apps.join("\n") }

      reload_rule_list
      load_rule_form
      reload_observed_apps
    end

    private def reload_rule_list : Nil
      rule_list = @rule_list
      return unless rule_list

      rule_list.clear
      @rules.each_with_index do |rule, index|
        label = rule.match_app_id.empty? ? "(未設定)" : rule.match_app_id
        rule_list.append("#{index + 1}. #{label}")
      end
      rule_list.selected = @selected_rule if @selected_rule >= 0 && @selected_rule < @rules.size
    end

    private def reload_observed_apps : Nil
      observed = @observed
      return unless observed

      observed.clear
      @relay.observed_apps.to_a.sort_by(&.[0]).each do |app_id, app_name|
        observed.append("#{app_id} (#{app_name})")
      end
    end

    private def load_rule_form : Nil
      rule = current_rule
      set_text("rule.match_app_id", rule.try(&.match_app_id) || "")

      RULE_OVERRIDE_ROWS.each do |field|
        value = rule ? rule_field(rule, field) : nil
        set_check("rule.override.#{field}", !value.nil?)
        set_text("rule.#{field}", value || "")
        update_rule_field_state(field)
      end
    end

    # 画面の入力をルールへ書き戻す。選択の切り替えと保存の直前に呼ぶ。
    # errors を渡すと、数値として読めない入力をそこへ記録する。
    private def flush_rule_form(errors : Array(String)? = nil) : Nil
      rule = current_rule
      return unless rule

      rule.match_app_id = text("rule.match_app_id")
      RULE_FIELDS.each do |field|
        value = checked?("rule.override.#{field}") ? text("rule.#{field}") : nil
        assign_rule_field(rule, field, value, errors)
      end
      assign_dynamic_timeout(rule, errors)
    end

    # 係数を 1 つでも上書きしていれば dynamic_timeout 全体を持たせる。
    # 上書きしていない係数は既定の通知設定から埋める。
    private def assign_dynamic_timeout(rule : ::Config::Rule, errors : Array(String)?) : Nil
      overridden = DYNAMIC_TIMEOUT_FIELDS.any? { |field| checked?("rule.override.dynamic_timeout.#{field}") }
      unless overridden
        rule.dynamic_timeout = nil
        return
      end

      inherited = @draft.defaults.dynamic_timeout
      rule.dynamic_timeout = ::Config::DynamicTimeout.new(
        base: dynamic_timeout_value("base", inherited.base, errors),
        reading_speed: dynamic_timeout_value("reading_speed", inherited.reading_speed, errors),
        min: dynamic_timeout_value("min", inherited.min, errors),
        max: dynamic_timeout_value("max", inherited.max, errors),
      )
    end

    private def dynamic_timeout_value(field : String, inherited : Float64, errors : Array(String)?) : Float64
      return inherited unless checked?("rule.override.dynamic_timeout.#{field}")
      rule_float(text("rule.dynamic_timeout.#{field}"), "dynamic_timeout.#{field}", errors) || inherited
    end

    private def current_rule : ::Config::Rule?
      return nil if @selected_rule < 0 || @selected_rule >= @rules.size
      @rules[@selected_rule]
    end

    private def rule_field(rule : ::Config::Rule, field : String) : String?
      case field
      when "timeout_mode"    then rule.timeout_mode.try(&.to_s.downcase)
      when "timeout"         then rule.timeout.try(&.to_s)
      when "max_body_length" then rule.max_body_length.try(&.to_s)
      when "title_template"  then rule.title_template
      when "icon"            then rule.icon
      when "opacity"         then rule.opacity.try(&.to_s)
      when "volume"          then rule.volume.try(&.to_s)
      when "sound"           then rule.sound
      else                        nil
      end
    end

    # 入力欄の文字列をルールへ書き戻す。
    #
    # 数値として読めない入力を「上書きなし」として捨てるわけにはいかない。
    # 捨てると既定値を継承した有効な設定になり、検証を通って保存され、
    # 利用者が書いた値が黙って消えるためである。
    # 読めない入力は errors に残し、保存もテスト通知も行わない。
    private def assign_rule_field(
      rule : ::Config::Rule,
      field : String,
      value : String?,
      errors : Array(String)?,
    ) : Nil
      case field
      when "timeout_mode"
        rule.timeout_mode = value.try do |raw|
          mode = ::Config::TimeoutMode.parse?(raw)
          errors << "ルールの timeout_mode は #{TIMEOUT_MODES.join(" / ")} のいずれかで指定する" if mode.nil? && errors
          mode
        end
      when "timeout"
        rule.timeout = rule_float(value, "timeout", errors)
      when "max_body_length"
        rule.max_body_length = rule_integer(value, "max_body_length", errors)
      when "title_template"
        rule.title_template = value
      when "icon"
        rule.icon = value
      when "opacity"
        rule.opacity = rule_float(value, "opacity", errors)
      when "volume"
        rule.volume = rule_float(value, "volume", errors)
      when "sound"
        rule.sound = value
      end
    end

    private def rule_float(value : String?, field : String, errors : Array(String)?) : Float64?
      value.try do |raw|
        parsed = raw.to_f64?
        errors << "ルールの #{field} に数値以外が入っている: #{raw}" if parsed.nil? && errors
        parsed
      end
    end

    private def rule_integer(value : String?, field : String, errors : Array(String)?) : Int32?
      value.try do |raw|
        parsed = raw.to_i32?
        errors << "ルールの #{field} に整数以外が入っている: #{raw}" if parsed.nil? && errors
        parsed
      end
    end

    private def update_rule_field_state(field : String) : Nil
      control = @controls["rule.#{field}"]?
      return unless control
      checked?("rule.override.#{field}") ? control.enable : control.disable
    end

    # timeout_mode に応じて、使わないほうの入力欄を触れなくする。
    private def update_timeout_inputs : Nil
      dynamic = selected_value("defaults.timeout_mode", TIMEOUT_MODES) == "dynamic"
      %w[defaults.dynamic_timeout.base defaults.dynamic_timeout.reading_speed
        defaults.dynamic_timeout.min defaults.dynamic_timeout.max].each do |key|
        dynamic ? @controls[key].enable : @controls[key].disable
      end
      dynamic ? @controls["defaults.timeout"].disable : @controls["defaults.timeout"].enable
    end

    private def add_rule : Nil
      flush_rule_form
      @rules << ::Config::Rule.new("")
      @selected_rule = @rules.size - 1
      reload_rule_list
      load_rule_form
    end

    private def remove_rule : Nil
      return if @selected_rule < 0 || @selected_rule >= @rules.size
      @rules.delete_at(@selected_rule)
      @selected_rule = @rules.empty? ? -1 : Math.min(@selected_rule, @rules.size - 1)
      reload_rule_list
      load_rule_form
    end

    # 先勝ちマッチのため、並び順そのものが設定の意味を持つ。
    private def move_rule(offset : Int32) : Nil
      flush_rule_form
      target = @selected_rule + offset
      return if @selected_rule < 0 || target < 0 || target >= @rules.size

      @rules.swap(@selected_rule, target)
      @selected_rule = target
      reload_rule_list
      load_rule_form
    end

    private def apply_observed_app : Nil
      index = @observed.try(&.selected) || -1
      return if index < 0

      app_id = @relay.observed_apps.keys.sort[index]?
      return unless app_id
      set_text("rule.match_app_id", app_id)
    end

    private def open_repository : Nil
      {% if flag?(:windows) %}
        Win32.open_with_shell(REPOSITORY_URL)
      {% end %}
    end

    private def refresh_status : Nil
      return unless @window
      @access_label.try { |label| label.text = "通知アクセスの許可状態: #{@access_status.call}" }
      @steamvr_label.try { |label| label.text = "登録状態: #{@steamvr_status.call}" }
    end

    # 画面の入力から設定スナップショットを組み立てる。
    # 数値として読めない入力はここで拾い、保存も反映も行わない。
    private def collect : {::Config::Root?, Array(String)}
      errors = [] of String
      flush_rule_form(errors)

      root = @draft.dup_snapshot
      root.log_level = selected_value("log_level", LOG_LEVELS)

      root.sources = root.sources.dup
      root.sources[WinNotification::SOURCE_ID] = JSON.parse({
        "enabled"             => checked?("sources.windows.enabled"),
        "polling_interval_ms" => spin_value("sources.windows.polling_interval_ms"),
      }.to_json)

      root.sinks = root.sinks.dup
      root.sinks[XSOverlay::SINK_ID] = JSON.parse({
        "enabled"        => checked?("sinks.xsoverlay.enabled"),
        "transport"      => selected_value("sinks.xsoverlay.transport", TRANSPORTS),
        "websocket_port" => spin_value("sinks.xsoverlay.websocket_port"),
        "udp_port"       => spin_value("sinks.xsoverlay.udp_port"),
      }.to_json)

      defaults = root.defaults
      defaults.timeout_mode = ::Config::TimeoutMode.parse(selected_value("defaults.timeout_mode", TIMEOUT_MODES))
      defaults.timeout = number("defaults.timeout", "固定の表示時間", errors)
      defaults.dynamic_timeout = ::Config::DynamicTimeout.new(
        base: number("defaults.dynamic_timeout.base", "dynamic の基準", errors),
        reading_speed: number("defaults.dynamic_timeout.reading_speed", "dynamic の読字速度", errors),
        min: number("defaults.dynamic_timeout.min", "dynamic の下限", errors),
        max: number("defaults.dynamic_timeout.max", "dynamic の上限", errors),
      )
      defaults.max_body_length = spin_value("defaults.max_body_length")
      defaults.title_template = text("defaults.title_template")
      defaults.icon = text("defaults.icon")
      defaults.opacity = number("defaults.opacity", "透明度", errors)
      defaults.volume = number("defaults.volume", "音量", errors)
      defaults.sound = text("defaults.sound")

      root.filter.mode = ::Config::FilterMode.parse(selected_value("filter.mode", FILTER_MODES))
      root.filter.apps = (@filter_apps.try(&.text) || "").lines.map(&.strip).reject(&.empty?)
      root.rules = @rules.map { |rule| ::Config::Rule.from_json(rule.to_json) }

      # steamvr セクションはアプリが書き込む記録であり、画面では編集しない。
      # SteamVR タブのボタンで登録や解除を行うと現在の設定だけが変わるため、
      # 下書きの古い記録で上書きしないよう、保存の直前に最新のものへ差し替える。
      root.steamvr = ::Config::SteamVRSection.from_json(@config.current.steamvr.to_json)

      return {nil, errors} unless errors.empty?
      {root, errors}
    end

    private def save(window : UIng::Window) : Nil
      root, parse_errors = collect
      unless root
        window.msg_box_error("保存できない", parse_errors.join("\n"))
        return
      end

      errors = @config.save(root)
      if errors.empty?
        @draft = @config.current.dup_snapshot
        @close_warned = false
        @external_change_label.try { |label| label.text = "" }
        window.msg_box("保存した", "設定を保存し、動作に反映した。")
      else
        window.msg_box_error("保存できない", errors.map(&.to_s).join("\n"))
      end
    end

    # テスト通知は保存せず、編集中の既定の通知設定をそのまま使って送る。
    private def send_test(window : UIng::Window) : Nil
      root, parse_errors = collect
      unless root
        window.msg_box_error("テスト通知を送れない", parse_errors.join("\n"))
        return
      end
      @relay.send_test(root.defaults.to_resolved)
    end

    # 未保存の変更があるまま閉じようとしたときは、一度警告を出して操作をやり直させる。
    # libui-ng が持つのは確認のないメッセージ表示だけなので、
    # 「保存するか破棄するか」の選択は、警告のあとにもう一度閉じる操作をするかで表す。
    private def request_close(window : UIng::Window) : Nil
      root, _ = collect
      changed = root.nil? || root.to_json != @config.current.to_json

      if changed && !@close_warned
        @close_warned = true
        window.msg_box(
          "未保存の変更がある",
          "保存していない変更がある。破棄してよければもう一度「閉じる」を押す。" \
          "残す場合は「保存」を押す。",
        )
        return
      end

      # 破棄した内容をそのままにすると、次に開いたときに再び現れて保存できてしまう。
      # ウィンドウは作り直さず再表示するだけなので、ここで下書きと入力欄を戻す。
      reset_draft if changed
      @close_warned = false
      window.hide
    end

    # 以降は控えめな見た目の入力欄を作るための小道具である。

    private def entry(key : String) : UIng::Entry
      control = UIng::Entry.new
      control.on_changed { |_text| @close_warned = false }
      @controls[key] = control
      control
    end

    private def check(key : String, label : String) : UIng::Checkbox
      control = UIng::Checkbox.new(label)
      control.on_toggled { |_checked| @close_warned = false }
      @checks[key] = control
      control
    end

    private def combo(key : String, items : Array(String)) : UIng::Combobox
      control = UIng::Combobox.new
      items.each { |item| control.append(item) }
      control.selected = 0
      control.on_selected { |_index| @close_warned = false }
      @combos[key] = control
      control
    end

    private def spin(key : String, min : Int32, max : Int32) : UIng::Spinbox
      control = UIng::Spinbox.new(min, max)
      control.on_changed { |_value| @close_warned = false }
      @spins[key] = control
      control
    end

    private def button(label : String, &block : -> Nil) : UIng::Button
      control = UIng::Button.new(label)
      control.on_clicked { block.call }
      control
    end

    private def text(key : String) : String
      (@controls[key]?.try(&.text) || "").strip
    end

    private def set_text(key : String, value : String) : Nil
      @controls[key]?.try { |control| control.text = value }
    end

    private def checked?(key : String) : Bool
      @checks[key]?.try(&.checked?) || false
    end

    private def set_check(key : String, value : Bool) : Nil
      @checks[key]?.try { |control| control.checked = value }
    end

    private def selected_value(key : String, items : Array(String)) : String
      index = @combos[key]?.try(&.selected) || 0
      items[index]? || items.first
    end

    private def set_combo(key : String, items : Array(String), value : String) : Nil
      index = items.index(value) || 0
      @combos[key]?.try { |control| control.selected = index }
    end

    private def spin_value(key : String) : Int32
      @spins[key]?.try(&.value) || 0
    end

    private def set_spin(key : String, value : Int32) : Nil
      @spins[key]?.try { |control| control.value = value }
    end

    private def number(key : String, label : String, errors : Array(String)) : Float64
      raw = text(key)
      value = raw.to_f64?
      return value if value
      errors << "#{label} に数値以外が入っている: #{raw}"
      0.0
    end
  end
end
