require "../spec_helper"

describe Config::Root do
  describe "#resolve_rule" do
    it "マッチするルールが無ければ defaults をそのまま使う" do
      root = Config::Root.from_json(<<-JSON)
        {"defaults": {"volume": 0.4, "sound": "default"}, "rules": []}
        JSON

      resolved = root.resolve_rule("com.example.App")
      resolved.volume.should eq 0.4
      resolved.sound.should eq "default"
      resolved.title_template.should eq "{app_name}: {title}"
    end

    it "ルールが指定した項目だけを上書きし、残りは defaults を継承する" do
      root = Config::Root.from_json(<<-JSON)
        {
          "defaults": {"timeout_mode": "dynamic", "volume": 0.5, "sound": "default", "opacity": 1.0},
          "rules": [{"match_app_id": "com.squirrel.Discord", "volume": 0.8, "sound": "C:/sounds/discord.wav"}]
        }
        JSON

      resolved = root.resolve_rule("com.squirrel.Discord.Discord")
      resolved.volume.should eq 0.8
      resolved.sound.should eq "C:/sounds/discord.wav"
      resolved.opacity.should eq 1.0
      resolved.timeout_mode.should eq Config::TimeoutMode::Dynamic
    end

    it "dynamic_timeout は書いた係数だけを上書きし、残りは defaults を継承する" do
      root = Config::Root.from_json(<<-JSON)
        {
          "defaults": {"dynamic_timeout": {"base": 2.0, "reading_speed": 12, "min": 3.0, "max": 15.0}},
          "rules": [{"match_app_id": "com.example", "dynamic_timeout": {"base": 5.0}}]
        }
        JSON

      dynamic = root.resolve_rule("com.example.App").dynamic_timeout
      dynamic.base.should eq 5.0
      dynamic.reading_speed.should eq 12.0
      dynamic.min.should eq 3.0
      dynamic.max.should eq 15.0
    end

    it "defaults を変えると、ルールが上書きしていない係数は追従する" do
      root = Config::Root.from_json(<<-JSON)
        {
          "defaults": {"dynamic_timeout": {"base": 2.0, "reading_speed": 12, "min": 3.0, "max": 15.0}},
          "rules": [{"match_app_id": "com.example", "dynamic_timeout": {"base": 5.0}}]
        }
        JSON
      root.defaults.dynamic_timeout = Config::DynamicTimeout.new(
        base: 2.0, reading_speed: 20.0, min: 3.0, max: 15.0)

      dynamic = root.resolve_rule("com.example.App").dynamic_timeout
      dynamic.base.should eq 5.0
      dynamic.reading_speed.should eq 20.0
    end

    it "先に書いたルールが勝つ" do
      root = Config::Root.from_json(<<-JSON)
        {
          "rules": [
            {"match_app_id": "com.example", "volume": 0.1},
            {"match_app_id": "com.example.App", "volume": 0.9}
          ]
        }
        JSON

      root.resolve_rule("com.example.App").volume.should eq 0.1
    end

    it "match_app_id が空のルールはどの app_id にもマッチしない" do
      root = Config::Root.from_json(%({"rules": [{"match_app_id": "", "volume": 0.9}]}))
      root.resolve_rule("com.example.App").volume.should eq 0.5
    end
  end

  describe "前方互換" do
    it "sources と sinks に未知のキーがあっても既知のキーを読める" do
      root = Config::Root.from_json(<<-JSON)
        {
          "sources": {"windows": {"enabled": true, "polling_interval_ms": 250}, "vrchat_log": {"enabled": true}},
          "sinks": {"xsoverlay": {"enabled": true}, "discord_webhook": {"enabled": false}}
        }
        JSON

      settings = WinNotification::Settings.from_section(root.source("windows"))
      settings.polling_interval_ms.should eq 250
      root.sources.keys.should contain "vrchat_log"
      root.sinks.keys.should contain "discord_webhook"
    end

    it "未知のトップレベルキーがあっても読み込める" do
      root = Config::Root.from_json(%({"log_level": "debug", "future_section": {"a": 1}}))
      root.log_level.should eq "debug"
    end
  end

  it "書き出した JSON をそのまま読み戻せる" do
    root = Config::Root.default
    root.defaults.timeout_mode = Config::TimeoutMode::Fixed
    root.filter.mode = Config::FilterMode::Whitelist

    restored = Config::Root.from_json(root.to_json)
    restored.defaults.timeout_mode.should eq Config::TimeoutMode::Fixed
    restored.filter.mode.should eq Config::FilterMode::Whitelist
  end

  describe "#with_steamvr" do
    it "元のスナップショットを書き換えずに新しいスナップショットを返す" do
      root = Config::Root.default
      updated = root.with_steamvr(true, "D:/tools/KxNotifyUtils.exe")

      updated.steamvr.auto_launch_registered.should be_true
      updated.steamvr.last_exe_path.should eq "D:/tools/KxNotifyUtils.exe"
      root.steamvr.auto_launch_registered.should be_false
      root.steamvr.last_exe_path.should eq ""
    end

    it "登録について決着がついたことを記録する" do
      root = Config::Root.default
      root.steamvr.auto_launch_configured.should be_false

      # 解除も決着の 1 つであり、次回起動時に自動で登録し直さない印になる。
      unregistered = root.with_steamvr(false, "")
      unregistered.steamvr.auto_launch_configured.should be_true
      unregistered.steamvr.auto_launch_registered.should be_false
    end
  end
end

describe Config::Filter do
  it "blacklist では app_id が前方一致したものを落とす" do
    filter = Config::Filter.from_json(%({"mode": "blacklist", "apps": ["Microsoft.Windows.Explorer"]}))
    filter.allow?("Microsoft.Windows.Explorer").should be_false
    filter.allow?("Microsoft.Windows.Explorer.Sub").should be_false
    filter.allow?("com.squirrel.Discord").should be_true
  end

  it "whitelist では app_id が前方一致したものだけを通す" do
    filter = Config::Filter.from_json(%({"mode": "whitelist", "apps": ["com.squirrel.Discord"]}))
    filter.allow?("com.squirrel.Discord.Discord").should be_true
    filter.allow?("Microsoft.OutlookForWindows").should be_false
  end
end

describe Config::DynamicTimeout do
  it "文字数から表示時間を求め、min と max でクランプする" do
    dynamic = Config::DynamicTimeout.new(base: 2.0, reading_speed: 12.0, min: 3.0, max: 15.0)

    dynamic.seconds_for(0).should eq 3.0
    dynamic.seconds_for(120).should eq 12.0
    dynamic.seconds_for(1000).should eq 15.0
  end
end
