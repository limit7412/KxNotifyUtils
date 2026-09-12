require "../spec_helper"

describe ServiceStatus::Settings do
  it "既定では VRChat と YouTube と Steam だけを知らせる（issue #5）" do
    settings = ServiceStatus::Settings.new

    settings.enabled.should be_true
    settings.polling_interval_s.should eq 60
    settings.service_enabled?("vrchat").should be_true
    settings.service_enabled?("youtube").should be_true
    settings.service_enabled?("steam").should be_true
    settings.service_enabled?("discord").should be_false
    settings.service_enabled?("booth").should be_false
  end

  it "services に書かれていない id は無効として扱う" do
    settings = ServiceStatus::Settings.from_json(%({"services": {"vrchat": true}}))

    settings.service_enabled?("vrchat").should be_true
    settings.service_enabled?("youtube").should be_false
    settings.service_enabled?("new_service").should be_false
  end

  # 初期設定は config/models に JSON として書いてある。
  # ここの既定を変えたときに、書き出す初期設定だけが古いままにならないようにする。
  it "初期設定に書き出すセクションは Settings の既定と一致する" do
    section = Config::Root.default.source("service_status").should_not be_nil

    ServiceStatus::Settings.validate(section).should be_empty
    ServiceStatus::Settings.from_section(section).to_json.should eq ServiceStatus::Settings.new.to_json
  end

  it "セクションが無ければ既定値になる" do
    settings = ServiceStatus::Settings.from_section(nil)

    settings.feed_url.should eq ServiceStatus::Settings::DEFAULT_FEED_URL
  end

  describe ".validate" do
    it "既定の設定は妥当である" do
      ServiceStatus::Settings.validate(JSON.parse(ServiceStatus::Settings.new.to_json)).should be_empty
    end

    it "ポーリング間隔の範囲外を弾く" do
      errors = ServiceStatus::Settings.validate(JSON.parse(%({"polling_interval_s": 5})))
      errors.size.should eq 1
      errors.first.should contain "polling_interval_s"
    end

    it "URL でない feed_url を弾く" do
      ServiceStatus::Settings.validate(JSON.parse(%({"feed_url": "status.json"}))).should_not be_empty
      ServiceStatus::Settings.validate(JSON.parse(%({"feed_url": "ftp://example.test/x"}))).should_not be_empty
      ServiceStatus::Settings.validate(JSON.parse(%({"feed_url": "http://localhost:8000/status.json"}))).should be_empty
    end

    it "書式が壊れていれば 1 件のエラーにする" do
      errors = ServiceStatus::Settings.validate(JSON.parse(%({"services": ["vrchat"]})))
      errors.size.should eq 1
      errors.first.should contain "書式"
    end
  end
end

describe ServiceStatus::Feed do
  it "配信 JSON から判定に使う項目を読む" do
    feed = ServiceStatus::Feed.from_json(<<-JSON)
      {
        "v": 1,
        "generated_unix": 1700000000,
        "generated_jst": "2023/11/15 07:13",
        "stale": false,
        "services": [
          {"id": "vrchat", "name": "VRChat", "level": 1, "label": "Degraded", "note": "Login: Partial Outage",
           "source": "official", "url": "https://status.vrchat.com", "checked_unix": 1700000000,
           "components": [{"name": "Authentication / Login", "level": 1}]}
        ]
      }
      JSON

    feed.supported?.should be_true
    feed.generated_unix.should eq 1700000000
    feed.stale?.should be_false
    feed.services.size.should eq 1
    feed.services.first.level_enum.should eq ServiceStatus::Level::Degraded
    feed.services.first.note.should eq "Login: Partial Outage"
  end

  it "範囲外の level は判定不能として読む" do
    ServiceStatus::Level.from_level(9).should eq ServiceStatus::Level::Unknown
    ServiceStatus::Level.from_level(-1).should eq ServiceStatus::Level::Unknown
  end

  it "v が無い配信は読めない版として扱う" do
    ServiceStatus::Feed.from_json(%({"services": []})).supported?.should be_false
  end
end
