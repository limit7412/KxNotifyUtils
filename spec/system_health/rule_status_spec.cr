require "../spec_helper"

private METRIC = SystemHealth::Metric::MEMORY_PHYSICAL_USAGE
private MARGIN = SystemHealth::Metric::GPU_THERMAL_MARGIN
private FAN    = SystemHealth::Metric::GPU_FAN
private alias State = SystemHealth::RuleStatus::State

private TEXTS = SystemHealth::Texts.new(app_name: "システムヘルス", rules: {} of String => SystemHealth::RuleTexts)

private def repository(
  values : Hash(String, Float64), json : String = "{}",
) : {SystemHealth::Repository, Fakes::MetricProvider}
  provider = Fakes::MetricProvider.new(values: values)
  settings = SystemHealth::Settings.from_section(JSON.parse(json))
  {SystemHealth::Repository.new([provider.as(SystemHealth::MetricProvider)], settings, TEXTS), provider}
end

private def status(target : SystemHealth::Repository, id : String, now : Time::Span) : SystemHealth::RuleStatus
  target.rule_statuses(now).find! { |entry| entry.rule.id == id }
end

describe SystemHealth::RuleStatus do
  it "同梱の規則すべてを、定義の順に返す" do
    target, _ = repository({} of String => Float64)

    target.rule_statuses(0.seconds).map(&.rule.id).should eq SystemHealth::RULES.map(&.id)
  end

  it "ソースが止まっている間は、どの規則も「監視していない」になる" do
    target, _ = repository({METRIC => 99.0})

    target.rule_statuses(0.seconds).all?(&.state.stopped?).should be_true

    target.start
    target.poll_new(0.seconds)
    target.stop
    entry = status(target, "memory.physical_usage", 1.seconds)
    entry.state.should eq State::Stopped
    entry.value.should be_nil
  end

  it "無効にした規則は「無効」になる" do
    target, _ = repository({METRIC => 99.0}, %({"alerts": {"memory.physical_usage": {"enabled": false}}}))
    target.start
    target.poll_new(0.seconds)

    entry = status(target, "memory.physical_usage", 0.seconds)
    entry.state.should eq State::Disabled
    entry.value.should eq 99.0
  end

  it "計測値が取れていない規則は、平常と区別する" do
    target, _ = repository({METRIC => 40.0})
    target.start
    target.poll_new(0.seconds)

    status(target, "memory.physical_usage", 0.seconds).state.should eq State::Normal
    status(target, "gpu.thermal_margin", 0.seconds).state.should eq State::Unavailable
  end

  it "2 つ目の計測値だけが欠けている規則も、値が取れていない扱いにする" do
    target, _ = repository({MARGIN => 20.0})
    target.start
    target.poll_new(0.seconds)

    entry = status(target, "gpu.cooling_saturated", 0.seconds)
    entry.state.should eq State::Unavailable
    entry.value.should eq 20.0
    entry.secondary_value.should be_nil
  end

  it "条件が成り立ってから通知までの残り秒数を返し、通知の後は警告中になる" do
    target, _ = repository({METRIC => 96.0})
    target.start

    target.poll_new(0.seconds)
    entry = status(target, "memory.physical_usage", 30.5.seconds)
    entry.state.should eq State::Pending
    entry.remaining_s.should eq 90

    target.poll_new(120.seconds).size.should eq 1
    entry = status(target, "memory.physical_usage", 121.seconds)
    entry.state.should eq State::Firing
    entry.remaining_s.should be_nil
  end

  it "解除の値まで戻ると正常に戻る" do
    target, provider = repository({METRIC => 96.0})
    target.start
    target.poll_new(0.seconds)
    target.poll_new(120.seconds)

    provider.values = {METRIC => 92.0}
    target.poll_new(121.seconds)
    status(target, "memory.physical_usage", 121.seconds).state.should eq State::Firing

    provider.values = {METRIC => 90.0}
    target.poll_new(122.seconds)
    status(target, "memory.physical_usage", 122.seconds).state.should eq State::Normal
  end

  it "再通知の間隔が明けていない間は、明けるまでの秒数を返す" do
    target, provider = repository({METRIC => 96.0})
    target.start
    target.poll_new(0.seconds)
    target.poll_new(120.seconds)
    provider.values = {METRIC => 80.0}
    target.poll_new(130.seconds)

    provider.values = {METRIC => 96.0}
    target.poll_new(200.seconds)
    # 継続の 120 秒は 320 秒に満ちるが、間隔の 600 秒が明けるのは 720 秒である。
    entry = status(target, "memory.physical_usage", 400.seconds)
    entry.state.should eq State::Suppressed
    entry.remaining_s.should eq 320

    # 間隔の方が先に明ける場合は、継続時間を数えている扱いにする。
    target, provider = repository({METRIC => 96.0}, %({"alerts": {"memory.physical_usage": {"cooldown_s": 100}}}))
    target.start
    target.poll_new(0.seconds)
    target.poll_new(120.seconds)
    provider.values = {METRIC => 80.0}
    target.poll_new(130.seconds)
    provider.values = {METRIC => 96.0}
    target.poll_new(200.seconds)
    entry = status(target, "memory.physical_usage", 210.seconds)
    entry.state.should eq State::Pending
    entry.remaining_s.should eq 110
  end

  it "画面に出す値は、設定を重ねたしきい値と小数 1 桁までの計測値である" do
    target, _ = repository(
      {MARGIN => 5.0, FAN => 97.26},
      %({"alerts": {"gpu.cooling_saturated": {"threshold": 7.5, "secondary_threshold": 90}}}))
    target.start
    target.poll_new(0.seconds)

    values = status(target, "gpu.cooling_saturated", 10.seconds).placeholders
    values["value"].should eq "5"
    values["threshold"].should eq "7.5"
    values["clear_threshold"].should eq "11.5"
    values["secondary_value"].should eq "97.3"
    values["secondary_threshold"].should eq "90"
    values["remaining_s"].should eq "50"
  end

  it "しきい値の手前の値を、整数へ丸めてしきい値と同じに見せない" do
    target, _ = repository({METRIC => 94.6})
    target.start
    target.poll_new(0.seconds)

    entry = status(target, "memory.physical_usage", 0.seconds)
    entry.state.should eq State::Normal
    entry.placeholders["value"].should eq "94.6"
  end

  it "取れていない値と、数えていない残り秒数は - で出す" do
    target, _ = repository({} of String => Float64)
    target.start
    target.poll_new(0.seconds)

    values = status(target, "memory.physical_usage", 0.seconds).placeholders
    values["value"].should eq "-"
    values["secondary_value"].should eq "-"
    values["secondary_threshold"].should eq "-"
    values["remaining_s"].should eq "-"
  end

  it "全規則の状態を、監視しているかと件数に要約する" do
    target, provider = repository({METRIC => 96.0, SystemHealth::Metric::GPU_THERMAL_THROTTLE => 1.0})

    summary = SystemHealth::RuleStatus.summary(target.rule_statuses(0.seconds))
    summary.monitoring.should be_false

    target.start
    target.poll_new(0.seconds)
    summary = SystemHealth::RuleStatus.summary(target.rule_statuses(1.seconds))
    summary.monitoring.should be_true
    summary.firing.should eq 1
    summary.pending.should eq 1

    # 再通知までの間隔が明けていない規則も、条件が成立している側に数える。
    provider.values = {SystemHealth::Metric::GPU_THERMAL_THROTTLE => 0.0}
    target.poll_new(2.seconds)
    provider.values = {SystemHealth::Metric::GPU_THERMAL_THROTTLE => 1.0}
    target.poll_new(3.seconds)
    summary = SystemHealth::RuleStatus.summary(target.rule_statuses(4.seconds))
    summary.firing.should eq 0
    summary.pending.should eq 1
  end

  it "計測値が 0 か 1 の規則は、値が立っているかを返す" do
    target, provider = repository({SystemHealth::Metric::GPU_THERMAL_THROTTLE => 0.0, METRIC => 50.0})
    target.start
    target.poll_new(0.seconds)
    status(target, "gpu.thermal_throttle", 0.seconds).flag?.should be_false
    # しきい値を変えられる規則では、語で見せる値が無い。
    status(target, "memory.physical_usage", 0.seconds).flag?.should be_nil

    provider.values = {SystemHealth::Metric::GPU_THERMAL_THROTTLE => 1.0}
    target.poll_new(1.seconds)
    entry = status(target, "gpu.thermal_throttle", 1.seconds)
    entry.flag?.should be_true
    entry.state.should eq State::Firing

    provider.values = {} of String => Float64
    target.poll_new(2.seconds)
    status(target, "gpu.thermal_throttle", 2.seconds).flag?.should be_nil
  end
end
