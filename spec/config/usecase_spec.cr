require "../spec_helper"

private def usecase(stored : String? = nil, existing_files = [] of String)
  repository = Fakes::ConfigRepository.new(stored)
  repository.existing_files = existing_files
  target = Config::Usecase.new(repository)
  # composition root と同じく、組み立てられるシンクの検証を登録する。
  target.register_validator("sinks.xsoverlay") { |section| XSOverlay::Settings.validate(section) }
  {target, repository}
end

describe Config::Usecase do
  describe "#load" do
    it "設定ファイルが無ければ初期設定を書き出す" do
      target, repository = usecase
      target.load.should be_empty

      repository.save_count.should eq 1
      target.current.sinks.keys.should eq ["xsoverlay"]
    end

    it "壊れた JSON では直前の有効な設定を維持する" do
      target, _ = usecase(%({"defaults": ))
      before = target.current

      errors = target.load

      errors.should_not be_empty
      target.current.should be before
    end
  end

  describe "#reload" do
    it "不正な設定を読んだら直前の有効な設定を維持する" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      applied = [] of Config::Root
      target.on_apply = ->(root : Config::Root) { applied << root; nil }

      repository.stored = %({"sinks": {}})
      errors = target.reload

      errors.should_not be_empty
      applied.should be_empty
      target.current.sinks.keys.should eq ["xsoverlay"]
    end
  end

  describe "#save" do
    it "検証を通った設定だけを保存し、スナップショットを差し替える" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      applied = [] of Config::Root
      target.on_apply = ->(root : Config::Root) { applied << root; nil }

      updated = Config::Root.default
      updated.defaults.volume = 0.9

      target.save(updated).should be_empty
      applied.size.should eq 1
      target.current.defaults.volume.should eq 0.9
      repository.save_count.should eq 1
    end

    it "保存しても、それ以前に取り出したスナップショットは変わらない" do
      target, _ = usecase(Config::Root.default.to_json)
      target.load
      before = target.current

      updated = Config::Root.default
      updated.defaults.volume = 0.9
      target.save(updated).should be_empty

      before.defaults.volume.should eq 0.5
      target.current.should_not be before
    end

    it "検証エラーがあるときは保存も反映もしない" do
      target, repository = usecase(Config::Root.default.to_json)
      target.load
      saved_before = repository.save_count

      invalid = Config::Root.default
      invalid.defaults.volume = 2.0

      target.save(invalid).should_not be_empty
      repository.save_count.should eq saved_before
      target.current.defaults.volume.should eq 0.5
    end
  end

  describe "#validate" do
    it "全シンクが無効な設定を弾く" do
      target, _ = usecase
      root = Config::Root.from_json(%({"sinks": {"xsoverlay": {"enabled": false}}}))

      target.validate(root).map(&.section).should contain "通知先"
    end

    it "シンクが 1 つも無い設定を弾く" do
      target, _ = usecase

      target.validate(Config::Root.from_json("{}")).should_not be_empty
    end

    it "組み立てられないシンクだけが有効な設定を弾く" do
      target, _ = usecase
      root = Config::Root.from_json(<<-JSON)
        {"sinks": {"xsoverlay": {"enabled": false}, "discord_webhook": {"enabled": true}}}
        JSON

      target.validate(root).map(&.section).should contain "通知先"
    end

    it "数値範囲を外れた項目を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.opacity = 1.5
      root.defaults.timeout = 0.0

      messages = target.validate(root).map(&.message)
      messages.any?(&.includes?("opacity")).should be_true
      messages.any?(&.includes?("timeout")).should be_true
    end

    it "存在しない音声ファイルを指したルールを弾く" do
      target, _ = usecase
      root = Config::Root.default
      rule = Config::Rule.new("com.squirrel.Discord")
      rule.sound = "C:/sounds/missing.wav"
      root.rules << rule

      target.validate(root).map(&.message).any?(&.includes?("sound")).should be_true
    end

    it "存在する音声ファイルは通す" do
      target, _ = usecase(existing_files: ["C:/sounds/discord.wav"])
      root = Config::Root.default
      rule = Config::Rule.new("com.squirrel.Discord")
      rule.sound = "C:/sounds/discord.wav"
      root.rules << rule

      target.validate(root).should be_empty
    end

    it "空文字列の sound はミュートとして通す" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.sound = ""

      target.validate(root).should be_empty
    end

    it "match_app_id が空のルールを弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.rules << Config::Rule.new("")

      target.validate(root).map(&.message).any?(&.includes?("match_app_id")).should be_true
    end

    it "アダプタが登録した検証をセクションごとに呼ぶ" do
      target, _ = usecase
      root = Config::Root.from_json(%({"sinks": {"xsoverlay": {"enabled": true, "websocket_port": 0}}}))

      target.validate(root).map(&.message).any?(&.includes?("websocket_port")).should be_true
    end

    it "dynamic_timeout の上下限が正でない設定を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.dynamic_timeout = Config::DynamicTimeout.new(base: 2.0, reading_speed: 12.0, min: -10.0, max: -5.0)

      messages = target.validate(root).map(&.message)
      messages.any?(&.includes?("dynamic_timeout.min")).should be_true
      messages.any?(&.includes?("dynamic_timeout.max")).should be_true
    end

    it "max_body_length が上限を超えた設定を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.defaults.max_body_length = Config::MAX_BODY_LENGTH_RANGE.end + 1

      target.validate(root).map(&.message).any?(&.includes?("max_body_length")).should be_true
    end

    it "未知の log_level を弾く" do
      target, _ = usecase
      root = Config::Root.default
      root.log_level = "verbose"

      target.validate(root).map(&.message).any?(&.includes?("log_level")).should be_true
    end
  end
end
