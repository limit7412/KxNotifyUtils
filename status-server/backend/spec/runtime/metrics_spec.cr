require "../spec_helper"

# CloudWatch がメトリクスとして拾える形かを見る（仕様書 9）。
#
# 拾われるかは実物の CloudWatch しか答えられないので、ここで確かめるのは
# Embedded Metric Format の仕様が要求する形になっているかまでである。
describe Runtime::Metrics do
  describe "#success" do
    it "一行の JSON として出す" do
      io = IO::Memory.new
      Runtime::Metrics.new("dev", io).success

      io.to_s.count('\n').should eq(1)
      io.to_s.chomp.should_not contain('\n')
    end

    it "名前空間と次元と単位を載せる" do
      io = IO::Memory.new
      Runtime::Metrics.new("dev", io).success

      document = JSON.parse(io.to_s)
      directive = document["_aws"]["CloudWatchMetrics"][0]

      directive["Namespace"].should eq("VRCServiceStatusPanel")
      directive["Dimensions"].should eq(JSON.parse(%([["Env"]])))
      directive["Metrics"][0]["Name"].should eq("RefreshSuccess")
      directive["Metrics"][0]["Unit"].should eq("Count")
    end

    it "次元に挙げた名前の値を根の直下に置く" do
      io = IO::Memory.new
      Runtime::Metrics.new("prod", io).success

      document = JSON.parse(io.to_s)

      # ここが欠けると、CloudWatch はこの行をメトリクスとして読まない。
      document["Env"].should eq("prod")
      document["RefreshSuccess"].should eq(1)
    end

    it "時刻をミリ秒で出す" do
      io = IO::Memory.new
      at = Time.utc(2026, 9, 2, 12, 0, 0)
      Runtime::Metrics.new("dev", io).success(at)

      # 秒で出すと 1970 年の値として捨てられる。
      JSON.parse(io.to_s)["_aws"]["Timestamp"].should eq(at.to_unix_ms)
    end

    it "書き出せなくても例外を外に出さない" do
      io = IO::Memory.new
      io.close

      # ここで例外が漏れると、配信まで終えた実行が失敗として報告される。
      Runtime::Metrics.new("dev", io).success
    end
  end
end
