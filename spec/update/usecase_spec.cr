require "../spec_helper"
require "../../src/update/usecase"

private class FakeRepository < Update::Repository
  property releases : Array(Update::Release)
  property error : Exception?
  getter calls = 0

  def initialize(@releases = [] of Update::Release, @error = nil)
  end

  # 直近に渡されたチャンネル。stable と test でエンドポイントが分かれることの確認に使う。
  getter last_channel : String? = nil

  def fetch_releases(channel : String) : Array(Update::Release)
    @calls += 1
    @last_channel = channel
    if error = @error
      raise error
    end
    @releases
  end
end

private def release(tag : String, prerelease : Bool = false) : Update::Release
  version = Update::Version.parse?(tag).not_nil!
  Update::Release.new(version, tag, "https://example.test/#{tag}", prerelease)
end

describe Update::Usecase do
  describe "#check" do
    it "新しい安定版を見つける" do
      usecase = Update::Usecase.new(FakeRepository.new([release("0.0.1"), release("1.0.0")]))

      result = usecase.check("0.0.1", "stable")

      result.outcome.should eq Update::Outcome::Available
      result.release.try(&.tag).should eq "1.0.0"
      usecase.available("stable").try(&.tag).should eq "1.0.0"
    end

    it "実行中が最新なら UpToDate を返す" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      usecase.available("stable").should be_nil
    end

    # 応答の並び順に頼らない。GitHub は作成順に返すが、タグの新しさとは限らない。
    it "並び順ではなく版の新しさで選ぶ" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("2.0.0"), release("1.5.0")]))

      usecase.check("1.0.0", "stable").release.try(&.tag).should eq "2.0.0"
    end

    describe "チャンネル" do
      it "stable はプレリリースを拾わない" do
        usecase = Update::Usecase.new(
          FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))

        usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      end

      it "test はプレリリースも拾う" do
        usecase = Update::Usecase.new(
          FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))

        result = usecase.check("1.0.0", "test")
        result.outcome.should eq Update::Outcome::Available
        result.release.try(&.tag).should eq "1.0.1-test1"
      end
    end

    # 手元ビルドは運用しているタグの綴りから外れており、比べる相手が決まらない。
    it "版を読めない実行中の版では一覧すら取りに行かない" do
      repository = FakeRepository.new([release("1.0.0")])
      usecase = Update::Usecase.new(repository)

      usecase.check("0.1.0-dev", "stable").outcome.should eq Update::Outcome::Unknown
      repository.calls.should eq 0
    end

    # 回線が無い環境で起動するたびに知らせても対処のしようがない（issue #10）。
    it "一覧を取れなければ Unreachable を返し、確認済みにしない" do
      usecase = Update::Usecase.new(
        FakeRepository.new(error: Exception.new("つながらない")))

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::Unreachable
      usecase.checked?("stable").should be_false
    end

    it "一覧が空なら UpToDate を返す" do
      usecase = Update::Usecase.new(FakeRepository.new)

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
      usecase.checked?("stable").should be_true
    end

    # 新しい版を見つけた後で取り下げられることがある。表示に残し続けない。
    it "新しい版が消えたら available も下ろす" do
      repository = FakeRepository.new([release("2.0.0")])
      usecase = Update::Usecase.new(repository)
      usecase.check("1.0.0", "stable")
      usecase.available("stable").should_not be_nil

      repository.releases = [release("1.0.0")]
      usecase.check("1.0.0", "stable")

      usecase.available("stable").should be_nil
    end
  end

  # 設定を変えた直後に、別のチャンネルで確かめた結果が残っていてはならない。
  describe "チャンネルをまたいだ結果" do
    it "確認したチャンネルでしか結果を返さない" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))
      usecase.check("1.0.0", "test")

      usecase.available("test").try(&.tag).should eq "1.0.1-test1"
      usecase.available("stable").should be_nil
    end

    # test で確かめただけの状態を stable の「最新である」と読ませない。
    it "確認していないチャンネルは未確認として扱う" do
      usecase = Update::Usecase.new(FakeRepository.new([release("1.0.0")]))
      usecase.check("1.0.0", "stable")

      usecase.checked?("stable").should be_true
      usecase.checked?("test").should be_false
    end

    it "チャンネルを渡し直せば結果も入れ替わる" do
      usecase = Update::Usecase.new(
        FakeRepository.new([release("1.0.0"), release("1.0.1-test1", prerelease: true)]))
      usecase.check("1.0.0", "test")
      usecase.check("1.0.0", "stable")

      usecase.available("test").should be_nil
      usecase.checked?("stable").should be_true
    end

    # 安定版と test でエンドポイントが分かれるため、repository へそのまま渡す。
    it "チャンネルを repository へ渡す" do
      repository = FakeRepository.new([release("1.0.0")])
      usecase = Update::Usecase.new(repository)

      usecase.check("0.9.0", "test")

      repository.last_channel.should eq "test"
    end
  end

  describe "知らせ済みの版" do
    # 本体は SteamVR の自動起動で立ち上がる。
    # 覚えておかないと VR を始めるたびに同じ更新のバルーンが出る。
    it "復元すると同じ版を知らせ直さない" do
      usecase = Update::Usecase.new(FakeRepository.new([release("2.0.0")]))
      usecase.notified_tag = "2.0.0"

      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
    end

    it "知らせた版をタグとして取り出せる" do
      usecase = Update::Usecase.new(FakeRepository.new([release("2.0.0")]))
      usecase.notified_tag.should eq ""

      usecase.check_quietly("1.0.0", "stable")

      usecase.notified_tag.should eq "2.0.0"
    end

    # 設定を手で壊された場合。記録が無いものとして扱い、確認そのものは続ける。
    it "版として読めない記録は無視する" do
      usecase = Update::Usecase.new(FakeRepository.new([release("2.0.0")]))
      usecase.notified_tag = "こわれている"

      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::Available
    end

    it "復元した版より新しい版は知らせる" do
      usecase = Update::Usecase.new(FakeRepository.new([release("3.0.0")]))
      usecase.notified_tag = "2.0.0"

      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::Available
    end
  end

  describe "#check_quietly" do
    # 24 時間ごとの確認で同じ版を繰り返し知らせると、利用者の手が止まる。
    it "同じ版は一度しか Available にしない" do
      usecase = Update::Usecase.new(FakeRepository.new([release("2.0.0")]))

      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::Available
      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::UpToDate
    end

    it "さらに新しい版が出たら改めて知らせる" do
      repository = FakeRepository.new([release("2.0.0")])
      usecase = Update::Usecase.new(repository)
      usecase.check_quietly("1.0.0", "stable")

      repository.releases = [release("3.0.0")]

      usecase.check_quietly("1.0.0", "stable").outcome.should eq Update::Outcome::Available
    end

    # 手動の確認は知らせ済みでも結末を返す。押して黙るのは無反応と区別が付かない。
    it "知らせ済みでも check は Available を返す" do
      usecase = Update::Usecase.new(FakeRepository.new([release("2.0.0")]))
      usecase.check_quietly("1.0.0", "stable")

      usecase.check("1.0.0", "stable").outcome.should eq Update::Outcome::Available
    end
  end
end
