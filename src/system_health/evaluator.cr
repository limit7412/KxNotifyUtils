require "./models"

module SystemHealth
  # 規則の評価。
  #
  # 受け取るのは計測値の名前と値の対だけであり、値の取得元を知らない。
  # 取得元から切り離してあるため、状態の遷移を Windows の外でも検証できる。
  #
  # 各規則は 3 つの状態を持つ。
  #
  #   平常 → 条件が成り立つ → 継続の計測中 → 継続時間を満たす → 発報中
  #   継続の計測中 → 条件が外れる → 平常
  #   発報中 → 解除の条件が成り立つ → 平常
  #
  # 発報を知らせるのは、発報中へ移るときの 1 回だけである。
  # 解除には発報より緩いしきい値を使う。同じ値を使うと、しきい値の付近で値が上下するたびに
  # 発報と解除を繰り返す。
  class Evaluator
    enum Phase
      Normal
      Pending
      Firing
    end

    enum Kind
      Fired
      Cleared
    end

    # 状態が変わった規則 1 件。
    # value は変わった時点の主の計測値、samples はその時点の計測値すべてである。
    # 通知の文面に、判定に使った値以外（余裕で判定した規則の温度など）も載せるために持つ。
    record Transition, kind : Kind, rule : Rule, value : Float64, samples : Hash(String, Float64)

    private class State
      property phase : Phase = Phase::Normal
      # 条件が成り立ち始めた時刻。
      property since : Time::Span = Time::Span.zero
      # 直近に発報した時刻。再発報の間隔を数える起点である。
      property last_fired : Time::Span? = nil
    end

    def initialize
      @states = {} of String => State
    end

    # 状態をすべて捨てる。ソースを開始し直すときに呼ぶ。
    def reset : Nil
      @states.clear
    end

    # 継続の計測を打ち切る。規則の数値が変わったときに呼ぶ。
    #
    # 数え始めたのは変わる前の条件であり、その時間を変わった後の条件へ引き継ぐと、
    # 新しい条件が継続時間を満たしていないのに発報する。
    # 発報中の状態と直近の発報時刻は保つ。保たないと、数値を変えるたびに同じ通知が出直す。
    def restart_pending(rule_id : String) : Nil
      state = @states[rule_id]?
      state.phase = Phase::Normal if state && state.phase.pending?
    end

    def phase(rule_id : String) : Phase
      @states[rule_id]?.try(&.phase) || Phase::Normal
    end

    # 計測値を規則に当て、状態が変わった規則を返す。
    #
    # 時刻は単調時計で受け取る。壁時計では、時刻の修正で継続時間と再発報の間隔が狂う。
    def evaluate(rules : Array(Rule), samples : Hash(String, Float64), now : Time::Span) : Array(Transition)
      transitions = [] of Transition
      rules.each do |rule|
        # 無効にした規則の状態は捨てる。残すと、有効に戻したときに
        # 無効にする前の継続時間や発報中の状態を引き継ぐ。
        unless rule.enabled?
          @states.delete(rule.id)
          next
        end

        state = (@states[rule.id] ||= State.new)
        if transition = step(rule, state, samples, now)
          transitions << transition
        end
      end
      transitions
    end

    private def step(rule : Rule, state : State, samples : Hash(String, Float64), now : Time::Span) : Transition?
      value = samples[rule.definition.metric]?

      if state.phase.firing?
        # 値が取れない間は、解除されたとは言えない。発報中のまま保つ。
        return nil unless value && rule.cleared?(samples)
        state.phase = Phase::Normal
        return Transition.new(Kind::Cleared, rule, value, samples)
      end

      satisfied = rule.satisfied?(samples)
      if value.nil? || !satisfied
        # 条件が外れたか、値が取れず条件が続いているとは言えない。継続の計測は打ち切る。
        state.phase = Phase::Normal
        return nil
      end

      if state.phase.normal?
        state.phase = Phase::Pending
        state.since = now
      end
      # 継続時間が 0 の規則は、条件が成り立った周期のうちに発報する。
      fire_if_due(rule, state, value, samples, now)
    end

    # 継続時間を満たし、かつ前回の発報から間隔が空いていれば発報する。
    #
    # 間隔が空くまでは継続の計測中にとどめる。
    # 条件が続いたまま間隔が明ければ、その時点で発報する。
    private def fire_if_due(
      rule : Rule, state : State, value : Float64, samples : Hash(String, Float64), now : Time::Span,
    ) : Transition?
      return nil if now - state.since < rule.for_s.seconds
      if last = state.last_fired
        return nil if now - last < rule.cooldown_s.seconds
      end

      state.phase = Phase::Firing
      state.last_fired = now
      Transition.new(Kind::Fired, rule, value, samples)
    end
  end
end
