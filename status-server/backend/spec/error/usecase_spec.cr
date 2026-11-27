require "../spec_helper"

# 送られた本文とヘッダを控える試験用の受け口。
private class Inbox
  getter bodies = [] of String
  getter content_types = [] of String

  def handler : HTTP::Server::Context -> Nil
    ->(context : HTTP::Server::Context) do
      @bodies << (context.request.body.try(&.gets_to_end) || "")
      @content_types << (context.request.headers["Content-Type"]? || "")
      context.response.status_code = 200
      context.response.print("ok")
    end
  end
end

describe Error::Usecase do
  describe "#alert" do
    it "仕様書 11.7 の五つを Discord の形で送る" do
      inbox = Inbox.new

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new("dev", url)
        usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req-1")
      end

      inbox.content_types.first.should eq("application/json")

      body = JSON.parse(inbox.bodies.first)

      # 押し通知に出る一行。開かずに、どこの何が落ちたかが分かる。
      body["content"].as_s.should contain("dev")
      body["content"].as_s.should contain("refresh")

      embed = body["embeds"][0]
      embed["title"].should eq("ArgumentError")
      embed["description"].should eq("鍵が違う")

      fields = embed["fields"].as_a.to_h { |field| {field["name"].as_s, field["value"].as_s} }
      fields["env"].should eq("dev")
      fields["handler"].should eq("refresh")
      fields["request_id"].should eq("req-1")
    end

    it "Discord の上限を越える文面を切り詰める" do
      inbox = Inbox.new
      long = "あ" * 5000

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new("dev", url)
        usecase.alert("refresh", ArgumentError.new(long), "req-1")
      end

      # 越えたまま送ると 400 で丸ごと断られ、届かないことだけが残る。
      description = JSON.parse(inbox.bodies.first)["embeds"][0]["description"].as_s
      description.size.should eq(Error::Usecase::DESCRIPTION_LIMIT)
      description.should end_with("…")
    end

    it "embed 全体の合計も Discord の上限に収める" do
      inbox = Inbox.new
      # 項目ごとの上限は守っていても、足すと 6000 を越える組み合わせ。
      long_env = "e" * Error::Usecase::FIELD_LIMIT
      long_handler = "h" * Error::Usecase::FIELD_LIMIT
      long_request_id = "r" * Error::Usecase::FIELD_LIMIT

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new(long_env, url)
        usecase.alert(long_handler, ArgumentError.new("あ" * 5000), long_request_id)
      end

      embed = JSON.parse(inbox.bodies.first)["embeds"][0]
      fields = embed["fields"].as_a
      total = embed["title"].as_s.size + embed["description"].as_s.size +
              fields.sum { |field| field["name"].as_s.size + field["value"].as_s.size }

      total.should be <= Error::Usecase::EMBED_TOTAL_LIMIT
      # 吸収するのは description で、fields は落とさない。
      fields.size.should eq(3)
      fields.each { |field| field["value"].as_s.size.should eq(Error::Usecase::FIELD_LIMIT) }
      embed["description"].as_s.should end_with("…")
    end

    it "request id が無くても空の field を送らない" do
      inbox = Inbox.new

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new("dev", url)
        usecase.alert("refresh", ArgumentError.new("鍵が違う"), nil)
      end

      # Discord は空の value を断る。
      fields = JSON.parse(inbox.bodies.first)["embeds"][0]["fields"].as_a
      fields.find! { |field| field["name"] == "request_id" }["value"].as_s.should_not be_empty
    end

    it "同じ種類が続くあいだは 10 分に一通しか送らない" do
      inbox = Inbox.new
      at = Time.utc(2026, 9, 2, 12, 0, 0)

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new("dev", url)

        # 60 秒ごとに同じ原因で落ち続ける形。
        11.times do |count|
          usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req", at + (count * 60).seconds)
        end
      end

      # 最初の一通と、10 分後の一通。
      inbox.bodies.size.should eq(2)
    end

    it "種類が違えば抑えない" do
      inbox = Inbox.new
      at = Time.utc(2026, 9, 2, 12, 0, 0)

      with_stub_server(inbox.handler) do |url|
        usecase = Error::Usecase.new("dev", url)
        usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req", at)
        usecase.alert("refresh", IO::Error.new("届かない"), "req", at)
      end

      # 原因が別なら、片方が抑えられているあいだも届く。
      inbox.bodies.size.should eq(2)
    end

    it "送れなくても例外を外に出さない" do
      usecase = Error::Usecase.new("dev", "http://127.0.0.1:#{unused_port}/hook")

      # ここで例外が漏れると、本体の失敗の報告がアラートの失敗に置き換わる。
      usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req-1")
    end

    it "送れなかったことを記録する" do
      Log.capture("error") do |logs|
        usecase = Error::Usecase.new("dev", "http://127.0.0.1:#{unused_port}/hook")
        usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req-1")

        logs.check(:error, /アラートを送れなかった/)
      end
    end

    it "受け取られなかったことを記録する" do
      rejecting = ->(context : HTTP::Server::Context) do
        context.response.status_code = 404
        context.response.print("no such hook")
      end

      Log.capture("error") do |logs|
        with_stub_server(rejecting) do |url|
          usecase = Error::Usecase.new("dev", url)
          usecase.alert("refresh", ArgumentError.new("鍵が違う"), "req-1")
        end

        # webhook の URL を間違えていることに、これで気付ける。
        logs.check(:error, /HTTP 404/)
      end
    end
  end
end
