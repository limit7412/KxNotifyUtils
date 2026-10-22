require "../spec_helper"
require "http/server"
require "../../src/oyasumivr/repository"

# 探す結果と読む結果を順に返す Client。
# 結果を使い切った後は、探せば見つからず、読めば失敗する。
private class FakeClient < OyasumiVR::Client
  property ports = [] of Int32?
  property modes = [] of Bool | Exception
  getter discover_count = 0
  getter read_ports = [] of Int32

  def discover : Int32?
    @discover_count += 1
    @ports.shift? || nil
  end

  def sleep_mode(port : Int32) : Bool
    @read_ports << port
    result = @modes.shift? || Exception.new("応答しない")
    raise result if result.is_a?(Exception)
    result
  end
end

private class Monotonic
  property now = Time::Span.zero
end

# 仕事をその場で走らせる Repository。tick から戻った時点で結果が反映されている。
private def repository(client : FakeClient, clock : Monotonic) : OyasumiVR::Repository
  OyasumiVR::Repository.new(client, ->(work : Proc(Nil)) { work.call }, -> { clock.now })
end

describe OyasumiVR::Repository do
  it "無効の間は探さない" do
    client = FakeClient.new
    target = repository(client, Monotonic.new)

    target.tick

    client.discover_count.should eq 0
    target.status.should eq OyasumiVR::Status::Disabled
    target.state.should eq Sleep::SignalState::Unknown
  end

  it "見つけたらすぐに睡眠モードを読み、その後は設定の間隔で読む" do
    client = FakeClient.new
    client.ports = [51234] of Int32?
    client.modes = [false, true] of Bool | Exception
    clock = Monotonic.new
    target = repository(client, clock)
    target.configure(true, 5.seconds)

    target.tick
    target.port.should eq 51234
    target.tick
    target.status.should eq OyasumiVR::Status::Connected
    target.state.should eq Sleep::SignalState::Awake

    clock.now = 4.seconds
    target.tick
    client.read_ports.size.should eq 1

    clock.now = 5.seconds
    target.tick
    client.read_ports.should eq [51234, 51234]
    target.status.should eq OyasumiVR::Status::Asleep
    target.state.should eq Sleep::SignalState::Asleep
  end

  it "見つからなければ 30 秒おいて探し直す" do
    client = FakeClient.new
    clock = Monotonic.new
    target = repository(client, clock)
    target.configure(true, 5.seconds)

    target.tick
    target.status.should eq OyasumiVR::Status::NotFound
    clock.now = 29.seconds
    target.tick
    client.discover_count.should eq 1

    clock.now = 30.seconds
    target.tick
    client.discover_count.should eq 2
  end

  # 1 回の失敗で解くと、OyasumiVR が一瞬応えなかっただけで通知が出る。
  it "読み取りの失敗が 1 回なら直前の状態を保ち、2 回続いたら見失ったものとして探し直す" do
    client = FakeClient.new
    client.ports = [51234, 52345] of Int32?
    client.modes = [true, Exception.new("接続を拒否された"), Exception.new("接続を拒否された")] of Bool | Exception
    clock = Monotonic.new
    target = repository(client, clock)
    target.configure(true, 5.seconds)
    target.tick
    target.tick
    target.state.should eq Sleep::SignalState::Asleep

    clock.now = 5.seconds
    target.tick
    target.state.should eq Sleep::SignalState::Asleep

    clock.now = 10.seconds
    target.tick
    target.port.should be_nil
    target.state.should eq Sleep::SignalState::Unknown

    # 見失った直後に探し直し、起動し直した OyasumiVR の新しいポートを拾う。
    target.tick
    target.port.should eq 52345
  end

  it "間に成功を挟んだ失敗は続けて数えない" do
    client = FakeClient.new
    client.ports = [51234] of Int32?
    client.modes = [true, Exception.new("一時的"), true, Exception.new("一時的")] of Bool | Exception
    clock = Monotonic.new
    target = repository(client, clock)
    target.configure(true, 1.second)
    target.tick

    4.times do |index|
      clock.now = (index + 1).seconds
      target.tick
    end

    target.port.should eq 51234
  end

  it "無効にすれば状態を捨て、有効にし直すと探すところから始める" do
    client = FakeClient.new
    client.ports = [51234, 52345] of Int32?
    client.modes = [true] of Bool | Exception
    target = repository(client, Monotonic.new)
    target.configure(true, 5.seconds)
    target.tick
    target.tick

    target.configure(false, 5.seconds)
    target.state.should eq Sleep::SignalState::Unknown

    target.configure(true, 5.seconds)
    target.port.should be_nil
    target.tick
    target.port.should eq 52345
  end

  # 設定を切り替える前に投げた仕事の結果は、切り替えた後の状態に混ぜない。
  it "設定を切り替える前に投げた仕事の結果は捨てる" do
    client = FakeClient.new
    client.ports = [51234] of Int32?
    pending = [] of Proc(Nil)
    target = OyasumiVR::Repository.new(client, ->(work : Proc(Nil)) { pending << work; nil }, -> { Time::Span.zero })
    target.configure(true, 5.seconds)
    target.tick

    target.configure(false, 5.seconds)
    target.configure(true, 5.seconds)
    pending.shift.call

    target.port.should be_nil
    target.tick
    pending.size.should eq 1
  end
end

# 決まった応答を返す HTTP サーバを 127.0.0.1 の空きポートに立て、そのポートを渡す。
private def with_server(status : Int32, body : String, &)
  server = HTTP::Server.new do |context|
    context.response.status_code = status
    context.response.print body
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  Fiber.yield
  begin
    yield address.port
  ensure
    server.close
  end
end

describe OyasumiVR::NetworkClient do
  it "ノードの VALUE から睡眠モードを読む" do
    body = %({"FULL_PATH":"/OyasumiVR/SleepMode","ACCESS":3,"TYPE":"F","VALUE":[true],"DESCRIPTION":"Enabled status of the sleep mode"})
    with_server(200, body) do |port|
      OyasumiVR::NetworkClient.new.sleep_mode(port).should be_true
    end
  end

  it "未知のパスへの 204 は読み取りの失敗とする" do
    with_server(204, "") do |port|
      expect_raises(Exception, /204/) { OyasumiVR::NetworkClient.new.sleep_mode(port) }
    end
  end

  it "VALUE が真偽値でなければ読み取りの失敗とする" do
    with_server(200, %({"VALUE":[]})) do |port|
      expect_raises(Exception, /VALUE/) { OyasumiVR::NetworkClient.new.sleep_mode(port) }
    end
  end
end

describe OyasumiVR::HostInfo do
  it "NAME を読み、ほかの項目は無視する" do
    json = %({"NAME":"OyasumiVR","OSC_IP":"127.0.0.1","OSC_PORT":9001,"OSC_TRANSPORT":"UDP","EXTENSIONS":{"ACCESS":true}})

    OyasumiVR::HostInfo.from_json(json).name.should eq "OyasumiVR"
  end
end
