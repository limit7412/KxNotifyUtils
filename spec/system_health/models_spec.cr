require "../spec_helper"

private def section(json : String) : JSON::Any
  JSON.parse(json)
end

private def rule(settings : SystemHealth::Settings, id : String = "memory.physical_usage") : SystemHealth::Rule
  settings.rules.find! { |candidate| candidate.id == id }
end

describe SystemHealth::Settings do
  describe ".from_section" do
    it "セクションが無ければ既定値で有効になる" do
      settings = SystemHealth::Settings.from_section(nil)

      settings.enabled.should be_true
      settings.polling_interval_s.should eq 1
      settings.provider_enabled?("memory").should be_true
    end

    it "alerts に書かれていない規則は既定値で有効になる" do
      memory = rule(SystemHealth::Settings.from_section(section(%({"alerts": {}}))))

      memory.enabled?.should be_true
      memory.threshold.should eq 95.0
      memory.for_s.should eq 120
      memory.clear_threshold.should eq 90.0
      memory.cooldown_s.should eq 600
      memory.notify_clear?.should be_false
    end

    it "書かれた項目だけを上書きし、残りは既定値のままにする" do
      settings = SystemHealth::Settings.from_section(section(
        %({"alerts": {"memory.physical_usage": {"for_s": 30, "notify_clear": true}}})))
      memory = rule(settings)

      memory.for_s.should eq 30
      memory.notify_clear?.should be_true
      memory.threshold.should eq 95.0
      memory.cooldown_s.should eq 600
    end

    it "解除のしきい値を書かなければ、発報のしきい値に合わせて動く" do
      settings = SystemHealth::Settings.from_section(section(
        %({"alerts": {"memory.physical_usage": {"threshold": 80}}})))

      rule(settings).clear_threshold.should eq 75.0
    end

    it "継続時間と再発報の間隔に 0 を指定できる" do
      settings = SystemHealth::Settings.from_section(section(
        %({"alerts": {"memory.physical_usage": {"for_s": 0, "cooldown_s": 0}}})))
      memory = rule(settings)

      memory.for_s.should eq 0
      memory.cooldown_s.should eq 0
    end

    it "規則を無効にできる" do
      settings = SystemHealth::Settings.from_section(section(
        %({"alerts": {"memory.physical_usage": {"enabled": false}}})))

      rule(settings).enabled?.should be_false
    end

    it "取得元を無効にできる" do
      settings = SystemHealth::Settings.from_section(section(%({"providers": {"memory": false}})))

      settings.provider_enabled?("memory").should be_false
    end
  end

  describe ".validate" do
    it "セクションが無くても妥当とみなす" do
      SystemHealth::Settings.validate(nil).should be_empty
    end

    it "初期設定に書き出すセクションは妥当である" do
      default = Config::Root.default.source("system_health")

      default.should_not be_nil
      SystemHealth::Settings.validate(default).should be_empty
    end

    it "初期設定に書き出す値は規則の既定値と一致する" do
      written = rule(SystemHealth::Settings.from_section(Config::Root.default.source("system_health")))
      builtin = rule(SystemHealth::Settings.new)

      written.should eq builtin
    end

    it "範囲外のポーリング間隔を弾く" do
      errors = SystemHealth::Settings.validate(section(%({"polling_interval_s": 0})))

      errors.size.should eq 1
      errors.first.should contain "polling_interval_s"
    end

    it "範囲外のしきい値を弾く" do
      errors = SystemHealth::Settings.validate(section(
        %({"alerts": {"memory.physical_usage": {"threshold": 120, "clear_threshold": 90}}})))

      errors.size.should eq 1
      errors.first.should contain "alerts.memory.physical_usage.threshold"
    end

    it "発報のしきい値より厳しい側にある解除のしきい値を弾く" do
      errors = SystemHealth::Settings.validate(section(
        %({"alerts": {"memory.physical_usage": {"threshold": 90, "clear_threshold": 95}}})))

      errors.size.should eq 1
      errors.first.should contain "clear_threshold"
    end

    it "範囲外の継続時間と再発報の間隔を弾く" do
      errors = SystemHealth::Settings.validate(section(
        %({"alerts": {"memory.physical_usage": {"for_s": -1, "cooldown_s": 100000}}})))

      errors.size.should eq 2
      errors[0].should contain "for_s"
      errors[1].should contain "cooldown_s"
    end

    it "型の合わない値は書式の誤りとして返す" do
      errors = SystemHealth::Settings.validate(section(%({"alerts": {"memory.physical_usage": {"threshold": "high"}}})))

      errors.size.should eq 1
      errors.first.should contain "書式が不正"
    end

    it "知らない規則と取得元は誤りにせず、読み飛ばす対象として返す" do
      json = section(%({"providers": {"nvml": true}, "alerts": {"gpu.thermal_margin": {"threshold": 4}}}))

      SystemHealth::Settings.validate(json).should be_empty
      settings = SystemHealth::Settings.from_section(json)
      settings.unknown_alert_ids.should eq ["gpu.thermal_margin"]
      settings.unknown_provider_ids.should eq ["nvml"]
    end
  end

  it "保存し直しても、書かれていなかった項目を既定値で埋めない" do
    settings = SystemHealth::Settings.from_section(section(
      %({"alerts": {"memory.physical_usage": {"for_s": 30}}})))

    JSON.parse(settings.to_json)["alerts"]["memory.physical_usage"].should eq JSON.parse(%({"for_s": 30}))
  end
end

describe SystemHealth::RuleDefinition do
  it "規則の id は重複しない" do
    ids = SystemHealth::RULES.map(&.id)

    ids.uniq.should eq ids
  end

  it "既定値はどの規則も検証を通る" do
    SystemHealth::Settings.validate(JSON.parse("{}")).should be_empty
  end

  it "値が小さいほど悪い規則では、解除のしきい値を大きい側へ離す" do
    definition = SystemHealth::RuleDefinition.new(
      id: "test.margin", metric: "test.margin", direction: SystemHealth::Direction::AtOrBelow,
      severity: SystemHealth::Severity::Warning, threshold: 4.0, threshold_range: 0.0..50.0,
      for_s: 60, clear_margin: 4.0, cooldown_s: 600)
    margin = SystemHealth::Rule.new(definition)

    margin.clear_threshold.should eq 8.0
    margin.satisfied?(4.0).should be_true
    margin.satisfied?(4.1).should be_false
    margin.cleared?(7.9).should be_false
    margin.cleared?(8.0).should be_true
  end
end
