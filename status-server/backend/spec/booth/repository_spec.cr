require "../spec_helper"

# delay は片方だけを遅らせるためのもので、返す前にその時間だけ待つ。
private record Stub, status : HTTP::Status = HTTP::Status::OK, delay : Time::Span = Time::Span.zero

# threshold は遅さの spec で縮める。3 秒待つより、上限を下げて短い待ちで確かめる。
private def with_booth(
  top : Stub,
  item : Stub,
  threshold : Time::Span = Status::Usecase::LATENCY_THRESHOLD,
  &
)
  handler = ->(context : HTTP::Server::Context) do
    stub = context.request.path.starts_with?("/items") ? item : top
    sleep stub.delay
    context.response.status = stub.status
    nil
  end

  with_stub_server(handler) do |endpoint|
    yield Booth::Repository.new("123456", top_url: endpoint, latency_threshold: threshold)
  end
end

describe Booth::Repository do
  it "合成監視である" do
    Booth::Repository.new("123456").source_kind.should eq Status::SourceKind::Synthetic
  end

  it "作者自身の商品ページを見に行く" do
    Booth::Repository.new("123456").item_url.should eq "https://booth.pm/ja/items/123456"
  end

  it "どちらも返れば届いたものとする" do
    with_booth(Stub.new, Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "booth"
      observation.partial?.should be_false
      observation.note.should eq ""
    end
  end

  # 商品ページだけが落ちるのは、その商品が消えたときにも起きる。
  # 月次の点検で見分けられるよう、どちらが落ちたかを残す（仕様書 9）。
  it "商品ページだけが落ちていれば一段下げる" do
    with_booth(Stub.new, Stub.new(status: HTTP::Status::NOT_FOUND)) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should eq "商品ページが応答しない"
    end
  end

  it "トップだけが落ちていれば一段下げる" do
    with_booth(Stub.new(status: HTTP::Status::BAD_GATEWAY), Stub.new) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_true
      observation.note.should eq "トップが応答しない"
    end
  end

  # 全体の時間は遅いほうと同じなので、どちらが遅いかは経路ごとに測るしかない。
  it "商品ページが遅ければどちらが遅いかを残す" do
    item = Stub.new(delay: 100.milliseconds)

    with_booth(Stub.new, item, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.partial?.should be_false
      observation.note.should start_with("商品ページ: 応答に ")
      (observation.latency || Time::Span.zero).should be >= 100.milliseconds
    end
  end

  it "トップが遅ければそちらを残す" do
    top = Stub.new(delay: 100.milliseconds)

    with_booth(top, Stub.new, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.note.should start_with("トップ: 応答に ")
    end
  end

  # 落ちた理由のほうが先に読みたい。
  it "片方が落ちていれば遅さより落ちたことを残す" do
    item = Stub.new(status: HTTP::Status::NOT_FOUND, delay: 100.milliseconds)

    with_booth(Stub.new, item, threshold: 50.milliseconds) do |source|
      observation = source.observe

      observation.note.should eq "商品ページが応答しない"
    end
  end

  it "両方落ちていれば届かなかったものとする" do
    top = Stub.new(status: HTTP::Status::BAD_GATEWAY)
    item = Stub.new(status: HTTP::Status::NOT_FOUND)

    with_booth(top, item) do |source|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      # 片方だけを出すと、もう片方が何で落ちたか分からない。
      observation.note.should contain("502")
      observation.note.should contain("404")
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    source = Booth::Repository.new("123456", top_url: "http://127.0.0.1:#{unused_port}")

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    observation.note.should_not eq ""
  end
end
