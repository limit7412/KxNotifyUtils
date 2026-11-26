require "../spec_helper"

describe Status::Level do
  it "assigns the numbers defined by the specification" do
    Status::Level::Operational.value.should eq 0
    Status::Level::Degraded.value.should eq 1
    Status::Level::MajorOutage.value.should eq 2
    Status::Level::Unknown.value.should eq 3
  end

  it "exposes the label carried by the feed" do
    Status::Level::Operational.label.should eq "Operational"
    Status::Level::MajorOutage.label.should eq "Major Outage"
    Status::Level::Unknown.label.should eq "Unknown"
  end
end

describe Status::SourceKind do
  it "renders the strings used by the feed" do
    Status::SourceKind::Official.key.should eq "official"
    Status::SourceKind::Synthetic.key.should eq "synthetic"
  end
end

describe Status::History do
  it "keeps only the three most recent outcomes" do
    history = Status::History.new
      .push(Status::Outcome::Success)
      .push(Status::Outcome::Failure)
      .push(Status::Outcome::Failure)
      .push(Status::Outcome::Success)

    history.outcomes.should eq [
      Status::Outcome::Failure,
      Status::Outcome::Failure,
      Status::Outcome::Success,
    ]
  end

  it "counts failures" do
    history = Status::History.new
      .push(Status::Outcome::Failure)
      .push(Status::Outcome::Success)
      .push(Status::Outcome::Failure)

    history.failure_count.should eq 2
  end

  it "reports indeterminate only for the latest outcome" do
    Status::History.new
      .push(Status::Outcome::Indeterminate)
      .indeterminate?.should be_true

    Status::History.new
      .push(Status::Outcome::Indeterminate)
      .push(Status::Outcome::Success)
      .indeterminate?.should be_false
  end
end

describe Status::ServiceStatus do
  describe ".format_note" do
    it "removes newlines and control characters" do
      Status::ServiceStatus.format_note("API\nWebsocket\tdown").should eq "APIWebsocketdown"
    end

    it "keeps a note that fits in 40 full-width characters" do
      note = "あ" * 40

      Status::ServiceStatus.format_note(note).should eq note
    end

    it "truncates a note longer than 40 full-width characters" do
      Status::ServiceStatus.format_note("あ" * 41).should eq "あ" * 40
    end

    it "counts half-width characters as half" do
      note = "a" * 80

      Status::ServiceStatus.format_note(note).should eq note
      Status::ServiceStatus.format_note("a" * 81).should eq note
    end

    it "does not split a full-width character at the boundary" do
      Status::ServiceStatus.format_note("a" + "あ" * 40).should eq "a" + "あ" * 39
    end
  end

  it "derives the feed fields from the level and the source" do
    service = Status::ServiceStatus.new(
      id: "vrchat",
      name: "VRChat",
      level: Status::Level::Degraded,
      source: Status::SourceKind::Official,
      url: "https://status.vrchat.com",
      checked_at: Time.unix(1756123180),
      note: "Websocket: Partial Outage",
    )

    service.level.should eq 1
    service.label.should eq "Degraded"
    service.source.should eq "official"
    service.checked_unix.should eq 1756123180
  end

  it "omits components when the source has none" do
    service = Status::ServiceStatus.new(
      id: "youtube",
      name: "YouTube",
      level: Status::Level::Operational,
      source: Status::SourceKind::Synthetic,
      url: "https://www.youtube.com",
      checked_at: Time.unix(1756123185),
    )

    JSON.parse(service.to_json).as_h.has_key?("components").should be_false
  end
end

describe Status::Feed do
  it "serializes the schema of the specification" do
    service = Status::ServiceStatus.new(
      id: "vrchat",
      name: "VRChat",
      level: Status::Level::Degraded,
      source: Status::SourceKind::Official,
      url: "https://status.vrchat.com",
      checked_at: Time.unix(1756123180),
      note: "Websocket: Partial Outage",
      components: [
        Status::Component.new("API", Status::Level::Operational),
        Status::Component.new("Websocket", Status::Level::Degraded),
      ],
    )
    feed = Status::Feed.new(Time.unix(1756123200), false, [service])

    parsed = JSON.parse(feed.to_json)
    parsed["v"].should eq 1
    parsed["generated_unix"].should eq 1756123200
    parsed["stale"].should be_false
    parsed["services"][0]["id"].should eq "vrchat"
    parsed["services"][0]["components"][1]["level"].should eq 1
  end

  it "formats the generated time in JST without depending on tzdata" do
    Status::Feed.format_jst(Time.unix(1756123200)).should eq "2025/08/25 21:00"
  end
end

describe Status::State do
  it "falls back to an empty history for an unknown service" do
    Status::State.new.history_of("youtube").empty?.should be_true
    Status::State.new.service_of("youtube").should be_nil
  end

  it "carries the schema version it was written with" do
    state = Status::State.new

    state.version.should eq Status::State::SCHEMA_VERSION
    state.supported?.should be_true
    JSON.parse(state.to_json)["v"].should eq Status::State::SCHEMA_VERSION
  end

  # 版を持たない記録を読めてしまうと、履歴が空のまま通り、
  # 合成監視の判定が黙って振り出しに戻る。
  it "refuses a record written without a version" do
    state = Status::State.from_json(%({"histories": {}, "services": {}}))

    state.version.should eq 0
    state.supported?.should be_false
  end

  it "refuses a version it does not know" do
    state = Status::State.from_json(%({"v": 99, "histories": {}, "services": {}}))

    state.supported?.should be_false
  end

  # 次の実行はこれを読んでヒステリシスを続ける。書けても読めなければ意味がない。
  it "survives a round trip" do
    service = Status::ServiceStatus.new(
      id: "vrchat",
      name: "VRChat",
      level: Status::Level::Degraded,
      source: Status::SourceKind::Official,
      url: "https://status.vrchat.com",
      checked_at: Time.unix(1756123180),
      note: "Websocket: Partial Outage",
    )
    history = Status::History.new
      .push(Status::Outcome::Success)
      .push(Status::Outcome::Indeterminate)
    state = Status::State.new(
      histories: {"youtube" => history},
      services: {"vrchat" => service},
    )

    restored = Status::State.from_json(state.to_json)

    restored.supported?.should be_true
    restored.history_of("youtube").outcomes.should eq [
      Status::Outcome::Success,
      Status::Outcome::Indeterminate,
    ]
    restored.service_of("vrchat").try(&.level).should eq Status::Level::Degraded.value
    restored.service_of("vrchat").try(&.note).should eq "Websocket: Partial Outage"
  end
end
