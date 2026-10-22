require "../config/models"
require "../notify/repository"
require "./models"

module Sleep
  # 睡眠中かを決める（issue #54）。
  #
  # 入力を合わせて 1 つの理由を返す。今の入力はスケジュールだけである。
  # notify からは SleepGate として見え、中継を止めるかだけを問われる。
  class Usecase < Notify::SleepGate
    # 設定スナップショットの sleep セクション。差し替えは代入 1 回で済む。
    property config : ::Config::SleepSection

    # 時計は差し替えられるようにしておく。
    # スケジュールは壁時計の時刻で決まり、テストで時刻を固定しないと境界を確かめられない。
    def initialize(
      @config : ::Config::SleepSection = ::Config::SleepSection.new,
      @clock : Proc(Time) = -> { Time.local },
    )
    end

    def reason : Reason
      return Reason::Schedule if @config.schedule.active?(@clock.call)
      Reason::None
    end

    def sleeping? : Bool
      !reason.none?
    end
  end
end
