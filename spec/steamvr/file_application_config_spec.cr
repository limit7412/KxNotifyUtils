require "../spec_helper"
require "../../src/steamvr/file_application_config"

# SteamVR の設定ファイルを組み立てるところだけを確かめる。
# 実際の読み書きと置き場所の解決は Windows の実機でしか確かめられない（issue #12）。
describe SteamVR::FileApplicationConfig do
  describe ".with_manifest" do
    it "ファイルが無ければ manifest_paths を作る" do
      json = JSON.parse(SteamVR::FileApplicationConfig.with_manifest(nil, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.map(&.as_s).should eq ["C:\\a\\x.vrmanifest"]
    end

    it "既にある一覧へ足す" do
      source = %({"manifest_paths":["C:\\\\other.vrmanifest"]})

      json = JSON.parse(SteamVR::FileApplicationConfig.with_manifest(source, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.map(&.as_s).should eq [
        "C:\\other.vrmanifest",
        "C:\\a\\x.vrmanifest",
      ]
    end

    # 他のアプリの登録を消すと、利用者は SteamVR 側で登録し直すことになる。
    it "manifest_paths 以外の項目を残す" do
      source = %({"other_key":{"nested":1},"manifest_paths":[]})

      json = JSON.parse(SteamVR::FileApplicationConfig.with_manifest(source, "C:\\a\\x.vrmanifest"))

      json["other_key"]["nested"].as_i.should eq 1
    end

    it "同じパスを重ねない" do
      source = %({"manifest_paths":["C:\\\\a\\\\x.vrmanifest"]})

      json = JSON.parse(SteamVR::FileApplicationConfig.with_manifest(source, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.size.should eq 1
    end

    # Windows のパスは大文字小文字を区別せず、区切りも混在しうる。
    # 別物として足すと、同じマニフェストが 2 行並ぶ。
    it "大文字小文字と区切りの違いを同じパスとして扱う" do
      source = %({"manifest_paths":["c:/A/X.VRMANIFEST"]})

      json = JSON.parse(SteamVR::FileApplicationConfig.with_manifest(source, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.size.should eq 1
    end

    # 読めないものを空として扱うと、入っていた他のアプリの登録を丸ごと消す。
    it "読めない内容なら投げる" do
      expect_raises(JSON::ParseException) do
        SteamVR::FileApplicationConfig.with_manifest("{壊れている", "C:\\a\\x.vrmanifest")
      end
    end
  end

  describe ".without_manifest" do
    it "一覧から外す" do
      source = %({"manifest_paths":["C:\\\\other.vrmanifest","C:\\\\a\\\\x.vrmanifest"]})

      json = JSON.parse(SteamVR::FileApplicationConfig.without_manifest(source, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.map(&.as_s).should eq ["C:\\other.vrmanifest"]
    end

    it "無いものを外そうとしても壊さない" do
      source = %({"manifest_paths":["C:\\\\other.vrmanifest"]})

      json = JSON.parse(SteamVR::FileApplicationConfig.without_manifest(source, "C:\\a\\x.vrmanifest"))

      json["manifest_paths"].as_a.map(&.as_s).should eq ["C:\\other.vrmanifest"]
    end
  end

  describe ".with_auto_launch" do
    it "ファイルが無ければ SteamVR が書くのと同じ形で作る" do
      json = JSON.parse(SteamVR::FileApplicationConfig.with_auto_launch(nil, true))

      json["autolaunch"].as_bool.should be_true
      json["last_launch_time"].as_s.should eq "0"
    end

    # SteamVR が持つ値である。書き換えると起動の記録を失う。
    it "既にある last_launch_time は残す" do
      source = %({"autolaunch":false,"last_launch_time":"1234"})

      json = JSON.parse(SteamVR::FileApplicationConfig.with_auto_launch(source, true))

      json["autolaunch"].as_bool.should be_true
      json["last_launch_time"].as_s.should eq "1234"
    end

    it "無効にもできる" do
      json = JSON.parse(SteamVR::FileApplicationConfig.with_auto_launch(%({"autolaunch":true}), false))

      json["autolaunch"].as_bool.should be_false
    end

    # このファイルは app_key ごとに 1 つで、中身は自動起動の状態だけである。
    # appconfig.json と違い、作り直しても他の登録を巻き込まない。
    it "読めない内容なら作り直す" do
      json = JSON.parse(SteamVR::FileApplicationConfig.with_auto_launch("{壊れている", true))

      json["autolaunch"].as_bool.should be_true
    end
  end

  describe ".auto_launch?" do
    it "有効なら真を返す" do
      SteamVR::FileApplicationConfig.auto_launch?(%({"autolaunch":true})).should be_true
    end

    it "無効なら偽を返す" do
      SteamVR::FileApplicationConfig.auto_launch?(%({"autolaunch":false})).should be_false
    end

    it "ファイルが無ければ偽を返す" do
      SteamVR::FileApplicationConfig.auto_launch?(nil).should be_false
    end

    # 読めないものを真と読むと、登録されていないのに「登録済み」と表示する。
    it "読めない内容なら偽を返す" do
      SteamVR::FileApplicationConfig.auto_launch?("{壊れている").should be_false
    end
  end
end
