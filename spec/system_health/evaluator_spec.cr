require "../spec_helper"

private METRIC = SystemHealth::Metric::MEMORY_PHYSICAL_USAGE

private def rules(**overrides) : Array(SystemHealth::Rule)
  settings = SystemHealth::Settings.from_section(
    JSON.parse({"alerts" => {"memory.physical_usage" => overrides}}.to_json))
  settings.rules
end

private def at(evaluator, rules, value : Float64?, second : Int32) : Array(SystemHealth::Evaluator::Transition)
  samples = {} of String => Float64
  samples[METRIC] = value if value
  evaluator.evaluate(rules, samples, second.seconds)
end

describe SystemHealth::Evaluator do
  it "条件が継続時間を満たしたときに 1 回だけ発報する" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 120)

    at(evaluator, target, 96.0, 0).should be_empty
    evaluator.phase("memory.physical_usage").pending?.should be_true
    at(evaluator, target, 96.0, 119).should be_empty

    fired = at(evaluator, target, 97.0, 120)
    fired.size.should eq 1
    fired.first.kind.fired?.should be_true
    fired.first.value.should eq 97.0
    evaluator.phase("memory.physical_usage").firing?.should be_true

    at(evaluator, target, 98.0, 121).should be_empty
    at(evaluator, target, 98.0, 1000).should be_empty
  end

  it "継続の計測中に条件が外れたら、継続時間を数え直す" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 120)

    at(evaluator, target, 96.0, 0)
    at(evaluator, target, 94.0, 100).should be_empty
    evaluator.phase("memory.physical_usage").normal?.should be_true

    at(evaluator, target, 96.0, 110)
    at(evaluator, target, 96.0, 229).should be_empty
    at(evaluator, target, 96.0, 230).size.should eq 1
  end

  it "継続時間が 0 の規則は、条件が成り立った周期に発報する" do
    evaluator = SystemHealth::Evaluator.new

    at(evaluator, rules(for_s: 0), 95.0, 0).map(&.kind.fired?).should eq [true]
  end

  it "発報のしきい値を下回っても、解除のしきい値までは発報中を保つ" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 0, clear_threshold: 90)
    at(evaluator, target, 96.0, 0)

    at(evaluator, target, 93.0, 1).should be_empty
    at(evaluator, target, 96.0, 2).should be_empty
    evaluator.phase("memory.physical_usage").firing?.should be_true

    cleared = at(evaluator, target, 90.0, 3)
    cleared.size.should eq 1
    cleared.first.kind.cleared?.should be_true
    evaluator.phase("memory.physical_usage").normal?.should be_true
  end

  it "解除の後、再発報の間隔が空くまでは発報しない" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 10, clear_threshold: 90, cooldown_s: 600)
    at(evaluator, target, 96.0, 0)
    at(evaluator, target, 96.0, 10).size.should eq 1
    at(evaluator, target, 80.0, 20).size.should eq 1

    at(evaluator, target, 96.0, 30)
    at(evaluator, target, 96.0, 40).should be_empty
    at(evaluator, target, 96.0, 609).should be_empty

    again = at(evaluator, target, 96.0, 610)
    again.map(&.kind.fired?).should eq [true]
  end

  it "間隔が空くのを待つ間に条件が外れたら発報しない" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 10, clear_threshold: 90, cooldown_s: 600)
    at(evaluator, target, 96.0, 0)
    at(evaluator, target, 96.0, 10)
    at(evaluator, target, 80.0, 20)

    at(evaluator, target, 96.0, 30)
    at(evaluator, target, 94.0, 300)
    at(evaluator, target, 94.0, 610).should be_empty
  end

  it "値が取れない間は継続の計測を打ち切る" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 60)
    at(evaluator, target, 96.0, 0)

    at(evaluator, target, nil, 30).should be_empty
    evaluator.phase("memory.physical_usage").normal?.should be_true
    at(evaluator, target, 96.0, 60).should be_empty
    at(evaluator, target, 96.0, 120).size.should eq 1
  end

  it "値が取れない間も発報中は保ち、解除とは扱わない" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 0)
    at(evaluator, target, 96.0, 0)

    at(evaluator, target, nil, 1).should be_empty
    evaluator.phase("memory.physical_usage").firing?.should be_true
  end

  it "無効にした規則は評価せず、有効に戻したら継続時間を数え直す" do
    evaluator = SystemHealth::Evaluator.new
    at(evaluator, rules(for_s: 60), 96.0, 0)

    at(evaluator, rules(for_s: 60, enabled: false), 96.0, 60).should be_empty
    at(evaluator, rules(for_s: 60), 96.0, 61).should be_empty
    at(evaluator, rules(for_s: 60), 96.0, 121).size.should eq 1
  end

  it "reset で発報中の状態を捨てる" do
    evaluator = SystemHealth::Evaluator.new
    target = rules(for_s: 0)
    at(evaluator, target, 96.0, 0)

    evaluator.reset

    evaluator.phase("memory.physical_usage").normal?.should be_true
    at(evaluator, target, 96.0, 1).size.should eq 1
  end
end
