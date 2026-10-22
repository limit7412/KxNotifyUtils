require "../spec_helper"
require "../../src/sleep/usecase"

private def sleep_usecase(json : String, time : Time)
  Sleep::Usecase.new(Config::SleepSection.from_json(json), -> { time })
end

describe Sleep::Usecase do
  it "スケジュールの範囲内なら Schedule を理由に睡眠中とする" do
    target = sleep_usecase(%({"schedule": {"enabled": true, "start": "23:00", "end": "07:00"}}),
      Time.local(2026, 10, 23, 2, 0))

    target.reason.should eq Sleep::Reason::Schedule
    target.sleeping?.should be_true
  end

  it "スケジュールの範囲外なら睡眠中としない" do
    target = sleep_usecase(%({"schedule": {"enabled": true, "start": "23:00", "end": "07:00"}}),
      Time.local(2026, 10, 23, 12, 0))

    target.reason.should eq Sleep::Reason::None
    target.sleeping?.should be_false
  end

  it "スケジュールが無効なら睡眠中としない" do
    target = sleep_usecase(%({"schedule": {"enabled": false, "start": "23:00", "end": "07:00"}}),
      Time.local(2026, 10, 23, 2, 0))

    target.sleeping?.should be_false
  end

  it "設定の差し替えは次の問い合わせから効く" do
    target = sleep_usecase(%({}), Time.local(2026, 10, 23, 2, 0))
    target.sleeping?.should be_false

    target.config = Config::SleepSection.from_json(%({"schedule": {"enabled": true, "start": "01:00", "end": "08:00"}}))

    target.sleeping?.should be_true
  end
end

# 時計を進められる Sleep::Usecase。
# 閉包が捕まえるのは変数そのものなので、clock.now を書き換えると次の問い合わせから効く。
private class Clock
  property now : Time

  def initialize(@now : Time)
  end
end

private def manual_usecase(json : String, clock : Clock)
  Sleep::Usecase.new(Config::SleepSection.from_json(json), -> { clock.now })
end

private SCHEDULED   = %({"manual_duration_h": 8, "schedule": {"enabled": true, "start": "23:00", "end": "07:00"}})
private UNSCHEDULED = %({"manual_duration_h": 3, "schedule": {"enabled": false, "start": "23:00", "end": "07:00"}})

describe "Sleep::Usecase の手動のおやすみモード" do
  it "スケジュールが無効なら設定した時間だけ止める" do
    clock = Clock.new(Time.local(2026, 10, 22, 21, 0))
    target = manual_usecase(UNSCHEDULED, clock)

    target.start_manual.should eq Time.local(2026, 10, 23, 0, 0)
    target.reason.should eq Sleep::Reason::Manual

    clock.now = Time.local(2026, 10, 22, 23, 59)
    target.sleeping?.should be_true
    clock.now = Time.local(2026, 10, 23, 0, 0)
    target.sleeping?.should be_false
  end

  it "スケジュールが有効なら次の終了時刻まで止める" do
    clock = Clock.new(Time.local(2026, 10, 22, 21, 0))
    target = manual_usecase(SCHEDULED, clock)

    target.start_manual.should eq Time.local(2026, 10, 23, 7, 0)

    # 時間帯の前は手動、時間帯に入っても手動を先に出す。
    target.reason.should eq Sleep::Reason::Manual
    clock.now = Time.local(2026, 10, 23, 2, 0)
    target.reason.should eq Sleep::Reason::Manual
    clock.now = Time.local(2026, 10, 23, 7, 0)
    target.sleeping?.should be_false
  end

  it "終了すれば手動の停止を解く" do
    clock = Clock.new(Time.local(2026, 10, 22, 21, 0))
    target = manual_usecase(UNSCHEDULED, clock)
    target.start_manual

    target.stop

    target.sleeping?.should be_false
    target.manual_until.should be_nil
    target.awake_until.should be_nil
  end

  # 寝ている途中で起きて通知を見たい場面である。
  it "スケジュールの時間帯で終了すると、その時間帯の終わりまで中継し、次の晩はまた止める" do
    clock = Clock.new(Time.local(2026, 10, 23, 2, 0))
    target = manual_usecase(SCHEDULED, clock)
    target.reason.should eq Sleep::Reason::Schedule

    target.stop

    target.awake_until.should eq Time.local(2026, 10, 23, 7, 0)
    target.sleeping?.should be_false
    clock.now = Time.local(2026, 10, 23, 6, 59)
    target.sleeping?.should be_false
    clock.now = Time.local(2026, 10, 23, 23, 0)
    target.reason.should eq Sleep::Reason::Schedule
  end

  it "起きている間の上書きがあっても、始め直せば止める" do
    clock = Clock.new(Time.local(2026, 10, 23, 2, 0))
    target = manual_usecase(SCHEDULED, clock)
    target.stop
    target.sleeping?.should be_false

    clock.now = Time.local(2026, 10, 23, 3, 0)
    target.start_manual

    target.awake_until.should be_nil
    target.reason.should eq Sleep::Reason::Manual
  end
end
