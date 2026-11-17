require "../spec_helper"
require "../../src/system_health/alert_form"

private def definition(id : String) : SystemHealth::RuleDefinition
  SystemHealth.rule?(id).not_nil!
end

private def round_trip(id : String, previous : SystemHealth::AlertSettings?) : SystemHealth::AlertSettings
  errors = [] of String
  rule = definition(id)
  result = SystemHealth::AlertForm.from(rule, previous).to_settings(rule, previous, id, errors)
  errors.should be_empty
  result
end

describe SystemHealth::AlertForm do
  it "設定に書かれていない項目へ規則の既定値を入れる" do
    form = SystemHealth::AlertForm.from(definition("gpu.cooling_saturated"), nil)

    form.enabled?.should be_true
    form.threshold.should eq "6"
    form.secondary_threshold.should eq "95"
    form.for_s.should eq 60
    form.cooldown_s.should eq 600
    form.notify_clear?.should be_false
  end

  it "解除のしきい値は、書かれていなければ空欄にする" do
    SystemHealth::AlertForm.from(definition("memory.physical_usage"), nil).clear_threshold.should eq ""

    overrides = SystemHealth::AlertSettings.new(clear_threshold: 88.5)
    SystemHealth::AlertForm.from(definition("memory.physical_usage"), overrides).clear_threshold.should eq "88.5"
  end

  it "しきい値を変える意味の無い規則では、しきい値の欄を空にする" do
    form = SystemHealth::AlertForm.from(definition("gpu.thermal_throttle"), nil)

    form.threshold.should eq ""
    form.clear_threshold.should eq ""
  end

  it "編集していなければ、書かれていなかった項目を書かないままにする" do
    SystemHealth::RULES.each do |rule|
      round_trip(rule.id, nil).empty?.should be_true
    end
  end

  it "編集していなければ、書かれていた項目をそのまま返す" do
    previous = SystemHealth::AlertSettings.new(
      enabled: true, threshold: 95.0, for_s: 120, clear_threshold: 90.0, cooldown_s: 600, notify_clear: false)

    round_trip("memory.physical_usage", previous).to_json.should eq previous.to_json
  end

  it "既定値から変えた項目だけを書く" do
    rule = definition("gpu.thermal_margin")
    form = SystemHealth::AlertForm.new(
      enabled: false, threshold: "5.5", clear_threshold: "", secondary_threshold: "",
      for_s: 60, cooldown_s: 600, notify_clear: true)
    errors = [] of String

    result = form.to_settings(rule, nil, "余裕", errors)

    errors.should be_empty
    result.enabled.should be_false
    result.threshold.should eq 5.5
    result.clear_threshold.should be_nil
    result.for_s.should be_nil
    result.cooldown_s.should be_nil
    result.notify_clear.should be_true
  end

  it "解除のしきい値を空欄に戻すと、上書きを消す" do
    rule = definition("memory.physical_usage")
    previous = SystemHealth::AlertSettings.new(threshold: 95.0, clear_threshold: 90.0)
    form = SystemHealth::AlertForm.new(
      enabled: true, threshold: "80", clear_threshold: " ", secondary_threshold: "",
      for_s: 120, cooldown_s: 600, notify_clear: false)

    result = form.to_settings(rule, previous, "メモリ", [] of String)

    result.threshold.should eq 80.0
    result.clear_threshold.should be_nil
    SystemHealth::Rule.new(rule, result).clear_threshold.should eq 75.0
  end

  it "画面に出していないしきい値は前の設定を引き継ぐ" do
    previous = SystemHealth::AlertSettings.new(threshold: 1.0, cooldown_s: 30)

    round_trip("gpu.thermal_throttle", previous).threshold.should eq 1.0
  end

  it "数値として読めない入力を誤りとして残す" do
    rule = definition("gpu.cooling_saturated")
    form = SystemHealth::AlertForm.new(
      enabled: true, threshold: "abc", clear_threshold: "nan", secondary_threshold: "",
      for_s: 60, cooldown_s: 600, notify_clear: false)
    errors = [] of String

    form.to_settings(rule, nil, "冷却", errors)

    errors.size.should eq 3
    errors.first.should contain "冷却"
  end
end
