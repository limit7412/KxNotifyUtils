require "../config/models"
require "../notify/repository"
require "./models"
require "./repository"

module Sleep
  # 睡眠中かを決める（issue #54）。
  #
  # 入力を合わせて 1 つの理由を返す。入力は、トレイから始める手動、スケジュール、OyasumiVR の 3 つである。
  # notify からは SleepGate として見え、中継を止めるかだけを問われる。
  #
  # 手動の状態と起きている間の上書きは設定ファイルに書かず、再起動で消える。
  # 睡眠中に再起動が起きるのは更新の適用くらいで、適用は手動の操作か次の起動に限られる。
  class Usecase < Notify::SleepGate
    # 設定スナップショットの sleep セクション。差し替えは代入 1 回で済む。
    property config : ::Config::SleepSection

    # 手動のおやすみモードが終わる時刻。始めていなければ nil である。
    getter manual_until : Time?

    # スケジュールの時間帯でも中継する期限。
    # 寝ている途中で起きて「おやすみモードを終了」を押したときに立つ。
    # その時間帯が終わる時刻を入れるので、次の晩の時間帯ではまた止まる。
    getter awake_until : Time?

    # OyasumiVR が睡眠モードを示していても中継するか。
    # 睡眠モードのまま「おやすみモードを終了」を押したときに立ち、睡眠モードが切れたら下りる。
    # OyasumiVR には終わる時刻が無いため、スケジュールと違って状態の変化で期限を決める。
    getter? awake_oyasumivr : Bool = false

    # 時計は差し替えられるようにしておく。
    # スケジュールも手動の期限も壁時計の時刻で決まり、テストで時刻を固定しないと境界を確かめられない。
    def initialize(
      @config : ::Config::SleepSection = ::Config::SleepSection.new,
      @clock : Proc(Time) = -> { Time.local },
      @oyasumivr : Signal? = nil,
    )
    end

    # 止めている理由。複数が成り立つときは Reason の並びで先のものを返す。
    def reason : Reason
      now = @clock.call
      # OyasumiVR は先に見る。上書きを下ろす機会を、手動やスケジュールで止めている間も逃さないためである。
      oyasumivr = oyasumivr_active?
      return Reason::Manual if manual_active?(now)
      return Reason::Schedule if schedule_active?(now)
      return Reason::OyasumiVR if oyasumivr
      Reason::None
    end

    def sleeping? : Bool
      !reason.none?
    end

    # おやすみモードを始める。
    #
    # 期限は、スケジュールが有効なら次の終了時刻、無効なら設定した時間の後とする。
    # 起きるつもりの時刻がスケジュールに書いてあるなら、それに揃えるほうが利用者の意図に近い。
    # 起きている間の上書きは消す。寝ると決めた操作のほうを優先する。
    def start_manual : Time
      now = @clock.call
      schedule = @config.schedule
      ends = (schedule.enabled ? schedule.next_end(now) : nil) || now + @config.manual_duration_h.hours
      @manual_until = ends
      @awake_until = nil
      @awake_oyasumivr = false
      ends
    end

    # おやすみモードを終える。トレイの「おやすみモードを終了」から呼ぶ。
    #
    # 手動の状態を消したうえで、スケジュールの時間帯にいれば、その時間帯が終わるまで中継する。
    # OyasumiVR が睡眠モードを示していれば、睡眠モードが切れるまで中継する。
    # 手動だけを消すと、時間帯や睡眠モードの中では止まったままになり、押しても何も変わらない。
    def stop : Nil
      now = @clock.call
      @manual_until = nil
      @awake_until = @config.schedule.active?(now) ? @config.schedule.next_end(now) : nil
      @awake_oyasumivr = oyasumivr_state.asleep?
    end

    private def manual_active?(now : Time) : Bool
      ends = @manual_until
      !ends.nil? && now < ends
    end

    private def schedule_active?(now : Time) : Bool
      return false unless @config.schedule.active?(now)
      awake = @awake_until
      awake.nil? || now >= awake
    end

    # OyasumiVR の睡眠モードで止めるか。
    #
    # 起きている間の上書きは、睡眠モードが切れたのを見た時点で下ろす。
    # 時刻で期限を判定できるスケジュールと違い、切れたことは問い合わせの時点でしか分からない。
    # 主ループが毎周期 reason を呼ぶため、ここで下ろしても取りこぼさない。
    # 見失った間（Unknown）は下ろさない。一時的に読めなかっただけで、起きているのにまた止まるのを避ける。
    #
    # 連携を無効にしたときも下ろす。無効の間に睡眠モードが切れて入り直しても、それを見る手段が無い。
    # 残したまま有効に戻すと、次に切れるのを見るまで睡眠モード中も中継し続ける。
    private def oyasumivr_active? : Bool
      unless @config.oyasumivr.enabled
        @awake_oyasumivr = false
        return false
      end
      state = oyasumivr_state
      @awake_oyasumivr = false if state.awake?
      state.asleep? && !@awake_oyasumivr
    end

    private def oyasumivr_state : SignalState
      return SignalState::Unknown unless @config.oyasumivr.enabled
      @oyasumivr.try(&.state) || SignalState::Unknown
    end
  end
end
