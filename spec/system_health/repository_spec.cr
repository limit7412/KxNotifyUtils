require "../spec_helper"
require "../../src/runtime/i18n"

private METRIC = SystemHealth::Metric::MEMORY_PHYSICAL_USAGE

private TEXTS = SystemHealth::Texts.new(
  app_name: "システムヘルス",
  rules: {
    "memory.physical_usage" => SystemHealth::RuleTexts.new(
      title: "メモリ不足",
      body: "使用率 {value}%（{threshold}% 以上が {for_s} 秒）",
      cleared_title: "解消",
      cleared_body: "使用率 {value}%",
    ),
  },
)

private def settings(json : String = "{}") : SystemHealth::Settings
  SystemHealth::Settings.from_section(JSON.parse(json))
end

private def repository(provider : Fakes::MetricProvider, config : SystemHealth::Settings = settings) : SystemHealth::Repository
  SystemHealth::Repository.new([provider.as(SystemHealth::MetricProvider)], config, TEXTS)
end

describe SystemHealth::Repository do
  it "設定の間隔でポーリングされる" do
    target = repository(Fakes::MetricProvider.new, settings(%({"polling_interval_s": 5})))

    target.source_id.should eq "system_health"
    target.poll_interval.should eq 5.seconds
  end

  it "開始している間だけ、直近の計測値を見せる" do
    target = repository(Fakes::MetricProvider.new(values: {METRIC => 42.0}))

    target.started?.should be_false
    target.last_samples.should be_empty

    target.start
    target.poll_new(0.seconds)
    target.started?.should be_true
    target.last_samples[METRIC].should eq 42.0

    target.stop
    target.started?.should be_false
    target.last_samples.should be_empty
  end

  it "条件が継続時間を満たしたら、規則の id を付けた Incoming を返す" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 96.4})
    target = repository(provider)

    target.poll_new(0.seconds).should be_empty
    fresh = target.poll_new(120.seconds)

    fresh.size.should eq 1
    incoming = fresh.first
    incoming.source.should eq "system_health"
    incoming.app_id.should eq "system_health.memory.physical_usage"
    incoming.app_name.should eq "システムヘルス"
    incoming.title.should eq "メモリ不足"
    incoming.body.should eq "使用率 96%（95% 以上が 120 秒）"
    incoming.icon.should eq Notify::Icon.builtin("warning")
  end

  it "条件が続いていても、発報は繰り返さない" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider)
    target.poll_new(0.seconds)
    target.poll_new(120.seconds).size.should eq 1

    target.poll_new(121.seconds).should be_empty
    target.poll_new(3600.seconds).should be_empty
  end

  it "解除は既定では知らせない" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider)
    target.poll_new(0.seconds)
    target.poll_new(120.seconds)

    provider.values[METRIC] = 50.0
    target.poll_new(121.seconds).should be_empty
  end

  it "notify_clear を有効にした規則は、解除を default のアイコンで知らせる" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider, settings(
      %({"alerts": {"memory.physical_usage": {"for_s": 0, "notify_clear": true}}})))
    target.poll_new(0.seconds)

    provider.values[METRIC] = 88.6
    cleared = target.poll_new(1.seconds)

    cleared.size.should eq 1
    cleared.first.title.should eq "解消"
    cleared.first.body.should eq "使用率 89%"
    cleared.first.icon.should eq Notify::Icon.builtin("default")
  end

  it "無効にした取得元からは値を取らない" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider, settings(
      %({"providers": {"memory": false}, "alerts": {"memory.physical_usage": {"for_s": 0}}})))

    target.poll_new(0.seconds).should be_empty
    provider.sample_count.should eq 0
  end

  it "取得元が例外を出しても、他の取得元の値で評価を続ける" do
    broken = Fakes::MetricProvider.new("broken")
    broken.error = "取得に失敗"
    memory = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = SystemHealth::Repository.new(
      [broken.as(SystemHealth::MetricProvider), memory.as(SystemHealth::MetricProvider)],
      settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})), TEXTS)

    target.poll_new(0.seconds).size.should eq 1
  end

  it "設定を差し替えると、新しいしきい値で評価する" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 85.0})
    target = repository(provider, settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})))
    target.poll_new(0.seconds).should be_empty

    target.settings = settings(%({"alerts": {"memory.physical_usage": {"for_s": 0, "threshold": 80}}}))

    target.poll_new(1.seconds).size.should eq 1
  end

  it "継続の計測中に数値を変えたら、変えた後の条件で数え直す" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 96.0})
    target = repository(provider)
    target.poll_new(0.seconds)
    target.poll_new(119.seconds).should be_empty

    target.settings = settings(%({"alerts": {"memory.physical_usage": {"threshold": 98}}}))
    provider.values[METRIC] = 99.0

    target.poll_new(120.seconds).should be_empty
    target.poll_new(239.seconds).should be_empty
    target.poll_new(240.seconds).size.should eq 1
  end

  it "同じ設定を渡し直しても、継続の計測を打ち切らない" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 96.0})
    target = repository(provider)
    target.poll_new(0.seconds)

    target.settings = settings

    target.poll_new(120.seconds).size.should eq 1
  end

  it "発報中に数値を変えても、同じ通知を出し直さない" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider, settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})))
    target.poll_new(0.seconds).size.should eq 1

    target.settings = settings(%({"alerts": {"memory.physical_usage": {"for_s": 0, "threshold": 97}}}))

    target.poll_new(1.seconds).should be_empty
  end

  it "開始し直すと、発報中の状態を捨てる" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = repository(provider, settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})))
    target.poll_new(0.seconds).size.should eq 1

    target.start

    target.poll_new(1.seconds).size.should eq 1
  end

  it "文言の無い規則は id を件名にする" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    target = SystemHealth::Repository.new(
      [provider.as(SystemHealth::MetricProvider)],
      settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})),
      SystemHealth::Texts.new(app_name: "システムヘルス", rules: {} of String => SystemHealth::RuleTexts))

    target.poll_new(0.seconds).first.title.should eq "memory.physical_usage"
  end

  it "中継の整形とルールの前方一致をそのまま通る" do
    provider = Fakes::MetricProvider.new(values: {METRIC => 99.0})
    source = repository(provider, settings(%({"alerts": {"memory.physical_usage": {"for_s": 0}}})))
    sink = Fakes::Sink.new("sink")
    config = Config::Root.from_json(%({"rules": [{"match_app_id": "system_health.memory", "volume": 0.9}]}))
    relay = Notify::RelayUsecase.new(
      sources: [source.as(Notify::SourceRepository)],
      sinks: [sink.as(Notify::PostRepository)],
      builders: [SystemHealth::MessageBuilder.new(Fakes::Icons.new).as(Notify::MessageBuilder)],
      config: config,
    )

    relay.tick

    sink.sent.size.should eq 1
    message = sink.sent.first
    message.title.should eq "システムヘルス: メモリ不足"
    message.icon.should eq Notify::Icon.builtin("warning")
    message.volume.should eq 0.9
  end
