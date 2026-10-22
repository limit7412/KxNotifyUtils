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
