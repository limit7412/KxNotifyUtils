require "../spec_helper"
require "http/server"

# 実サーバ相手のため、時間ではなく状態の変化を待つ。
private def wait_until(timeout = 3.seconds, &block : -> Bool) : Bool
  deadline = Time.monotonic + timeout
  until block.call
    return false if Time.monotonic > deadline
    sleep 5.milliseconds
  end
  true
end

# 取れるまで聞き直す。取れなければ nil を返す。
private def fetch_until_done(client : ServiceStatus::HttpFeedClient, url : String) : ServiceStatus::Response?
  result = nil.as(ServiceStatus::Response?)
  wait_until do
    response = client.fetch(url)
    result = response unless response.pending?
    !result.nil?
  end
  result
end

private def serve(&handler : HTTP::Server::Context -> Nil) : {HTTP::Server, String}
  server = HTTP::Server.new { |context| handler.call(context) }
  address = server.bind_unused_port
  spawn { server.listen }
  {server, "http://127.0.0.1:#{address.port}/v1/status.json"}
end

describe ServiceStatus::HttpFeedClient do
  it "本文を取り、次は前回の ETag を添えて 304 なら変わっていないと返す" do
    seen = [] of HTTP::Headers
    server, url = serve do |context|
      seen << context.request.headers
      if context.request.headers["If-None-Match"]? == %("v1")
        context.response.status = HTTP::Status::NOT_MODIFIED
      else
        context.response.headers["ETag"] = %("v1")
        context.response.content_type = "application/json"
        context.response.print %({"v": 1})
      end
    end

    begin
      client = ServiceStatus::HttpFeedClient.new("KxNotifyUtils/spec")

      first = fetch_until_done(client, url).should_not be_nil
      first.kind.body?.should be_true
      first.body.should eq %({"v": 1})

      second = fetch_until_done(client, url).should_not be_nil
      second.kind.not_modified?.should be_true
      seen[1]["If-None-Match"]?.should eq %("v1")
      seen[1]["User-Agent"]?.should eq "KxNotifyUtils/spec"
    ensure
      server.close
    end
  end

  it "上限を超える本文は読み切らずに失敗にする" do
    server, url = serve do |context|
      context.response.content_type = "application/json"
      context.response.print "x" * (ServiceStatus::HttpFeedClient::MAX_BODY_SIZE + 1)
    end

    begin
      client = ServiceStatus::HttpFeedClient.new("KxNotifyUtils/spec")

      response = fetch_until_done(client, url).should_not be_nil
      response.kind.failed?.should be_true
      response.error.should contain "大きすぎる"
    ensure
      server.close
    end
  end

  it "Content-Length が上限を超えていれば読む前に断る" do
    server, url = serve do |context|
      context.response.content_length = (ServiceStatus::HttpFeedClient::MAX_BODY_SIZE + 1).to_i64
      context.response.print "x"
    end

    begin
      client = ServiceStatus::HttpFeedClient.new("KxNotifyUtils/spec")

      response = fetch_until_done(client, url).should_not be_nil
      response.kind.failed?.should be_true
    ensure
      server.close
    end
  end

  it "HTTP エラーは失敗として返す" do
    server, url = serve do |context|
      context.response.status = HTTP::Status::SERVICE_UNAVAILABLE
    end

    begin
      client = ServiceStatus::HttpFeedClient.new("KxNotifyUtils/spec")

      response = fetch_until_done(client, url).should_not be_nil
      response.kind.failed?.should be_true
      response.error.should contain "503"
    ensure
      server.close
    end
  end

  it "取りに行っている最中に reset したら、その結果も ETag も捨てる" do
    release = Channel(Nil).new
    seen = [] of HTTP::Headers
    server, url = serve do |context|
      seen << context.request.headers
      release.receive if seen.size == 1
      context.response.headers["ETag"] = %("v1")
      context.response.print %({"v": 1})
    end

    begin
      client = ServiceStatus::HttpFeedClient.new("KxNotifyUtils/spec")

      client.fetch(url).pending?.should be_true
      wait_until { seen.size == 1 }.should be_true
      client.reset
      release.send(nil)
      wait_until { !client.inflight? }.should be_true

      # 捨てた結果は渡されず、取り直しになる。
      client.fetch(url).pending?.should be_true
      wait_until { seen.size == 2 }.should be_true
      # 捨てた取得の ETag を添えない。添えると 304 が返り、開始し直した後の状態を読めない。
      seen[1]["If-None-Match"]?.should be_nil
    ensure
      server.close
    end
  end
end
