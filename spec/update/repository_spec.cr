require "../spec_helper"
require "../../src/update/repository"

# 応答の読み取りだけを確かめる。実際の通信は Windows の実機でしか確かめられない（issue #10）。

private def asset_for(body : String) : Update::Asset
  Update::Asset.new(Digest::SHA256.hexdigest(body), "https://example.test/asset", body.bytesize.to_i64)
end

# 実ファイルを触る確認のための置き場所。使い終わったら消す。
private def with_temporary_path(& : String -> Nil) : Nil
  path = File.join(Dir.tempdir, "kxnotifyutils-spec-#{Random::Secure.hex(8)}")
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

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

  # 一覧と /releases/latest を合わせて候補にする。
  # 一覧だけでは範囲から落ちた安定版を拾えず、
  # latest だけでは版番号が最大とは限らない（作成順で最も新しいものが返る）。
  describe ".merge" do
    it "一覧に無いものを足す" do
      list = [
        Update::Release.new(Update::Version.new(1, 5, 1), "1.5.1", "https://example.test/1.5.1"),
      ]
      latest = [
        Update::Release.new(Update::Version.new(2, 0, 0), "2.0.0", "https://example.test/2.0.0"),
      ]

      Update::GitHubRepository.merge(list, latest).map(&.tag).should eq ["1.5.1", "2.0.0"]
    end

    it "同じタグは重ねない" do
      release = Update::Release.new(
        Update::Version.new(1, 0, 0), "1.0.0", "https://example.test/1.0.0")

      Update::GitHubRepository.merge([release], [release]).map(&.tag).should eq ["1.0.0"]
    end

    it "足すものが無ければ一覧のままである" do
      release = Update::Release.new(
        Update::Version.new(1, 0, 0), "1.0.0", "https://example.test/1.0.0")

      Update::GitHubRepository.merge([release], [] of Update::Release).size.should eq 1
    end
  end

  # 一覧を最後まで取れたなら latest は要らない（issue #30）。
  # /releases は下書き以外のすべてを返すため、latest はその中に必ず含まれる。
  # 取りに行ったかどうかで確かめる。要求を 1 つ減らすことがこの分岐の目的だからである。
  describe ".catalog" do
    it "最後まで取れていれば latest を取りに行かない" do
      listed = [
        Update::Release.new(Update::Version.new(1, 0, 0), "1.0.0", "https://example.test/1.0.0"),
      ]
      asked = false

      catalog = Update::GitHubRepository.catalog(listed, true) do
        asked = true
        [] of Update::Release
      end

      asked.should be_false
      catalog.complete?.should be_true
      catalog.releases.map(&.tag).should eq ["1.0.0"]
    end

    it "切れていれば latest を取りに行って足す" do
      listed = [
        Update::Release.new(Update::Version.new(1, 5, 1), "1.5.1", "https://example.test/1.5.1"),
      ]
      asked = false

      catalog = Update::GitHubRepository.catalog(listed, false) do
        asked = true
        [Update::Release.new(Update::Version.new(2, 0, 0), "2.0.0", "https://example.test/2.0.0")]
      end

      asked.should be_true
      catalog.complete?.should be_false
      catalog.releases.map(&.tag).should eq ["1.5.1", "2.0.0"]
    end

    it "切れていて latest が一覧と同じなら重ねない" do
      release = Update::Release.new(
        Update::Version.new(1, 0, 0), "1.0.0", "https://example.test/1.0.0")

      catalog = Update::GitHubRepository.catalog([release], false) { [release] }

      catalog.releases.map(&.tag).should eq ["1.0.0"]
    end
  end

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

  describe "アセットの読み取り" do
    it "名前と digest が揃ったアセットを拾う" do
      releases = Update::GitHubRepository.parse(%([{
        "tag_name": "1.0.0",
        "html_url": "https://example.test/1.0.0",
        "assets": [{
          "name": "KxNotifyUtils.exe",
          "browser_download_url": "https://example.test/download/KxNotifyUtils.exe",
          "digest": "sha256:#{"a" * 64}",
          "size": 1024
        }]
      }]))

      asset = releases.first.asset.not_nil!
      asset.digest.should eq "a" * 64
      asset.url.should eq "https://example.test/download/KxNotifyUtils.exe"
      asset.size.should eq 1024
    end

    # 取ってきたものがそのリリースのものか確かめられない。
    # 実行ファイルを置き換える操作であり、確かめずに進むわけにはいかない。
    it "digest の無いアセットは扱わない" do
      releases = Update::GitHubRepository.parse(%([{
        "tag_name": "1.0.0",
        "html_url": "https://example.test/1.0.0",
        "assets": [{
          "name": "KxNotifyUtils.exe",
          "browser_download_url": "https://example.test/download/KxNotifyUtils.exe",
          "size": 1024
        }]
      }]))

      releases.first.asset.should be_nil
    end

    it "名前の違うアセットは扱わない" do
      releases = Update::GitHubRepository.parse(%([{
        "tag_name": "1.0.0",
        "html_url": "https://example.test/1.0.0",
        "assets": [{
          "name": "KxNotifyUtils.zip",
          "browser_download_url": "https://example.test/download/KxNotifyUtils.zip",
          "digest": "sha256:#{"a" * 64}",
          "size": 1024
        }]
      }]))

      releases.first.asset.should be_nil
    end

    # アップロードの途中のものを掴むと、宣言された大きさに届かない。
    it "アップロードの済んでいないアセットは扱わない" do
      releases = Update::GitHubRepository.parse(%([{
        "tag_name": "1.0.0",
        "html_url": "https://example.test/1.0.0",
        "assets": [{
          "name": "KxNotifyUtils.exe",
          "browser_download_url": "https://example.test/download/KxNotifyUtils.exe",
          "digest": "sha256:#{"a" * 64}",
          "size": 1024,
          "state": "starter"
        }]
      }]))

      releases.first.asset.should be_nil
    end

    it "アセットが無いリリースも読める" do
      releases = Update::GitHubRepository.parse(
        %([{"tag_name": "1.0.0", "html_url": "https://example.test/1.0.0"}]))

      releases.first.asset.should be_nil
    end
  end

  describe ".store" do
    it "digest が合えば書き出す" do
      with_temporary_path do |path|
        body = "KxNotifyUtils"
        Update::GitHubRepository.store(IO::Memory.new(body), asset_for(body), path)

        File.read(path).should eq body
      end
    end

    # 途中まで落ちたものを残しても、次に使えるわけではない。
    it "digest が合わなければ書きかけを残さない" do
      with_temporary_path do |path|
        asset = Update::Asset.new("b" * 64, "https://example.test/asset", 13_i64)

        expect_raises(Exception, /digest/) do
          Update::GitHubRepository.store(IO::Memory.new("KxNotifyUtils"), asset, path)
        end

        File.exists?(path).should be_false
      end
    end

    it "宣言より短ければ書きかけを残さない" do
      with_temporary_path do |path|
        body = "KxNotifyUtils"
        asset = Update::Asset.new(Digest::SHA256.hexdigest(body), "https://example.test/asset", 99_i64)

        expect_raises(Exception, /大きさ/) do
          Update::GitHubRepository.store(IO::Memory.new(body), asset, path)
        end

        File.exists?(path).should be_false
      end
    end

    # 宣言を超えた分まで受け取ってから気付くと、その間ディスクを埋め続ける。
    it "宣言を超えたら読み切らずに打ち切る" do
      with_temporary_path do |path|
        asset = Update::Asset.new("a" * 64, "https://example.test/asset", 4_i64)

        expect_raises(Exception, /超えた/) do
          Update::GitHubRepository.store(IO::Memory.new("KxNotifyUtils"), asset, path)
        end

        File.exists?(path).should be_false
      end
    end
  end

  describe ".redirect_target" do
    it "相対の Location を絶対へ直す" do
      response = HTTP::Client::Response.new(302, headers: HTTP::Headers{"Location" => "/moved"})

      Update::GitHubRepository.redirect_target(response, URI.parse("https://example.test/asset"))
        .should eq "https://example.test/moved"
    end

    it "リダイレクトでなければ nil を返す" do
      response = HTTP::Client::Response.new(200)

      Update::GitHubRepository.redirect_target(response, URI.parse("https://example.test/asset"))
        .should be_nil
    end

    it "Location が無ければ例外にする" do
      response = HTTP::Client::Response.new(302)

      expect_raises(Exception, /Location/) do
        Update::GitHubRepository.redirect_target(response, URI.parse("https://example.test/asset"))
      end
    end
  end
end