end

# 規則を足したのに辞書を足し忘れると、通知の件名が id のまま出る。
describe "システムヘルスの辞書" do
  it "同梱の規則すべてに、発報と解除の文言がある" do
    missing = [] of String
    SystemHealth::RULES.each do |rule|
      %w[title body cleared_title cleared_body].each do |suffix|
        key = "notify.system_health.#{rule.id}.#{suffix}"
        missing << key unless Runtime::I18n::LOCALES["ja"].has_key?(key)
      end
    end

    missing.should be_empty
  end

  it "同梱の規則すべてに、設定ウィンドウの文言がある" do
    missing = [] of String
    SystemHealth::RULES.each do |rule|
      keys = ["settings.health.rule.#{rule.id}", "settings.health.description.#{rule.id}"]
      keys << "settings.health.threshold.#{rule.id}" if rule.threshold_adjustable?
      keys << "settings.health.secondary.#{rule.id}" if rule.secondary
      keys.each { |key| missing << key unless Runtime::I18n::LOCALES["ja"].has_key?(key) }
    end

    missing.should be_empty
  end
end

# Windows の CI で FFI の宣言と構造体の大きさを確かめる。
# 宣言が食い違うと、呼び出しが失敗して値が入らないか、範囲外の値になる。
describe SystemHealth::MemoryProvider do
  it "Windows では物理メモリの使用率をパーセントで返し、他の環境では何も返さない" do
    samples = {} of String => Float64

    SystemHealth::MemoryProvider.new.sample(samples)

    {% if flag?(:windows) %}
      usage = samples[SystemHealth::Metric::MEMORY_PHYSICAL_USAGE]
      (usage > 0.0).should be_true
      (usage <= 100.0).should be_true
    {% else %}
      samples.should be_empty
    {% end %}
  end
end
