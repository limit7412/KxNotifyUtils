require "../spec_helper"
require "../../src/update/repository"

# 応答の読み取りだけを確かめる。実際の通信は Windows の実機でしか確かめられない（issue #10）。
describe Update::GitHubRepository do
  describe ".parse" do
    it "タグと URL とプレリリースの印を読む" do
      releases = Update::GitHubRepository.parse(<<-JSON)
        [
          {"tag_name": "1.0.0", "html_url": "https://example.test/1.0.0",
           "prerelease": false, "draft": false},
          {"tag_name": "1.0.1-test1", "html_url": "https://example.test/1.0.1-test1",
           "prerelease": true, "draft": false}
        ]
        JSON

      releases.size.should eq 2
      releases[0].tag.should eq "1.0.0"
      releases[0].url.should eq "https://example.test/1.0.0"
      releases[0].stable?.should be_true
      releases[1].prerelease.should be_true
    end

    # 下書きはまだ公開されていない。案内した先が 404 になる。
    it "下書きは捨てる" do
      releases = Update::GitHubRepository.parse(
        %([{"tag_name": "9.9.9", "html_url": "https://example.test/x", "draft": true}]))

      releases.should be_empty
    end

    # 運用しているタグの綴りから外れたものは版として比べられない。
    it "版として読めないタグは捨てる" do
      releases = Update::GitHubRepository.parse(<<-JSON)
        [
          {"tag_name": "nightly", "html_url": "https://example.test/nightly"},
          {"tag_name": "1.0.0", "html_url": "https://example.test/1.0.0"}
        ]
        JSON

      releases.map(&.tag).should eq ["1.0.0"]
    end

    it "リリースが無ければ空を返す" do
      Update::GitHubRepository.parse("[]").should be_empty
    end

    # prerelease と draft は省略されうる。既定値で読めないと確認そのものが落ちる。
    it "印が書かれていなくても読める" do
      releases = Update::GitHubRepository.parse(
        %([{"tag_name": "1.0.0", "html_url": "https://example.test/1.0.0"}]))

      releases.size.should eq 1
      releases[0].stable?.should be_true
    end
  end

  # stable のチャンネルは /releases/latest を使う。
  # 一覧はプレリリースが 20 件積まれると安定版が 1 ページ目から落ちるためである。
  describe ".parse_one" do
    it "1 件の応答を読む" do
      releases = Update::GitHubRepository.parse_one(
        %({"tag_name": "1.0.0", "html_url": "https://example.test/1.0.0"}))

      releases.map(&.tag).should eq ["1.0.0"]
    end

    it "版として読めないタグなら空を返す" do
      releases = Update::GitHubRepository.parse_one(
        %({"tag_name": "nightly", "html_url": "https://example.test/nightly"}))

      releases.should be_empty
    end
  end
end
