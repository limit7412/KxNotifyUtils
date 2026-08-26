require "../spec_helper"
require "../../src/update/models"

# 版の比較は実機を要さずに確かめられる唯一の要である（issue #10）。
# ここが狂うと、新しい版を見落とすか、古い版へ戻せと言い出す。
describe Update::Version do
  describe ".parse?" do
    it "X.Y.Z を読む" do
      version = Update::Version.parse?("1.2.3").should_not be_nil
      version.major.should eq 1
      version.minor.should eq 2
      version.patch.should eq 3
      version.test.should be_nil
      version.stable?.should be_true
    end

    it "X.Y.Z-testN を読む" do
      version = Update::Version.parse?("0.0.2-test3").should_not be_nil
      version.patch.should eq 2
      version.test.should eq 3
      version.stable?.should be_false
    end

    # 手動で作る安定版のタグには v が付くことがある。
    it "先頭の v を受け付ける" do
      Update::Version.parse?("v1.0.0").should eq Update::Version.new(1, 0, 0)
    end

    # 手元ビルドの版。運用しているタグの綴りから外れており、比較が成り立たない。
    it "0.1.0-dev は版として読まない" do
      Update::Version.parse?("0.1.0-dev").should be_nil
    end

    it "綴りの違うものは読まない" do
      Update::Version.parse?("1.2").should be_nil
      Update::Version.parse?("1.2.3.4").should be_nil
      Update::Version.parse?("1.2.3-rc1").should be_nil
      Update::Version.parse?("").should be_nil
    end

    # 正規表現は桁数を見ない。to_i のまま呼ぶと例外になり、
    # 設定の読み込みの外で呼ぶ起動時の復元ごとアプリが落ちる。
    it "Int32 に収まらない数値は読まない" do
      Update::Version.parse?("999999999999999999999.0.0").should be_nil
      Update::Version.parse?("1.999999999999999999999.0").should be_nil
      Update::Version.parse?("1.0.999999999999999999999").should be_nil
      Update::Version.parse?("1.0.0-test999999999999999999999").should be_nil
    end

    it "ゼロ埋めされた -testN も数値として読む" do
      Update::Version.parse?("0.0.2-test007").try(&.test).should eq 7
    end
  end

  describe "#<=>" do
    # 比較の例では読めることを前提にしてよい。読めない綴りは .parse? の例で押さえてある。
    version = ->(text : String) { Update::Version.parse?(text).not_nil! }

    it "X.Y.Z を数値で比べる" do
      version.call("1.0.0").should be < version.call("1.0.1")
      version.call("1.9.0").should be < version.call("1.10.0")
      version.call("2.0.0").should be > version.call("1.99.99")
    end

    # SemVer のプレリリースと同じ扱いにする。
    it "同じ X.Y.Z なら安定版がプレリリースより新しい" do
      version.call("0.0.2-test1").should be < version.call("0.0.2")
    end

    it "プレリリースは番号順に並ぶ" do
      version.call("0.0.2-test2").should be < version.call("0.0.2-test10")
    end

    # プレリリースは次のパッチ版として作られるため、直前の安定版より新しい。
    it "プレリリースは 1 つ前の安定版より新しい" do
      version.call("0.0.1").should be < version.call("0.0.2-test1")
    end

    it "同じ版は等しい" do
      version.call("1.2.3").should eq version.call("1.2.3")
      version.call("1.2.3-test1").should eq version.call("1.2.3-test1")
    end
  end

  describe "#to_s" do
    it "読んだ綴りへ戻す" do
      Update::Version.parse?("1.2.3").not_nil!.to_s.should eq "1.2.3"
      Update::Version.parse?("0.0.2-test4").not_nil!.to_s.should eq "0.0.2-test4"
    end
  end
end

describe Update::Release do
  it "タグも GitHub の印もプレリリースでなければ安定版とみなす" do
    release = Update::Release.new(Update::Version.new(1, 0, 0), "1.0.0", "https://example.test")
    release.stable?.should be_true
  end

  # 綴りと印のどちらか一方でもプレリリースなら安定版のチャンネルでは拾わない。
  it "プレリリースの印が付いていれば安定版とみなさない" do
    release = Update::Release.new(
      Update::Version.new(1, 0, 0), "1.0.0", "https://example.test", prerelease: true)
    release.stable?.should be_false
  end

  it "タグが -testN なら安定版とみなさない" do
    release = Update::Release.new(
      Update::Version.new(1, 0, 0, 1), "1.0.0-test1", "https://example.test")
    release.stable?.should be_false
  end
end
