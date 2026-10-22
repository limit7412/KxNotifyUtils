require "http/client"
require "log"
require "socket"
require "../sleep/repository"
require "./mdns"
require "./models"

module OyasumiVR
  Log = ::Log.for("oyasumivr")

  # OyasumiVR の OSCQuery サーバを探して読む境界。
  # 状態の管理の試験ではテスト用実装に差し替える。
  #
  # どちらも応答を待つ。呼ぶのは Repository が別のファイバから行う。
  abstract class Client
    # サーバのポートを探す。見つからなければ nil を返す。
    abstract def discover : Int32?

    # port のサーバから睡眠モードを読む。読めなければ例外を投げる。
    abstract def sleep_mode(port : Int32) : Bool
  end

  # UDP で探し、HTTP で読む実装。
  class NetworkClient < Client
    MDNS_GROUP = Socket::IPAddress.new("224.0.0.251", 5353)
    # OyasumiVR の OSCQuery サーバは 127.0.0.1 にしか bind していない。
    # 応答の A レコードもここを指すため、応答からは読まない。
    HOST = "127.0.0.1"

    # 応答を待つ長さ。同じ PC の中で応えるものであり、長く待っても見つかる見込みは増えない。
    DISCOVERY_TIMEOUT = 2.seconds
    HTTP_TIMEOUT      = 2.seconds
    # mDNS の応答 1 つの上限（RFC 6762 17 節）。
    MAX_PACKET_SIZE = 9000

    SLEEP_MODE_PATH = "/OyasumiVR/SleepMode"

    # 名前の合う応答を見つけても、127.0.0.1 のそのポートで OyasumiVR が名乗るまでは採らない。
    #
    # 同じ LAN の別の PC で動く OyasumiVR も問い合わせに応える。
    # そのポートはこの PC には無いため、最初の応答で打ち切ると、
    # 別の PC の応答が先に届いたときに、この PC の OyasumiVR を見つけられない。
    # 確かめられなかった候補は捨て、期限まで次の応答を待つ。
    def discover : Int32?
      socket = UDPSocket.new
      begin
        socket.bind("0.0.0.0", 0)
        socket.send(Mdns.query, MDNS_GROUP)
        deadline = Time.monotonic + DISCOVERY_TIMEOUT
        buffer = Bytes.new(MAX_PACKET_SIZE)
        tried = Set(Int32).new
        loop do
          remaining = deadline - Time.monotonic
          return nil unless remaining.positive?
          socket.read_timeout = remaining
          size, _ = socket.receive(buffer)
          port = Mdns.find_port(buffer[0, size])
          next unless port && tried.add?(port)
          return port if oyasumivr?(port)
        end
      rescue IO::TimeoutError
        nil
      ensure
        socket.close
      end
    end

    def sleep_mode(port : Int32) : Bool
      value = Node.from_json(get(port, SLEEP_MODE_PATH)).value.first?.try(&.as_bool?)
      raise "#{SLEEP_MODE_PATH} の VALUE が真偽値ではない" if value.nil?
      value
    end

    # port のサーバが OyasumiVR を名乗るか。
    # 名前で選んでいても、ほかのアプリが同じ名前を名乗っている可能性は残るため、サーバ自身の名乗りで確かめる。
    private def oyasumivr?(port : Int32) : Bool
      HostInfo.from_json(get(port, "/?HOST_INFO")).name.compare("OyasumiVR", case_insensitive: true) == 0
    rescue exception
      Log.debug { "ポート #{port} は OyasumiVR ではなかった: #{exception.message}" }
      false
    end

    private def get(port : Int32, target : String) : String
      client = HTTP::Client.new(HOST, port)
      client.connect_timeout = HTTP_TIMEOUT
      client.read_timeout = HTTP_TIMEOUT
      begin
        response = client.get(target)
        # 未知のパスには 204 が返る。本文が無いので読み取りの失敗として扱う。
        raise "#{target} が HTTP #{response.status_code} を返した" unless response.status_code == 200
        response.body
      ensure
        client.close
      end
    end
  end

  # OyasumiVR の睡眠モードを追いかける（issue #54）。
  #
  # 見つけるまでは一定間隔で探し、見つけた後は設定の間隔で睡眠モードを読む。
  # 読み取りが続けて失敗したら見失ったものとして、探すところからやり直す。
  # OyasumiVR はサーバのポートを起動のたびに変えるため、再起動されると古いポートには誰もいない。
  #
  # 探すのも読むのも別のファイバで行い、tick と state は待たずに戻る。
  class Repository < Sleep::Signal
    # 見つからない間に探し直す間隔。監視対象の再試行と揃える。
    DISCOVERY_INTERVAL = 30.seconds
    # 見失ったと判断するまでの、続けての失敗の回数。
    # 1 回で判断すると、OyasumiVR が一瞬応えなかっただけで睡眠中の停止が解ける。
    MAX_FAILURES = 2

    getter? enabled : Bool = false
    getter port : Int32? = nil

    # 仕事をファイバへ渡す方法と、単調時計。テストでは同期で走らせ、時刻を固定する。
    def initialize(
      @client : Client,
      @runner : Proc(Proc(Nil), Nil) = ->(work : Proc(Nil)) { spawn(name: "oyasumivr") { work.call }; nil },
      @clock : Proc(Time::Span) = -> { Time.monotonic },
    )
      @interval = 5.seconds
      # 直近に読めた睡眠モード。見つけてから一度も読めていなければ nil である。
      @asleep = nil.as(Bool?)
      @failures = 0
      @next_at = Time::Span.zero
      @inflight = false
      # 設定を切り替えるたびに進める。進める前に投げた仕事の結果は捨てる。
      @generation = 0
    end

    def state : Sleep::SignalState
      # 見つけただけで読む前の拍を Awake とすると、睡眠モード中に見つけ直したときに
      # 起きている間の上書きが下りてしまう。読めるまでは Unknown とする。
      asleep = @asleep
      return Sleep::SignalState::Unknown unless @enabled && @port && !asleep.nil?
      asleep ? Sleep::SignalState::Asleep : Sleep::SignalState::Awake
    end

    def status : Status
      return Status::Disabled unless @enabled
      case state
      in .unknown? then Status::NotFound
      in .awake?   then Status::Connected
      in .asleep?  then Status::Asleep
      end
    end

    # 設定を反映する。使うかどうかが変わったときは、探すところからやり直す。
    #
    # 間隔を縮めたときは、次に読む時刻も新しい間隔に合わせて早める。
    # 旧い間隔で決めた時刻のままだと、60 秒から 1 秒へ縮めても 60 秒近く読まない。
    def configure(enabled : Bool, interval : Time::Span) : Nil
      if interval != @interval && @enabled && @port
        @next_at = {@next_at, @clock.call + interval}.min
      end
      @interval = interval
      return if enabled == @enabled

      @enabled = enabled
      @generation += 1
      @inflight = false
      @port = nil
      @asleep = nil
      @failures = 0
      @next_at = @clock.call
    end

    # 主ループから毎周期呼ぶ。時刻が来ていれば、探すか読むかを 1 回投げる。
    def tick : Nil
      return unless @enabled
      return if @inflight
      return if @clock.call < @next_at

      @inflight = true
      generation = @generation
      if port = @port
        @runner.call(-> { read(port, generation) })
      else
        @runner.call(-> { discover(generation) })
      end
    end

    private def discover(generation : Int32) : Nil
      found = begin
        @client.discover
      rescue exception
        Log.debug { "OyasumiVR を探せなかった: #{exception.message}" }
        nil
      end
      return unless generation == @generation

      if found
        Log.info { "OyasumiVR を見つけた（ポート #{found}）" }
        @port = found
        @asleep = nil
        @failures = 0
        @next_at = @clock.call
      else
        @next_at = @clock.call + DISCOVERY_INTERVAL
      end
    ensure
      @inflight = false if generation == @generation
    end

    private def read(port : Int32, generation : Int32) : Nil
      result = begin
        @client.sleep_mode(port)
      rescue exception
        exception
      end
      return unless generation == @generation

      if result.is_a?(Bool)
        @asleep = result
        @failures = 0
        @next_at = @clock.call + @interval
        return
      end

      @failures += 1
      if @failures < MAX_FAILURES
        @next_at = @clock.call + @interval
        return
      end

      Log.info { "OyasumiVR を見失った: #{result.message}" }
      @port = nil
      @asleep = nil
      @failures = 0
      @next_at = @clock.call
    ensure
      @inflight = false if generation == @generation
    end
  end
end
