require "http/client"
require "uri"
require "./status/usecase"

# 上流への GET の共通部分（仕様書 5.4、11.7）。
#
# 取得元アダプタはどれも「名乗りを付けて一度だけ GET する」ところが同じで、
# 違うのは URL と応答の読み方だけである。同じ手続きを取得元の数だけ書き写すと、
# 名乗りや上限の変更がどれか一つで漏れる。
module Upstream
  # shard.yml の版をそのまま使う。名乗りに出す版を二箇所で持たないためである。
  VERSION = {{ read_file("#{__DIR__}/../shard.yml").lines.find(&.starts_with?("version:")).split(": ").last.strip }}

  # 名乗り（仕様書 5.4）。VRChat API を含むすべての上流に同じ値を送る。
  USER_AGENT = "VRCServiceStatusPanel/#{VERSION} (+https://github.com/limit7412/VRCServiceStatusPanel)"

  # 接続と応答待ちの上限（仕様書 3.3、5.2）。
  # 中核が持つ値をそのまま使い、秒数を二箇所に置かない。
  TIMEOUT = Status::Usecase::CONNECT_TIMEOUT

  # 一度だけ GET する。失敗しても再試行しない（仕様書 5.4）。
  #
  # 接続を使い回さないのは、keep-alive が古いレプリカに固定される事象を
  # 避けるためである（仕様書 11.7）。
  def self.get(url : String, headers : HTTP::Headers = HTTP::Headers.new) : HTTP::Client::Response
    uri = URI.parse(url)

    request_headers = headers.dup
    request_headers["User-Agent"] = USER_AGENT

    client = HTTP::Client.new(uri)
    client.connect_timeout = TIMEOUT
    client.read_timeout = TIMEOUT

    begin
      client.get(request_target(uri), headers: request_headers)
    ensure
      client.close
    end
  end

  # 一つの経路の結果。応答か例外と、返るまでにかかった時間を持つ。
  #
  # 時間を経路ごとに持つのは、二つを並べて叩く取得元が、どちらが遅かったかを
  # 言えるようにするためである。全体の時間は遅いほうと同じなので、それだけでは
  # ストアが重いのか Web API が重いのかを表示で言い分けられない。
  record Fetch, result : HTTP::Client::Response | Exception, elapsed : Time::Span do
    def ok? : Bool
      Upstream.ok?(result)
    end

    def reason : String
      Upstream.reason(result)
    end
  end

  # 複数の URL を並べて GET する（仕様書 5.2）。
  #
  # 合成監視は一つのサービスに二つの経路を持つ（仕様書 3.3）。
  # 順に叩くと待ち時間が足し算になり、どちらも上限まで待てば 10 秒を使う。
  # 一回の実行に与えられた時間を、一つのサービスで使い切ることになる。
  #
  # 例外は握らずそのまま返す。届かなかったことと 500 が返ったことでは
  # 重みが違い、その違いをどう扱うかは経路ごとに決まる。
  def self.get_all(urls : Array(String)) : Array(Fetch)
    channel = Channel({Int32, Fetch}).new(urls.size)

    urls.each_with_index do |url, index|
      spawn do
        started = Time.instant
        result = begin
          get(url)
        rescue error
          error
        end

        channel.send({index, Fetch.new(result, Time.instant - started)})
      end
    end

    results = {} of Int32 => Fetch
    urls.size.times do
      index, fetch = channel.receive
      results[index] = fetch
    end

    # 渡した順に戻す。届く順で並べると、経路と結果の対応が実行ごとに変わる。
    Array.new(urls.size) do |index|
      results[index]? || Fetch.new(Exception.new("結果が返らなかった"), Time::Span.zero)
    end
  end

  # いちばん遅かった経路を表示に出す一行。しきい値に届かなければ空を返す。
  #
  # 名前と結果の組を受ける。二つとも遅くても一つに絞るのは、note が一行で、
  # 見る先が一つ分かれば足りるためである。
  #
  # しきい値を引数で受けるのは spec から差し替えるためで、取得元は
  # Status::Usecase::LATENCY_THRESHOLD をそのまま渡す。3 秒を待つ spec を
  # 置くより、上限を縮めて短い待ちで確かめるほうが安い。
  def self.slowest_note(fetches : Array({String, Fetch}), threshold : Time::Span) : String
    name, fetch = fetches.max_by { |_, each| each.elapsed }
    return "" if fetch.elapsed < threshold

    Status::Usecase.slow_note(fetch.elapsed, name)
  end

  # 200 が返ったか。合成監視はこれを「届いた」の定めとする（仕様書 3.3）。
  def self.ok?(result : HTTP::Client::Response | Exception) : Bool
    result.is_a?(HTTP::Client::Response) && result.status_code == 200
  end

  # 届かなかった理由を一行にする。note とログに出す。
  def self.reason(result : HTTP::Client::Response | Exception) : String
    case result
    in HTTP::Client::Response
      "HTTP #{result.status_code}"
    in Exception
      result.message || result.class.name
    end
  end

  # URI からパス以降を取り出す。パスが空のときは "/" にする。
  private def self.request_target(uri : URI) : String
    target = uri.request_target
    target.empty? ? "/" : target
  end
end
