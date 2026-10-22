require "../config/models"
require "../notify/repository"
require "./models"

module Sleep
  # 睡眠中かを決める（issue #54）。
  #
  # 入力を合わせて 1 つの理由を返す。今の入力は、トレイから始める手動とスケジュールである。
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

    # 時計は差し替えられるようにしておく。
    # スケジュールも手動の期限も壁時計の時刻で決まり、テストで時刻を固定しないと境界を確かめられない。
    def initialize(
      @config : ::Config::SleepSection = ::Config::SleepSection.new,
      @clock : Proc(Time) = -> { Time.local },
    )
    end

    # 止めている理由。複数が成り立つときは Reason の並びで先のものを返す。
    def reason : Reason
      now = @clock.call
      return Reason::Manual if manual_active?(now)
      return Reason::Schedule if schedule_active?(now)
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
      ends
    end

    # おやすみモードを終える。トレイの「おやすみモードを終了」から呼ぶ。
    #
    # 手動の状態を消したうえで、スケジュールの時間帯にいれば、その時間帯が終わるまで中継する。
    # 手動だけを消すと、時間帯の中では止まったままになり、押しても何も変わらない。
    def stop : Nil
      now = @clock.call
      @manual_until = nil
      @awake_until = @config.schedule.active?(now) ? @config.schedule.next_end(now) : nil
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
  end
end
