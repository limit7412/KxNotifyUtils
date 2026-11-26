require "../spec_helper"

# 受け取った要求を控えておく。署名は検証しない。
# 鍵が正しいかは実機の R2 が答えることで、ここで見るのは
# どのバケットのどのキーへ、どんなヘッダと本文を送ったかである。
private record Received,
  method : String,
  path : String,
  headers : HTTP::Headers,
  body : String

private def recording_server(status : HTTP::Status = HTTP::Status::OK, body : String = "", &)
  received = [] of Received

  handler = ->(context : HTTP::Server::Context) do
    received << Received.new(
      method: context.request.method,
      path: context.request.path,
      headers: context.request.headers.dup,
      body: context.request.body.try(&.gets_to_end) || "",
    )
    # awscr-s3 は PUT の応答から ETag を必ず読む。S3 も R2 も返すので、
    # ここでも返す。無いと応答の読み取りが KeyError で落ちる。
    context.response.headers["ETag"] = %("dummy")
    context.response.status = status
    context.response.print body
    nil
  end

  with_stub_server(handler) do |endpoint|
    yield endpoint, received
  end
end

private def repository(endpoint : String) : R2::Repository
  R2::Repository.new(
    endpoint: endpoint,
    access_key_id: "key-id",
    secret_access_key: "secret",
    public_bucket: "status-public",
    state_bucket: "status-state",
  )
end

private def state_json(version : Int32 = Status::State::SCHEMA_VERSION) : String
  <<-JSON
    {
      "v": #{version},
      "histories": { "steam": { "outcomes": ["success", "failure"] } },
      "services": {}
    }
    JSON
end

# S3 が権限の無い操作へ返す本文。
private def access_denied_xml : String
  <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
    XML
end

# S3 がオブジェクトの無いキーへ返す本文。R2 も同じ形で返す。
private def no_such_key_xml : String
  <<-XML
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>NoSuchKey</Code><Message>The specified key does not exist.</Message></Error>
    XML
end

private def feed_with(note : String) : Status::Feed
  service = Status::ServiceStatus.new(
    id: "vrchat",
    name: "VRChat",
    level: Status::Level::Degraded,
    source: Status::SourceKind::Official,
    url: "https://status.vrchat.com",
    checked_at: Time.unix(1_756_123_180),
    note: note,
  )

  Status::Feed.new(Time.unix(1_756_123_200), false, [service])
end

describe R2::Repository do
  describe "#load_state" do
    it "内部バケットの state を読む" do
      recording_server(body: state_json) do |endpoint, received|
        state = repository(endpoint).load_state

        state.should_not be_nil
        state.try(&.history_of("steam").outcomes).should eq [
          Status::Outcome::Success,
          Status::Outcome::Failure,
        ]

        received.first.method.should eq "GET"
        received.first.path.should eq "/status-state/state.json"
      end
    end

    # 初回はまだ書かれていない。履歴なしとして進む（仕様書 5.2）。
    it "まだ無ければ nil を返す" do
      recording_server(status: HTTP::Status::NOT_FOUND, body: no_such_key_xml) do |endpoint, _|
        repository(endpoint).load_state.should be_nil
      end
    end

    # 版を上げたあとに古い記録を読むと、履歴が黙って空になる。
    # 読めないものとして弾き、そのことをログに残す。
    it "版が違えば nil を返す" do
      recording_server(body: state_json(version: 99)) do |endpoint, _|
        repository(endpoint).load_state.should be_nil
      end
    end

    it "版を持たない記録も nil を返す" do
      body = %({"histories": {}, "services": {}})

      recording_server(body: body) do |endpoint, _|
        repository(endpoint).load_state.should be_nil
      end
    end

    it "JSON として読めなければ nil を返す" do
      recording_server(body: "<html>error</html>") do |endpoint, _|
        repository(endpoint).load_state.should be_nil
      end
    end

    it "上流が落ちていても nil を返す" do
      recording_server(status: HTTP::Status::INTERNAL_SERVER_ERROR, body: "error") do |endpoint, _|
        repository(endpoint).load_state.should be_nil
      end
    end
  end

  describe "#save_feed" do
    it "配信バケットへ仕様どおりのヘッダで置く" do
      recording_server do |endpoint, received|
        repository(endpoint).save_feed(feed_with(""))

        request = received.first
        request.method.should eq "PUT"
        request.path.should eq "/status-public/v1/status.json"
        request.headers["Content-Type"].should eq "application/json; charset=utf-8"
        request.headers["Cache-Control"].should eq "public, max-age=30"
      end
    end

    it "配信 JSON をそのまま送る" do
      feed = feed_with("")

      recording_server do |endpoint, received|
        repository(endpoint).save_feed(feed)

        received.first.body.should eq feed.to_json
      end
    end

    # note には上流由来の文字列が入る（仕様書 4）。長さを文字数で数えると、
    # 日本語を含む本文が途中で切れたまま配られる。
    it "日本語を含む本文を切らずに送る" do
      feed = feed_with("Websocket の接続が切れる")

      recording_server do |endpoint, received|
        repository(endpoint).save_feed(feed)

        request = received.first
        request.body.should eq feed.to_json
        request.headers["Content-Length"].should eq feed.to_json.bytesize.to_s
      end
    end

    # 失敗しても再試行せず、次の実行に任せる（仕様書 5.3）。
    # 呼び出し側がその判断をできるよう、握りつぶさずに投げる。
    it "断られたら例外を投げる" do
      recording_server(status: HTTP::Status::FORBIDDEN, body: access_denied_xml) do |endpoint, _|
        expect_raises(Awscr::S3::Exception) do
          repository(endpoint).save_feed(feed_with(""))
        end
      end
    end

    # 配信経路の手前が HTML のエラーページを返すことがある。
    # 型は問わない。次の実行に任せるために、外へ出ることだけを見る。
    it "S3 の形でない失敗でも黙って終わらない" do
      recording_server(status: HTTP::Status::BAD_GATEWAY, body: "<html>error</html>") do |endpoint, _|
        expect_raises(Exception) do
          repository(endpoint).save_feed(feed_with(""))
        end
      end
    end
  end

  describe "#save_state" do
    it "内部バケットへ置く" do
      recording_server do |endpoint, received|
        repository(endpoint).save_state(Status::State.new)

        request = received.first
        request.method.should eq "PUT"
        request.path.should eq "/status-state/state.json"
        request.headers["Content-Type"].should eq "application/json"
      end
    end

    it "版を含めて書く" do
      recording_server do |endpoint, received|
        repository(endpoint).save_state(Status::State.new)

        JSON.parse(received.first.body)["v"].should eq Status::State::SCHEMA_VERSION
      end
    end
  end
end
