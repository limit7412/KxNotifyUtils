require "json"

# ソース実装：システムヘルス。
#
# PC の計測値を監視し、障害の前兆を通知にするソースである。
# 特定の障害を検出する機能ではなく、「計測値」「しきい値」「継続時間」の組を規則として持つ。
# 規則の定義は本体に同梱し、しきい値などの数値は設定で変えられる。
#
# 知らせる相手は XSOverlay であり、GPU が止まった後の通知は HMD に出ない。
# そのため規則が扱うのは、止まる前に計測値へ表れる兆候に限る。
module SystemHealth
  SOURCE_ID = "system_health"

  # 通知の重さ。組み込みアイコンの選択に使う。
  enum Severity
    Default
    Warning
    Error

    def icon_name : String
      to_s.downcase
    end
  end

  # しきい値に対して、どちら側で条件が成り立つか。
  enum Direction
    # 値がしきい値以上のときに成り立つ（使用率など）。
    AtOrAbove
    # 値がしきい値以下のときに成り立つ（上限までの余裕など）。
    AtOrBelow
  end

  # 計測値の名前。取得元と規則はこの名前だけで結び付く。
  module Metric
    # 物理メモリの使用率（パーセント）。
    MEMORY_PHYSICAL_USAGE = "memory.physical_usage_percent"
  end

  # 同梱する規則の定義。
  #
  # 設定で変えられるのは数値と有効・無効であり、どの計測値をどの向きで見るかは変えられない。
  # 計測値の名前と向きまで設定に出すと、通知の文面を規則ごとに用意できなくなる。
  struct RuleDefinition
    getter id : String
    getter metric : String
    getter direction : Direction
    getter severity : Severity
    # しきい値の既定値と、設定で指定できる範囲。
    getter threshold : Float64
    getter threshold_range : Range(Float64, Float64)
    # 条件が続いてから発報するまでの秒数の既定値。
    getter for_s : Int32
    # 解除のしきい値を設定に書かなかったとき、発報のしきい値からどれだけ離すか。
    getter clear_margin : Float64
    # 再発報までの間隔の既定値。
    getter cooldown_s : Int32

    def initialize(
      @id : String,
      @metric : String,
      @direction : Direction,
      @severity : Severity,
      @threshold : Float64,
      @threshold_range : Range(Float64, Float64),
      @for_s : Int32,
      @clear_margin : Float64,
      @cooldown_s : Int32,
    )
    end

    # 解除のしきい値の既定値。発報のしきい値から、条件が成り立たない側へ離した値である。
    def default_clear_threshold(threshold : Float64) : Float64
      value = direction.at_or_above? ? threshold - @clear_margin : threshold + @clear_margin
      value.clamp(@threshold_range.begin, @threshold_range.end)
    end
  end

  # 同梱する規則。
  #
  # 数値は 1 台の PC の調査記録から決めた初期値である。
  # 物理メモリは、VR を長時間続けた PC で 32 GB が満杯になっていた記録に基づく。
  RULES = [
    RuleDefinition.new(
      id: "memory.physical_usage",
      metric: Metric::MEMORY_PHYSICAL_USAGE,
      direction: Direction::AtOrAbove,
      severity: Severity::Warning,
      threshold: 95.0,
      threshold_range: 1.0..100.0,
      for_s: 120,
      clear_margin: 5.0,
      cooldown_s: 600,
    ),
  ]

  # 取得元の識別子。providers の鍵に使う。
  KNOWN_PROVIDERS = %w[memory]

  def self.rule?(id : String) : RuleDefinition?
    RULES.find { |rule| rule.id == id }
  end

  # sources.system_health.alerts の 1 件。
  #
  # どの項目も省略でき、省略した項目は規則の既定値になる。
  # 既定値のまま使う利用者の設定を、同梱の既定値の見直しに追従させるためである。
  class AlertSettings
    include JSON::Serializable

    @[JSON::Field(emit_null: false)]
    property enabled : Bool?
    @[JSON::Field(emit_null: false)]
    property threshold : Float64?
    @[JSON::Field(emit_null: false)]
    property for_s : Int32?
    @[JSON::Field(emit_null: false)]
    property clear_threshold : Float64?
    @[JSON::Field(emit_null: false)]
    property cooldown_s : Int32?
    @[JSON::Field(emit_null: false)]
    property notify_clear : Bool?

    def initialize(
      @enabled : Bool? = nil,
      @threshold : Float64? = nil,
      @for_s : Int32? = nil,
      @clear_threshold : Float64? = nil,
      @cooldown_s : Int32? = nil,
      @notify_clear : Bool? = nil,
    )
    end
  end

  # 規則の定義に設定を重ねた、評価にそのまま使える形。
  struct Rule
    getter definition : RuleDefinition
    getter? enabled : Bool
    getter threshold : Float64
    getter for_s : Int32
    getter clear_threshold : Float64
    getter cooldown_s : Int32
    getter? notify_clear : Bool

    def initialize(@definition : RuleDefinition, overrides : AlertSettings? = nil)
      enabled = overrides.try(&.enabled)
      @enabled = enabled.nil? ? true : enabled
      @threshold = overrides.try(&.threshold) || @definition.threshold
      @for_s = overrides.try(&.for_s) || @definition.for_s
      @clear_threshold = overrides.try(&.clear_threshold) || @definition.default_clear_threshold(@threshold)
      @cooldown_s = overrides.try(&.cooldown_s) || @definition.cooldown_s
      @notify_clear = overrides.try(&.notify_clear) == true
    end

    def id : String
      @definition.id
    end

    # 発報の条件が成り立っているか。
    def satisfied?(value : Float64) : Bool
      @definition.direction.at_or_above? ? value >= @threshold : value <= @threshold
    end

    # 解除の条件が成り立っているか。
    def cleared?(value : Float64) : Bool
      @definition.direction.at_or_above? ? value <= @clear_threshold : value >= @clear_threshold
    end

    # 解除のしきい値が、発報のしきい値から見て条件の成り立たない側にあるか。
    # 逆側にあると、発報した値のままで解除の条件も成り立ち、発報と解除を繰り返す。
    def clear_threshold_consistent? : Bool
      @definition.direction.at_or_above? ? @clear_threshold <= @threshold : @clear_threshold >= @threshold
    end
  end

  # sources.system_health セクション。
  class Settings
    include JSON::Serializable

    DEFAULT_POLLING_INTERVAL_S = 1
    POLLING_INTERVAL_RANGE     = 1..60
    FOR_RANGE                  = 0..3600
    COOLDOWN_RANGE             = 0..86400

    # 既定では無効にしてある。
    # 同梱のしきい値は 1 台の PC の記録から決めた初期値であり、他の環境で通知が多すぎないかを
    # 確かめられていない。更新しただけの利用者に、頼んでいない通知を出すわけにはいかない。
    property enabled : Bool = false
    property polling_interval_s : Int32 = DEFAULT_POLLING_INTERVAL_S
    # 取得元ごとの有効と無効。書かれていない取得元は有効として扱う。
    property providers : Hash(String, Bool) = {} of String => Bool
    # 規則ごとの上書き。書かれていない規則は既定値で有効になる。
    #
    # 障害検知のサービスは「書かれていない id は無効」だが、ここは逆にしてある。
    # ソースを有効にするだけで、規則を 1 つずつ書き足さなくても同梱の規則がすべて動くようにする。
    property alerts : Hash(String, AlertSettings) = {} of String => AlertSettings

    def initialize
    end

    def self.from_section(section : JSON::Any?) : Settings
      return Settings.new if section.nil?
      Settings.from_json(section.to_json)
    end

    def provider_enabled?(id : String) : Bool
      @providers.fetch(id, true)
    end

    # 同梱の規則すべてに設定を重ねて返す。
    def rules : Array(Rule)
      RULES.map { |definition| Rule.new(definition, @alerts[definition.id]?) }
    end

    # 同梱されていない規則の id。入力の誤りか、別の版が書いた設定である。
    def unknown_alert_ids : Array(String)
      @alerts.keys.reject { |id| SystemHealth.rule?(id) }
    end

    def unknown_provider_ids : Array(String)
      @providers.keys.reject(&.in?(KNOWN_PROVIDERS))
    end

    # 設定 GUI と起動時の検証で使う。エラーメッセージの配列を返し、空なら妥当とみなす。
    #
    # 知らない規則と取得元は誤りにしない。
    # 規則を足した版が書いた設定を前の版で読むと、設定全体が読めない扱いになるためである。
    # 知らない id は読み飛ばし、ログに残す。
    def self.validate(section : JSON::Any?) : Array(String)
      errors = [] of String
      settings = begin
        from_section(section)
      rescue ex : JSON::Error
        return ["sources.system_health の書式が不正である: #{ex.message}"]
      end

      unless POLLING_INTERVAL_RANGE.includes?(settings.polling_interval_s)
        errors << "sources.system_health.polling_interval_s は " \
                  "#{POLLING_INTERVAL_RANGE.begin} から #{POLLING_INTERVAL_RANGE.end} の範囲で指定する"
      end

      settings.rules.each { |rule| validate_rule(rule, errors) }
      errors
    end

    private def self.validate_rule(rule : Rule, errors : Array(String)) : Nil
      key = "sources.system_health.alerts.#{rule.id}"
      range = rule.definition.threshold_range

      unless range.includes?(rule.threshold)
        errors << "#{key}.threshold は #{format(range.begin)} から #{format(range.end)} の範囲で指定する"
      end
      unless range.includes?(rule.clear_threshold)
        errors << "#{key}.clear_threshold は #{format(range.begin)} から #{format(range.end)} の範囲で指定する"
      end
      unless rule.clear_threshold_consistent?
        side = rule.definition.direction.at_or_above? ? "以下" : "以上"
        errors << "#{key}.clear_threshold は threshold #{side}で指定する"
      end
      unless FOR_RANGE.includes?(rule.for_s)
        errors << "#{key}.for_s は #{FOR_RANGE.begin} から #{FOR_RANGE.end} の範囲で指定する"
      end
      unless COOLDOWN_RANGE.includes?(rule.cooldown_s)
        errors << "#{key}.cooldown_s は #{COOLDOWN_RANGE.begin} から #{COOLDOWN_RANGE.end} の範囲で指定する"
      end
    end

    private def self.format(value : Float64) : String
      value == value.round ? value.to_i.to_s : value.to_s
    end
  end
end
