require "./models"

module SystemHealth
  # 設定画面で編集する、規則 1 件ぶんの入力。
  #
  # 画面の部品から切り離してあるのは、設定との行き来を Windows の外で検証するためである。
  # しきい値は文字列で持つ。小数を書けるようにするためと、解除のしきい値の「空欄」を表すためである。
  struct AlertForm
    getter? enabled : Bool
    getter threshold : String
    getter clear_threshold : String
    getter secondary_threshold : String
    getter for_s : Int32
    getter cooldown_s : Int32
    getter? notify_clear : Bool

    def initialize(
      @enabled : Bool,
      @threshold : String,
      @clear_threshold : String,
      @secondary_threshold : String,
      @for_s : Int32,
      @cooldown_s : Int32,
      @notify_clear : Bool,
    )
    end

    # 設定から入力を作る。設定に書かれていない項目には、規則の既定値を入れる。
    #
    # 解除のしきい値だけは、書かれていなければ空欄にする。
    # 既定値はしきい値から決まるため、値を入れておくと、しきい値だけを変えたときに食い違う。
    def self.from(definition : RuleDefinition, overrides : AlertSettings?) : AlertForm
      rule = Rule.new(definition, overrides)
      adjustable = definition.threshold_adjustable?
      new(
        enabled: rule.enabled?,
        threshold: adjustable ? SystemHealth.format_number(rule.threshold) : "",
        clear_threshold: adjustable ? (overrides.try(&.clear_threshold).try { |value| SystemHealth.format_number(value) } || "") : "",
        secondary_threshold: rule.secondary_threshold.try { |value| SystemHealth.format_number(value) } || "",
        for_s: rule.for_s,
        cooldown_s: rule.cooldown_s,
        notify_clear: rule.notify_clear?,
      )
    end

    # 入力を設定へ戻す。数値として読めない入力は errors に残す。
    #
    # 設定に書かれていなかった項目は、入力が既定値のままなら書かないままにする。
    # 書くと値が固定され、同梱の既定値を見直した版へ更新しても追従しなくなる。
    # 画面に出していない項目（しきい値を変えられない規則のしきい値）は、前の設定を引き継ぐ。
    def to_settings(
      definition : RuleDefinition, previous : AlertSettings?, label : String, errors : Array(String),
    ) : AlertSettings
      adjustable = definition.threshold_adjustable?
      secondary = definition.secondary

      AlertSettings.new(
        enabled: keep(previous.try(&.enabled), @enabled, true),
        threshold: if adjustable
          parse(@threshold, label, errors).try { |value| keep(previous.try(&.threshold), value, definition.threshold) }
        else
          previous.try(&.threshold)
        end,
        for_s: keep(previous.try(&.for_s), @for_s, definition.for_s),
        clear_threshold: if adjustable
          @clear_threshold.strip.empty? ? nil : parse(@clear_threshold, label, errors)
        else
          previous.try(&.clear_threshold)
        end,
        secondary_threshold: if secondary
          parse(@secondary_threshold, label, errors).try do |value|
            keep(previous.try(&.secondary_threshold), value, secondary.threshold)
          end
        else
          previous.try(&.secondary_threshold)
        end,
        cooldown_s: keep(previous.try(&.cooldown_s), @cooldown_s, definition.cooldown_s),
        notify_clear: keep(previous.try(&.notify_clear), @notify_clear, false),
      )
    end

    private def keep(previous, value, default)
      previous.nil? && value == default ? nil : value
    end

    # NaN と無限大は受け付けない。設定は JSON へ書き出すため、通すと書き出しで例外になる。
    private def parse(raw : String, label : String, errors : Array(String)) : Float64?
      value = raw.strip.to_f64?
      return value if value && value.finite?
      errors << "#{label} には有限の数値を入れる: #{raw}"
      nil
    end
  end
end
