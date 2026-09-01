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

  describe "簡単設定のプリセット（issue #45）" do
    # 係数を触っていない利用者に、選んだ覚えのないプリセットを表示しないための一致である。
    it "標準は Defaults の既定値と同じである" do
      Config::DynamicTimeout::PRESETS["standard"].should eq Config::Defaults.new.dynamic_timeout
    end

    # 段階の順に長くならないと、長いほうへ選び直したのに短くなる文字数ができる。
    # 4 つの係数が絡むため、係数を 1 つ変えたときに順序が崩れても目では気付けない。
    it "どの文字数でも段階の順に表示時間が長くなる" do
      presets = Config::DynamicTimeout::PRESET_NAMES.map { |name| Config::DynamicTimeout::PRESETS[name] }

      [0, 20, 35, 78, 100, 200, 500, 5000].each do |count|
        seconds = presets.map(&.seconds_for(count))
        seconds.should eq(seconds.sort), "#{count} 文字で段階の順に並んでいない: #{seconds}"
      end
    end

    it "係数の組からプリセットの名前を引ける" do
      Config::DynamicTimeout::PRESETS.each do |name, preset|
        preset.preset_name.should eq name
      end
    end

    # 手で書いた係数はどの段階とも一致しない。画面はこの nil をカスタムの表示に使う。
    it "どのプリセットとも一致しない係数では名前を返さない" do
      Config::DynamicTimeout.new(base: 2.0, reading_speed: 12.0, min: 3.0, max: 14.0).preset_name.should be_nil
    end
  end
end

describe Config::Defaults do
  # 設定ファイルを持たない利用者に何が起こるかを決めるのはここである。
  # 既定値の変更は設定ファイルの差分に現れず、書き換えても気付かれにくいため固定しておく。
  it "表示時間は固定の 1 秒、透明度はわずかに透ける（issue #22）" do
    defaults = Config::Defaults.new.to_resolved

    defaults.timeout_mode.should eq Config::TimeoutMode::Fixed
    defaults.timeout.should eq 1.0
    defaults.opacity.should eq 0.75
  end

  # 既定を fixed にしても dynamic の係数は残す。切り替えたときにそのまま使う。
  it "dynamic の係数は既定を持ち続ける" do
    dynamic = Config::Defaults.new.dynamic_timeout

    dynamic.base.should eq 2.0
    dynamic.reading_speed.should eq 12.0
    dynamic.min.should eq 3.0
    dynamic.max.should eq 15.0
  end
end
