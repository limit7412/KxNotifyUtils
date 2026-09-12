require "http/client"
require "log"
require "uri"
require "../notify/models"
require "../notify/repository"
require "./models"

module ServiceStatus
  # 配信 JSON を 1 回取りに行った結末。
  #
  # 取得はブロックしない実装を許すため、「まだ取れていない」を結末の 1 つとして持つ。
  # 失敗も例外ではなくここへ畳む。poll_new は主ループから毎秒呼ばれる経路であり、
  # 例外で抜けると同じ失敗を毎秒ログへ落とすことになる。
  struct Response
    enum Kind
      # 取りに行っている最中である。次の poll_new で聞き直す。
      Pending
      # 前回から変わっていない（304）。
      NotModified
      # 本文が取れた。
      Body
      # 取れなかった。回線が無いか、配信側が応えなかった。
      Failed
    end

    getter kind : Kind
    getter body : String
    getter error : String

    def initialize(@kind : Kind, @body : String = "", @error : String = "")
    end

    def self.pending : Response
      new(Kind::Pending)
    end

    def self.not_modified : Response
      new(Kind::NotModified)
    end

    def self.body(body : String) : Response
      new(Kind::Body, body: body)
    end

    def self.failed(error : String) : Response
      new(Kind::Failed, error: error)
    end

    def pending? : Bool
      @kind.pending?
    end
  end

  # 配信 JSON を取る境界。
  # 差分検出の試験ではテスト用実装に差し替える。
  abstract class FeedClient
    # url の配信を取りに行く。ブロックしない実装は、取れるまで Pending を返し続ける。
    abstract def fetch(url : String) : Response

    # 取りかけのものと控えを捨てる。ソースを開始し直すときに呼ぶ。
    def reset : Nil
    end
  end

  # HTTP で取る実装。
  #
  # 応答待ちは別のファイバで行い、fetch は待たずに戻る。
  # poll_new は主ループの中で呼ばれるため、そこで 5 秒待つとトレイも設定画面も止まる。
  # 更新の確認（update）が別のファイバで待つのと同じ理由である。
  class HttpFeedClient < FeedClient
    Log = ::Log.for("service_status")

    # 常駐アプリの片手間の確認であり、待たされてまで通す価値は無い。
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 5.seconds

    # 受け取る本文の上限。実物は数 KB である。
    # 配信経路がエラーページを返しても、それを丸ごと読み込まないための保険である。
    MAX_BODY_SIZE = 1024 * 1024

    # 取りに行っている最中か。重ねて取りに行かないために持つ。
    getter? inflight : Bool = false

    def initialize(@user_agent : String)
      # 取れて、まだ渡していない結末。
      @result = nil.as(Response?)
      # 条件付き GET に使う前回の ETag と、その URL。URL が変わったら使わない。
      @etag = nil.as(String?)
      @etag_url = ""
      # reset のたびに進める。進める前に仕掛けた取得の結果は捨てる。
      @generation = 0
    end

    def fetch(url : String) : Response
      if result = @result
        @result = nil
        return result
      end
      return Response.pending if @inflight

      start(url)
      Response.pending
    end

    def reset : Nil
      @generation += 1
      @result = nil
      @etag = nil
      @etag_url = ""
    end

    private def start(url : String) : Nil
      @inflight = true
      generation = @generation
      spawn(name: "service-status-fetch") do
        response, etag = request(url)
        # reset をまたいだ結果は、開始し直す前の状態に対するものであり渡さない。
        # ETag も同じである。控えだけ残すと次の取得が 304 になり、
        # 開始し直した後の状態を一度も読めないまま、その次の変化を初回として捨てる。
        if generation == @generation
          @result = response
          remember_etag(url, etag) if response.kind.body?
        end
      ensure
        @inflight = false
      end
    end

    # 取りに行った結末と、本文が取れたときの ETag を返す。
    private def request(url : String) : {Response, String?}
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      begin
        client.get(request_target(uri), headers(url)) do |response|
          next {Response.not_modified, nil} if response.status_code == 304
          next {Response.failed("配信が HTTP #{response.status_code} を返した"), nil} unless response.success?

          body = read_body(response)
          next {Response.failed("配信の本文が大きすぎる"), nil} if body.nil?

          {Response.body(body), response.headers["ETag"]?}
        end
      ensure
        client.close
      end
    rescue exception
      {Response.failed(exception.message || exception.class.name), nil}
    end

    # 本文を上限まで読む。超えていれば nil を返す。
    #
    # 全部読んでから大きさを見るわけにはいかない。取得先は設定で向け直せるため、
    # 途切れない本文を返す相手に当たると、上限を見る前にメモリへ積み上がる。
    # Content-Length があれば読む前に断り、無ければ読みながら数える。
    private def read_body(response : HTTP::Client::Response) : String?
      if declared = response.headers["Content-Length"]?.try(&.to_i64?)
        return nil if declared > MAX_BODY_SIZE
      end

      io = IO::Memory.new
      copied = IO.copy(response.body_io, io, MAX_BODY_SIZE + 1)
      return nil if copied > MAX_BODY_SIZE
      io.to_s
    end

    private def headers(url : String) : HTTP::Headers
      headers = HTTP::Headers{
        "Accept"     => "application/json",
        "User-Agent" => @user_agent,
      }
      if (etag = @etag) && @etag_url == url
        headers["If-None-Match"] = etag
      end
      headers
    end

    private def remember_etag(url : String, etag : String?) : Nil
      @etag = etag
      @etag_url = url
    end

    private def request_target(uri : URI) : String
      query = uri.query
      path = uri.path.empty? ? "/" : uri.path
      query ? "#{path}?#{query}" : path
    end
  end

  # 通知に載せる文言。
  #
  # 利用者へ向けてこのアプリが作る文言であり、選択言語で出す必要がある（issue #4）。
  # 辞書は runtime 側にあり、ここから参照すると層が逆さになるため、
  # composition root が辞書から引いたものを受け取る。
  struct Texts
    getter degraded : String
    getter major_outage : String
    getter recovered : String

    def initialize(@degraded : String, @major_outage : String, @recovered : String)
    end
  end

  # 外部サービスの障害検知の SourceRepository 実装。
  # 前回のレベルとの比較という、このソースに固有の差分検出をここに閉じる（仕様書 4.2 節）。
  class Repository < Notify::SourceRepository
    Log = ::Log.for("service_status")

    # poll_new を呼ばれる間隔。
    #
    # 設定の polling_interval_s より短いのは、取得がブロックしないためである。
    # 取りに行ってから取れるまでを別のファイバで待つ以上、取れたことを知るには
    # 聞き直しに来る必要がある。設定の間隔で聞き直すと、取れてから知らせるまでに
    # 最大でその間隔ぶんの遅れが乗る。
    POLL_TICK = 1.second

    getter settings : Settings
    # 通知に載せる文言。言語が決まるのは起動の途中なので、後から差し替えられる。
    property texts : Texts

    def initialize(@client : FeedClient, @settings : Settings, @texts : Texts)
      # サービスごとの前回の既知のレベル。無いものは比較の対象にしない。
      @levels = {} of String => Level
      # 直近に読んだ配信の生成時刻。同じなら未更新である。
      @last_generated = 0_i64
      # 直近に取りに行った時刻。間隔を変えたときに次の時刻を引き直すために持つ。
      @last_fetch_at = nil.as(Time::Span?)
      # 次に取りに行く時刻。
      @next_fetch = Time.monotonic
      # 取りに行ったまま、まだ結末を受け取っていないか。
      @waiting = false
      # 取得の失敗を知らせたか。連続した失敗を毎回は残さない。
      @failing = false
      # 読めない版の配信であることを知らせたか。
      @schema_warned = false
    end

    def source_id : String
      SOURCE_ID
    end

    def poll_interval : Time::Span
      POLL_TICK
    end

    # 設定の差し替え。
    #
    # 無効にしたサービスの記録は捨てる。残しておくと、有効に戻したときに
    # 無効にしていた間の変化を知らせることになる。
    # 取得先が変わったときは全部を捨てる。別の配信の前回値と比べる意味が無い。
    #
    # 間隔が変わったときは、直近に取りに行った時刻から新しい間隔で次の時刻を引き直す。
    # 引き直さないと、1 時間から 30 秒へ縮めても、前の間隔で決めた次の時刻まで取りに行かない。
    def settings=(settings : Settings) : Nil
      if settings.feed_url != @settings.feed_url
        reset_diff_state
        @client.reset
      else
        @levels.reject! { |id, _| !settings.service_enabled?(id) }
        if settings.polling_interval_s != @settings.polling_interval_s
          if last = @last_fetch_at
            @next_fetch = last + settings.polling_interval_s.seconds
          end
        end
      end
      @settings = settings
    end

    # 開始のたびに差分検出の状態を戻す。
    # 無効にしている間の変化を、再開直後に一斉に知らせないためである。
    def start : Nil
      reset_diff_state
      @client.reset
    end

    def stop : Nil
    end

    # 取りに行く時刻が来ていれば取りに行き、結末が来ていれば前回と比べる。
    def poll_new : Array(Notify::Incoming)
      poll_new(Time.monotonic)
    end

    # 時刻を受け取るのは、間隔の扱いを spec から確かめるためである。
    def poll_new(now : Time::Span) : Array(Notify::Incoming)
      return [] of Notify::Incoming unless @waiting || now >= @next_fetch

      unless @waiting
        @last_fetch_at = now
        @next_fetch = now + @settings.polling_interval_s.seconds
      end

      response = @client.fetch(@settings.feed_url)
      if response.pending?
        @waiting = true
        return [] of Notify::Incoming
      end

      @waiting = false
      handle(response)
    end

    private def reset_diff_state : Nil
      @levels.clear
      @last_generated = 0_i64
      @waiting = false
      @last_fetch_at = nil
      @next_fetch = Time.monotonic
    end

    private def handle(response : Response) : Array(Notify::Incoming)
      case response.kind
      in .pending?
        [] of Notify::Incoming
      in .not_modified?
        recovered
        [] of Notify::Incoming
      in .failed?
        report_failure(response.error)
        [] of Notify::Incoming
      in .body?
        recovered
        ingest(response.body)
      end
    end

    # 回線が無い環境では毎回失敗する。利用者に対処のしようが無いため、
    # 警告ログに留めて知らせない（update と同じ扱い）。
    # 続く失敗は最初の 1 回だけ警告にし、以後は debug へ落とす。
    private def report_failure(error : String) : Nil
      if @failing
        Log.debug { "配信を取れなかった: #{error}" }
      else
        @failing = true
        Log.warn { "配信を取れなかった: #{error}" }
      end
    end

    private def recovered : Nil
      return unless @failing
      @failing = false
      Log.info { "配信を取れるようになった" }
    end

    # 配信の本文を読み、前回のレベルと比べて変わったサービスだけを Incoming にする。
    #
    # 通信から切り離してあり、spec からはこれを直に呼んで差分検出だけを確かめられる。
    def ingest(body : String) : Array(Notify::Incoming)
      feed = begin
        Feed.from_json(body)
      rescue ex : JSON::Error
        Log.warn { "配信を読めなかった: #{ex.message}" }
        return [] of Notify::Incoming
      end

      unless feed.supported?
        # 一度だけ知らせる。配信側が版を上げたのなら、本体の更新まで毎分同じ話になる。
        unless @schema_warned
          @schema_warned = true
          Log.warn { "配信の版 #{feed.version} は読めない（読めるのは #{SCHEMA_VERSION}）" }
        end
        return [] of Notify::Incoming
      end

      # 同じ生成時刻なら中身も同じである。304 が返らない経路でも二度読まない。
      # 生成時刻を持たない配信は比べようが無いので、毎回読む。
      if feed.generated_unix > 0 && feed.generated_unix == @last_generated
        return [] of Notify::Incoming
      end
      @last_generated = feed.generated_unix

      # 取得元がどのサービスも取れていない。中身は前回値であり、比べても今を語らない。
      if feed.stale?
        Log.debug { "配信が stale のため比べない" }
        return [] of Notify::Incoming
      end

      fresh = [] of Notify::Incoming
      feed.services.each do |service|
        next unless @settings.service_enabled?(service.id)

        level = service.level_enum
        # 判定不能は比較の材料にしない。前回の既知のレベルをそのまま保つ。
        next unless level.known?

        previous = @levels[service.id]?
        @levels[service.id] = level

        # 初めて見たサービスは覚えるだけにする。
        # 起動時に進行中の障害を知らせると、VR を始めるたびに同じ通知が出る。
        if previous.nil?
          Log.info { "#{service.id} の状態: #{level}" } unless level.operational?
          next
        end
        next if previous == level

        Log.info { "#{service.id} の状態が変わった: #{previous} -> #{level}" }
        fresh << to_incoming(service, level, feed)
      end
      fresh
    end

    private def to_incoming(service : Service, level : Level, feed : Feed) : Notify::Incoming
      name = service.name.empty? ? (KNOWN_SERVICES[service.id]? || service.id) : service.name
      created_at = feed.generated_unix > 0 ? Time.unix(feed.generated_unix) : Time.utc
      Notify::Incoming.new(
        source: SOURCE_ID,
        app_id: "#{SOURCE_ID}.#{service.id}",
        app_name: name,
        title: title_for(level),
        body: service.note.empty? ? service.label : service.note,
        icon: Notify::Icon.builtin(icon_for(level)),
        created_at: created_at,
      )
    end

    private def title_for(level : Level) : String
      case level
      in .operational?  then @texts.recovered
      in .degraded?     then @texts.degraded
      in .major_outage? then @texts.major_outage
      in .unknown?      then @texts.recovered
      end
    end

    # 組み込みアイコンで重さを見せる。復旧は default に戻す。
    private def icon_for(level : Level) : String
      case level
      in .operational?  then "default"
      in .degraded?     then "warning"
      in .major_outage? then "error"
      in .unknown?      then "default"
      end
    end
  end
end
