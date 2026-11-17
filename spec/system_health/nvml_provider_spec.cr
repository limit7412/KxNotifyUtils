require "../spec_helper"

private def sampling(**fields) : SystemHealth::NvmlSample
  SystemHealth::NvmlSample.new(**fields, state: SystemHealth::NvmlSample::State::Sampling)
end

private def collect(reader : Fakes::NvmlReader, interval : Time::Span = 1.second) : Hash(String, Float64)
  provider = SystemHealth::NvmlProvider.new(reader)
  provider.start(interval)
  samples = {} of String => Float64
  provider.sample(samples)
  samples
end

describe SystemHealth::NvmlProvider do
  it "温度、上限、余裕、ファン、温度制限を計測値にする" do
    reader = Fakes::NvmlReader.new(sampling(
      device_count: 1, temperature_c: 85, limit_gpu_max_c: 88, limit_slowdown_c: 95,
      limit_shutdown_c: 100, fan_percent: 100, clock_reasons: 0x24_u64))

    collect(reader).should eq({
      "gpu.temperature_c"       => 85.0,
      "gpu.temperature_limit_c" => 88.0,
      "gpu.thermal_margin_c"    => 3.0,
      "gpu.fan_percent"         => 100.0,
      "gpu.thermal_throttle"    => 1.0,
    })
  end

  it "動作上限が返らない機種では、減速を始める温度までの余裕で代える" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 85, limit_slowdown_c: 95, limit_shutdown_c: 100))

    collect(reader)["gpu.thermal_margin_c"].should eq 10.0
  end

  it "上限が 1 つも返らなければ、余裕は計測値にしない" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 85))

    samples = collect(reader)
    samples["gpu.temperature_c"].should eq 85.0
    samples.has_key?("gpu.thermal_margin_c").should be_false
  end

  it "温度制限のビットだけを見て、電力上限などの他の理由では作動と見なさない" do
    # 0x04 は電力上限、0x40 はハードウェアの高温による減速である。
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 70, clock_reasons: 0x44_u64))

    collect(reader)["gpu.thermal_throttle"].should eq 0.0
  end

  it "減速の理由が取れなければ、温度制限は計測値にしない" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 70))

    collect(reader).has_key?("gpu.thermal_throttle").should be_false
  end

  it "NVML を使えない環境では計測値を出さない" do
    reader = Fakes::NvmlReader.new(SystemHealth::NvmlSample.new(SystemHealth::NvmlSample::State::Unavailable))

    collect(reader).should be_empty
  end

  it "まだ 1 回も取れていない間は計測値を出さない" do
    reader = Fakes::NvmlReader.new(SystemHealth::NvmlSample.new(SystemHealth::NvmlSample::State::Starting))

    collect(reader).should be_empty
  end

  it "更新が止まった値は使わない" do
    reader = Fakes::NvmlReader.new(sampling(age: 6.seconds, temperature_c: 60, limit_gpu_max_c: 88))

    collect(reader).should be_empty
  end

  it "更新が止まったと見なすまでの時間は、取得の間隔に合わせて延びる" do
    reader = Fakes::NvmlReader.new(sampling(age: 6.seconds, temperature_c: 60, limit_gpu_max_c: 88))

    collect(reader, interval: 10.seconds).should_not be_empty
  end

  it "取得の間隔を取得スレッドへ渡し、停止を伝える" do
    reader = Fakes::NvmlReader.new
    provider = SystemHealth::NvmlProvider.new(reader)

    provider.start(2.seconds)
    provider.stop

    reader.intervals.should eq [2.seconds]
    reader.stop_count.should eq 1
  end
end

