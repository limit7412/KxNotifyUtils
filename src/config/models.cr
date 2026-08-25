require "json"

# 設定コンテキスト。
# 設定スキーマ（仕様書 5 章）の定義と、defaults と rules の継承解決を担う。
module Config
  # 表示時間の決め方（仕様書 4.3 節 手順 4）。
  enum TimeoutMode
    Fixed
    Dynamic
  end

  # フィルタの判定方向（仕様書 4.3 節 手順 1）。
  enum FilterMode
    Blacklist
    Whitelist
  end

  # dynamic モードでの表示時間の係数。
  struct DynamicTimeout
    include JSON::Serializable

    getter base : Float64
    getter reading_speed : Float64
    getter min : Float64
    getter max : Float64

    def initialize(@base = 2.0, @reading_speed = 12.0, @min = 3.0, @max = 15.0)
    end

    # 文字数から表示時間を求め、min と max でクランプする。
    def seconds_for(char_count : Int32) : Float64
      speed = @reading_speed <= 0.0 ? 1.0 : @reading_speed
      (@base + char_count / speed).clamp(@min, @max)
    end
  end

  # 本文の最大文字数として受け付ける範囲。
  # 設定編集ウィンドウの入力欄も同じ範囲を使う。
  MAX_BODY_LENGTH_RANGE = 0..5000

  # 通知の見た目と鳴り方を決める項目の集合。
  # defaults と rules はどちらもこの項目集合を持ち、rules 側は省略した項目を defaults から継承する。
  struct Resolved
    getter timeout_mode : TimeoutMode
    getter timeout : Float64
    getter dynamic_timeout : DynamicTimeout
    getter max_body_length : Int32
    getter title_template : String
    getter icon : String
    getter opacity : Float64
    getter volume : Float64
    getter sound : String

    def initialize(
      @timeout_mode : TimeoutMode,
      @timeout : Float64,
      @dynamic_timeout : DynamicTimeout,
      @max_body_length : Int32,
      @title_template : String,
      @icon : String,
      @opacity : Float64,
      @volume : Float64,
      @sound : String,
    )
    end
  end

  # defaults セクション。
  # 全項目に既定値を持ち、設定ファイルに書かれていない項目はその既定値になる。
  class Defaults
    include JSON::Serializable

    property timeout_mode : TimeoutMode = TimeoutMode::Dynamic
    property timeout : Float64 = 6.0
    property dynamic_timeout : DynamicTimeout = DynamicTimeout.new
    property max_body_length : Int32 = 200
    property title_template : String = "{app_name}: {title}"
    property icon : String = "app"
    property opacity : Float64 = 1.0
    property volume : Float64 = 0.5
    property sound : String = "default"

    def initialize
    end

    def to_resolved : Resolved
      Resolved.new(
        timeout_mode: @timeout_mode,
        timeout: @timeout,
        dynamic_timeout: @dynamic_timeout,
        max_body_length: @max_body_length,
        title_template: @title_template,
        icon: @icon,
        opacity: @opacity,
        volume: @volume,
        sound: @sound,
      )
    end
  end

  # rules の 1 項目。
  # 値を持つ項目だけが defaults を上書きし、nil の項目は defaults を継承する。
  class Rule
    include JSON::Serializable

    # マッチ条件は v1 では match_app_id のみとする。
    # ソース追加時に match_source を足せるよう、match_ プレフィックスを予約している（仕様書 5 章）。
    property match_app_id : String = ""

    property timeout_mode : TimeoutMode?
    property timeout : Float64?
    property dynamic_timeout : DynamicTimeout?
    property max_body_length : Int32?
    property title_template : String?
    property icon : String?
    property opacity : Float64?
    property volume : Float64?
    property sound : String?

    def initialize(@match_app_id : String = "")
    end

    def matches?(app_id : String) : Bool
      return false if @match_app_id.empty?
      app_id.starts_with?(@match_app_id)
    end

    def resolve(defaults : Defaults) : Resolved
      Resolved.new(
        timeout_mode: @timeout_mode || defaults.timeout_mode,
        timeout: @timeout || defaults.timeout,
        dynamic_timeout: @dynamic_timeout || defaults.dynamic_timeout,
        max_body_length: @max_body_length || defaults.max_body_length,
        title_template: @title_template || defaults.title_template,
        icon: @icon || defaults.icon,
        opacity: @opacity || defaults.opacity,
        volume: @volume || defaults.volume,
        sound: @sound || defaults.sound,
      )
    end
  end

  # filter セクション。
  class Filter
    include JSON::Serializable

    property mode : FilterMode = FilterMode::Blacklist
    property apps : Array(String) = [] of String

    def initialize
    end

    # app_id の前方一致で中継可否を決める。
    def allow?(app_id : String) : Bool
      matched = @apps.any? { |prefix| !prefix.empty? && app_id.starts_with?(prefix) }
      @mode.blacklist? ? !matched : matched
    end
  end

  # steamvr セクション。
  # どれもアプリが書き込む記録であり、利用者が編集する項目ではない。
  class SteamVRSection
    include JSON::Serializable

    property auto_launch_registered : Bool = false
    property last_exe_path : String = ""

    # 自動起動の登録について一度でも決着がついたか。
    # 初回の自動登録を「設定ファイルが無いこと」で判断すると、
    # SteamVR を起動していない初回実行で設定ファイルだけができた場合に、
    # 一度も登録しないまま二度と登録を試さなくなる。
    # 逆に登録状態だけを見ると、利用者が解除した後で毎回登録し直してしまう。
    # そのため「決着がついたか」を別に持つ。
    property auto_launch_configured : Bool = false

    def initialize
    end
  end

  # 設定ファイル全体。
  #
  # sources と sinks は識別子をキーにした生の JSON として保持する。
  # 各アダプタが自分のキーだけを自分の設定型へ読み替えるため、
  # ソースやシンクを追加しても既存キーの互換が保たれる（仕様書 5 章）。
  class Root
    include JSON::Serializable

    property sources : Hash(String, JSON::Any) = {} of String => JSON::Any
    property sinks : Hash(String, JSON::Any) = {} of String => JSON::Any
    property filter : Filter = Filter.new
    property defaults : Defaults = Defaults.new
    property rules : Array(Rule) = [] of Rule
    property steamvr : SteamVRSection = SteamVRSection.new
    property log_level : String = "info"

    def initialize
    end

    # 設定ファイルが存在しないときに書き出す初期設定。
    def self.default : Root
      root = Root.new
      root.sources = {
        "windows" => JSON.parse(%({"enabled": true, "polling_interval_ms": 500})),
      }
      root.sinks = {
        "xsoverlay" => JSON.parse(
          %({"enabled": true, "transport": "websocket", "websocket_port": 42070, "udp_port": 42069})),
      }
      root
    end

    # rules を上から順に評価し、最初にマッチしたルールを採用する。
    # マッチしない場合は defaults をそのまま使う（仕様書 4.3 節 手順 2）。
    def resolve_rule(app_id : String) : Resolved
      if rule = @rules.find(&.matches?(app_id))
        rule.resolve(@defaults)
      else
        @defaults.to_resolved
      end
    end

    def source(id : String) : JSON::Any?
      @sources[id]?
    end

    def sink(id : String) : JSON::Any?
      @sinks[id]?
    end

    # 設定スナップショットの複製。
    # 反映はスナップショットの差し替えで行うため、部分的な書き換えは複製に対して行う（仕様書 4.8.2 節）。
    def dup_snapshot : Root
      Root.from_json(to_json)
    end

    # SteamVR 登録の記録だけを差し替えた新しいスナップショットを返す。
    def with_steamvr(registered : Bool, exe_path : String, configured : Bool = true) : Root
      copy = dup_snapshot
      copy.steamvr.auto_launch_registered = registered
      copy.steamvr.last_exe_path = exe_path
      copy.steamvr.auto_launch_configured = configured
      copy
    end
  end
end
