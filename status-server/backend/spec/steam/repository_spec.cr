require "../spec_helper"

# 二つの経路をパスで分ける。片方だけを落とした場合を作るためである。
# delay は片方だけを遅らせるためのもので、返す前にその時間だけ待つ。
private record Stub,
  status : HTTP::Status = HTTP::Status::OK,
  body : String = "",
  delay : Time::Span = Time::Span.zero

private def server_info_json : String
  <<-JSON
    { "servertime": 1756123200, "servertimestring": "Mon Aug 25 21:00:00 2025" }
    JSON
end

# threshold は遅さの spec で縮める。3 秒待つより、上限を下げて短い待ちで確かめる。
private def with_steam(
  web_api : Stub,
  store : Stub,
  threshold : Time::Span = Status::Usecase::LATENCY_THRESHOLD,
  &
)
  handler = ->(context : HTTP::Server::Context) do
    stub = context.request.path.starts_with?("/api") ? web_api : store
    sleep stub.delay
    context.response.status = stub.status
    context.response.print stub.body
    nil
  end

  with_stub_server(handler) do |endpoint|
    yield Steam::Repository.new(
      web_api_url: "#{endpoint}/api",
      store_url: "#{endpoint}/store",
      latency_threshold: threshold,
    )
  end
end

describe Steam::Repository do
  it "合成監視である" do
    Steam::Repository.new.source_kind.should eq Status::SourceKind::Synthetic
  end

  it "人が開く先はストアにする" do
    Steam::Repository.new.display_url.should eq Steam::Repository::STORE_URL
  end

  it "どちらも返れば届いたものとする" do
    with_steam(Stub.new(body: server_info_json), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "steam"
      observation.partial?.should be_false
      observation.note.should eq ""
      observation.latency.should_not be_nil
    end
  end

  # ストアが重いだけでログインできないとは限らないので、一段下げるにとどめる。
  it "ストアだけが落ちていれば一段下げる" do
    store = Stub.new(status: HTTP::Status::SERVICE_UNAVAILABLE)

    with_steam(Stub.new(body: server_info_json), store) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should contain("ストア")
      observation.note.should contain("503")
    end
  end

  # 全体の時間は遅いほうと同じなので、どちらが遅いかは経路ごとに測るしかない。
  # ストアが重いだけなのか Web API が重いのかで、次に見る先が変わる。
  it "ストアが遅ければどちらが遅いかを残す" do
    store = Stub.new(delay: 100.milliseconds)

    with_steam(Stub.new(body: server_info_json), store, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_false
      observation.note.should start_with("ストア: 応答に ")
      observation.note.should end_with(" 秒")
      # 遅いほうの時間が利用者の体感になる。
      (observation.latency || Time::Span.zero).should be >= 100.milliseconds
    end
  end

  it "Web API が遅ければそちらを残す" do
    web_api = Stub.new(body: server_info_json, delay: 100.milliseconds)

    with_steam(web_api, Stub.new, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.note.should start_with("Web API: 応答に ")
    end
  end

  # 落ちた理由のほうが先に読みたい。遅さは level を動かさず、
  # 二つ並べても一行に収まらない。
  it "ストアが落ちていれば遅さより落ちたことを残す" do
    store = Stub.new(status: HTTP::Status::SERVICE_UNAVAILABLE, delay: 100.milliseconds)

    with_steam(Stub.new(body: server_info_json), store, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.partial?.should be_true
      observation.note.should contain("ストアが応答しない")
      observation.note.should_not contain("応答に")
    end
  end

  # VRChat の Steam ログインに効くのはこちらである。
  it "Web API が落ちていれば届かなかったものとする" do
    with_steam(Stub.new(status: HTTP::Status::INTERNAL_SERVER_ERROR), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should contain("Web API")
      observation.note.should contain("500")
    end
  end

  # 上流がエラーページを 200 で返すことがある。状態コードだけでは足りない。
  #
  # このとき「HTTP 200」とだけ残すと、応答があったことしか伝わらない。
  # 返ってきたものが読めなかったのだと分かる一行を出す。
  it "Web API が JSON を返さなければ届かなかったものとする" do
    with_steam(Stub.new(body: "<html>maintenance</html>"), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should eq "Web API の応答が JSON でない"
      observation.note.should_not contain("200")
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    port = unused_port
    source = Steam::Repository.new(
      web_api_url: "http://127.0.0.1:#{port}/api",
      store_url: "http://127.0.0.1:#{port}/store",
    )

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    # 断られたのではなく届かなかったことが分かるようにする。
    observation.note.should contain("届かない")
  end
end
