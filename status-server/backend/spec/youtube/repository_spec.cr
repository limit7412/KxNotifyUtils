require "../spec_helper"

private def oembed_json : String
  <<-JSON
    { "title": "固定動画", "author_name": "作者" }
    JSON
end

private def with_youtube(status : HTTP::Status = HTTP::Status::OK, body : String = "", &)
  queries = [] of String

  handler = ->(context : HTTP::Server::Context) do
    queries << (context.request.query || "")
    context.response.status = status
    context.response.print body
    nil
  end

  with_stub_server(handler) do |endpoint|
    source = Youtube::Repository.new("dQw4w9WgXcQ", endpoint: "#{endpoint}/oembed")
    yield source, queries
  end
end

describe Youtube::Repository do
  it "合成監視である" do
    Youtube::Repository.new("abc").source_kind.should eq Status::SourceKind::Synthetic
  end

  it "表示名は YouTube である" do
    Youtube::Repository.new("abc").display_name.should eq "YouTube"
  end

  it "固定動画の URL を組み立てて渡す" do
    source = Youtube::Repository.new("abc")

    source.watch_url.should eq "https://www.youtube.com/watch?v=abc"
    source.oembed_url.should contain("format=json")
    source.oembed_url.should contain("url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3Dabc")
  end

  it "oEmbed が返れば届いたものとする" do
    with_youtube(body: oembed_json) do |source, queries|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Success
      observation.service_id.should eq "youtube"
      observation.partial?.should be_false
      observation.note.should eq ""
      observation.latency.should_not be_nil
      queries.first.should contain("format=json")
    end
  end

  # 消された動画や限定公開では 401 か 404 が返る。
  it "oEmbed が断れば届かなかったものとする" do
    with_youtube(status: HTTP::Status::NOT_FOUND) do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should contain("404")
    end
  end

  it "本文が JSON でなければ届かなかったものとする" do
    with_youtube(body: "<html>error</html>") do |source, _|
      observation = source.observe

      observation.outcome.should eq Status::Outcome::Failure
      observation.note.should eq "oEmbed の応答が JSON でない"
    end
  end

  it "誰も答えなくても例外を外に出さない" do
    source = Youtube::Repository.new("abc", endpoint: "http://127.0.0.1:#{unused_port}/oembed")

    observation = source.observe

    observation.outcome.should eq Status::Outcome::Failure
    # 断られたのではなく届かなかったことが分かるようにする。
    observation.note.should contain("届かない")
  end
end
