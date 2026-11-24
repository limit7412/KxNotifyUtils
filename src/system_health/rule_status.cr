require "./models"

module SystemHealth
  # 規則 1 件の、今の状態と計測値。設定画面の一覧に出す。
  #
  # 画面の部品と辞書から切り離してあるのは、状態の決め方を Windows の外で検証するためである。
  struct RuleStatus
    enum State
      # ソースが止まっている。
      Stopped
      # 規則が無効になっている。
      Disabled
      # 判定に要る計測値が取れていない。
      Unavailable
      # 条件が成り立っていない。
      Normal
      # 条件が成り立ち、継続時間を数えている。
      Pending
      # 条件は続いているが、前回の通知から再通知までの間隔が空いていない。
      Suppressed
      # 通知を出し、解除を待っている。
      Firing
    end

    # 値が取れなかった計測値の表記。
    UNKNOWN_VALUE = "-"

    getter rule : Rule
    getter state : State
    # 判定に使う主の計測値。取れていなければ nil である。
    getter value : Float64?
    # 2 つ目の条件の計測値。2 つ目の条件を持たない規則と、取れていない間は nil である。
    getter secondary_value : Float64?
    # 条件が続いた場合に通知が出るまでの秒数。数えている間だけ入る。
    getter remaining_s : Int32?

    def initialize(
      @rule : Rule,
      @state : State,
      @value : Float64? = nil,
      @secondary_value : Float64? = nil,
      @remaining_s : Int32? = nil,
    )
    end

    # 画面の文言へ埋める値。
    #
    # 計測値は小数 1 桁まで出す。整数へ丸めると、しきい値 95 に対する 94.6 が 95 と表示され、
    # 条件が成り立っていないのに成り立っているように読める。
    def placeholders : Hash(String, String)
      {
        "value"               => measured(@value),
        "threshold"           => SystemHealth.format_number(@rule.threshold),
        "clear_threshold"     => SystemHealth.format_number(@rule.clear_threshold),
        "secondary_value"     => measured(@secondary_value),
        "secondary_threshold" => @rule.secondary_threshold.try { |value| SystemHealth.format_number(value) } || UNKNOWN_VALUE,
        "remaining_s"         => @remaining_s.try(&.to_s) || UNKNOWN_VALUE,
      }
    end

    # 計測値が 0 か 1 の規則で、その値が立っているか。値が取れていなければ nil を返す。
    # こうした規則は数値ではなく「作動中」のような語で見せるため、画面はこちらを読む。
    def flag? : Bool?
      return nil if @rule.definition.threshold_adjustable?
      @value.try { |value| value >= @rule.threshold }
    end

    private def measured(value : Float64?) : String
      value.try { |number| SystemHealth.format_number(number.round(1)) } || UNKNOWN_VALUE
    end
  end
end