describe "GPU の温度の通知" do
  texts = SystemHealth::Texts.new(
    app_name: "システムヘルス",
    rules: {
      "gpu.thermal_margin" => SystemHealth::RuleTexts.new(
        title: "上限に近い", body: "{gpu.temperature_c}℃（上限 {gpu.temperature_limit_c}℃ まで {value}℃）",
        cleared_title: "下がった", cleared_body: "{gpu.temperature_c}℃"),
      "gpu.cooling_saturated" => SystemHealth::RuleTexts.new(
        title: "冷却が追いつかない", body: "ファン {gpu.fan_percent}%、{gpu.temperature_c}℃",
        cleared_title: "追いついた", cleared_body: ""),
      "gpu.thermal_throttle" => SystemHealth::RuleTexts.new(
        title: "温度制限", body: "現在 {gpu.temperature_c}℃",
        cleared_title: "解除", cleared_body: ""),
    },
  )

  it "余裕が 4℃ 以下のまま 60 秒続いたら warning を出す" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 85, limit_gpu_max_c: 88, fan_percent: 70, clock_reasons: 0_u64))
    target = SystemHealth::Repository.new(
      [SystemHealth::NvmlProvider.new(reader).as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)
    target.start

    target.poll_new(0.seconds).should be_empty
    target.poll_new(59.seconds).should be_empty
    fresh = target.poll_new(60.seconds)

    fresh.map(&.app_id).should eq ["system_health.gpu.thermal_margin"]
    fresh.first.title.should eq "上限に近い"
    fresh.first.body.should eq "85℃（上限 88℃ まで 3℃）"
    fresh.first.icon.should eq Notify::Icon.builtin("warning")
  end

  it "ファンが全開で余裕が 6℃ 以下なら、余裕の規則より先に冷却の限界を知らせる" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 83, limit_gpu_max_c: 88, fan_percent: 100, clock_reasons: 0_u64))
    target = SystemHealth::Repository.new(
      [SystemHealth::NvmlProvider.new(reader).as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)
    target.start

    target.poll_new(0.seconds)
    fresh = target.poll_new(60.seconds)

    fresh.map(&.app_id).should eq ["system_health.gpu.cooling_saturated"]
    fresh.first.body.should eq "ファン 100%、83℃"
  end

  it "温度制限が作動した周期に error を出す" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 87, limit_gpu_max_c: 88, fan_percent: 100, clock_reasons: 0x20_u64))
    target = SystemHealth::Repository.new(
      [SystemHealth::NvmlProvider.new(reader).as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)
    target.start

    fresh = target.poll_new(0.seconds)

    fresh.map(&.app_id).should eq ["system_health.gpu.thermal_throttle"]
    fresh.first.body.should eq "現在 87℃"
    fresh.first.icon.should eq Notify::Icon.builtin("error")
  end

  it "本文に書いた計測値が取れていなければ、プレースホルダの代わりに - を出す" do
    reader = Fakes::NvmlReader.new(sampling(clock_reasons: 0x20_u64))
    target = SystemHealth::Repository.new(
      [SystemHealth::NvmlProvider.new(reader).as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)
    target.start

    target.poll_new(0.seconds).first.body.should eq "現在 -℃"
  end

  it "値の更新が止まったら、継続の計測を打ち切る" do
    reader = Fakes::NvmlReader.new(sampling(temperature_c: 85, limit_gpu_max_c: 88))
    target = SystemHealth::Repository.new(
      [SystemHealth::NvmlProvider.new(reader).as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)
    target.start
    target.poll_new(0.seconds)

    reader.sample = sampling(age: 30.seconds, temperature_c: 85, limit_gpu_max_c: 88)
    target.poll_new(30.seconds)
    reader.sample = sampling(temperature_c: 85, limit_gpu_max_c: 88)

    target.poll_new(60.seconds).should be_empty
    target.poll_new(120.seconds).size.should eq 1
  end
end

describe "取得元の開始と停止" do
  texts = SystemHealth::Texts.new(app_name: "システムヘルス", rules: {} of String => SystemHealth::RuleTexts)

  it "ソースの開始で有効な取得元を開始し、停止で止める" do
    provider = Fakes::MetricProvider.new("nvml")
    target = SystemHealth::Repository.new(
      [provider.as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.from_section(JSON.parse(%({"polling_interval_s": 2}))), texts)

    provider.intervals.should be_empty
    target.start
    provider.intervals.should eq [2.seconds]

    target.stop
    provider.stop_count.should eq 1
  end

  it "無効にした取得元は開始せず、設定で無効にしたら止める" do
    provider = Fakes::MetricProvider.new("nvml")
    target = SystemHealth::Repository.new(
      [provider.as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.from_section(JSON.parse(%({"providers": {"nvml": false}}))), texts)

    target.start
    provider.intervals.should be_empty

    target.settings = SystemHealth::Settings.new
    provider.intervals.size.should eq 1

    target.settings = SystemHealth::Settings.from_section(JSON.parse(%({"providers": {"nvml": false}})))
    provider.stop_count.should eq 1
  end

  it "開始していないソースへ設定を渡しても、取得元を開始しない" do
    provider = Fakes::MetricProvider.new("nvml")
    target = SystemHealth::Repository.new(
      [provider.as(SystemHealth::MetricProvider)], SystemHealth::Settings.new, texts)

    target.settings = SystemHealth::Settings.new

    provider.intervals.should be_empty
  end

  it "取得元を開始できなくても、ソースの開始は続ける" do
    broken = Fakes::MetricProvider.new("nvml")
    broken.start_error = "取得スレッドを立てられなかった"
    memory = Fakes::MetricProvider.new("memory")
    target = SystemHealth::Repository.new(
      [broken.as(SystemHealth::MetricProvider), memory.as(SystemHealth::MetricProvider)],
      SystemHealth::Settings.new, texts)

    target.start

    memory.intervals.size.should eq 1
  end
end
