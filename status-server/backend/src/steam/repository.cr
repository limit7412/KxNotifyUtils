require "../status/models"
require "../status/repository"
require "../status/usecase"
require "../upstream"
require "./models"

module Steam
  # Steam の合成監視（仕様書 3.3）。
  #
  # VRChat の Steam ログインに効くのは Web API 側なので、そちらを主指標にする。
  # ストアは補助で、落ちていても一段下げるにとどめる。ストアが重いだけで
  # ログインできない、とは限らないためである。
  #
  # 非公式のステータス集約サイトは取得元にしない（仕様書 3.3）。
  class Repository < Status::SourceRepository
    # API キーが要らない疎通確認用のエンドポイント。
    WEB_API_URL = "https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/"
    STORE_URL   = "https://store.steampowered.com/"

    # 取得先としきい値を受け取るのは spec から差し替えるためである。
    # 表示に出す url は上の定数のままにする（仕様書 4）。
    def initialize(
      @web_api_url : String = WEB_API_URL,
      @store_url : String = STORE_URL,
      @latency_threshold : Time::Span = Status::Usecase::LATENCY_THRESHOLD,
    )
    end

    def service_id : String
      "steam"
    end

    def display_name : String
      "Steam"
    end

    # 人が開くのはストアである。Web API を開いても JSON が出るだけになる。
    def display_url : String
      STORE_URL
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Synthetic
    end

    # 失敗を例外として外に出さず、outcome で返す（仕様書 11.4）。
    def observe : Status::Observation
      web_api, store = Upstream.get_all([@web_api_url, @store_url])

      if reason = web_api_failure(web_api.result)
        return failure(reason)
      end

      store_down = !store.ok?

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        # 二つを並べて叩いているので、遅いほうが利用者の体感になる。
        # どちらかが遅ければ体感も遅いので、主指標だけを見ない。
        latency: {web_api.elapsed, store.elapsed}.max,
        note: store_down ? "ストアが応答しない（#{store.reason}）" : slow_note(web_api, store),
        partial: store_down,
      )
    rescue error
      failure(error.message || error.class.name)
    end

    # 遅かった経路を表示に出す。しきい値に届かなければ空を返す。
    #
    # 全体の時間は遅いほうと同じなので、どちらが遅いかはここでしか分からない。
    # ストアが重いだけなのか Web API が重いのかで、次に見る先が変わる。
    # ストアが落ちているときは呼ばない。落ちた理由のほうが先に読みたい。
    private def slow_note(web_api : Upstream::Fetch, store : Upstream::Fetch) : String
      Upstream.slowest_note([{"Web API", web_api}, {"ストア", store}], @latency_threshold)
    end

    # Web API が使えるかを見て、駄目なら表示に出す一行を返す。使えれば nil を返す。
    #
    # 200 でも本文が読めなければ使えないものとする。上流がエラーページを
    # 200 で返すことがあり、状態コードだけでは足りない。
    #
    # 三つを言い分けるのは、「HTTP 200」とだけ書いた失敗が、応答があったことしか
    # 伝えないためである。届かなかったのか、断られたのか、返ってきたものが
    # 読めなかったのかで、次に見る先が変わる。
    private def web_api_failure(result : HTTP::Client::Response | Exception) : String?
      case result
      in Exception
        "Web API に届かない（#{Upstream.reason(result)}）"
      in HTTP::Client::Response
        if result.status_code != 200
          "Web API が応答しない（HTTP #{result.status_code}）"
        elsif readable?(result.body)
          nil
        else
          "Web API の応答が JSON でない"
        end
      end
    end

    private def readable?(body : String) : Bool
      ServerInfo.from_json(body)
      true
    rescue
      false
    end

    # 合成監視の失敗は前回値へ戻らず、この note がそのまま表示に出る。
    private def failure(reason : String) : Status::Observation
      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Failure,
        checked_at: Time.utc,
        note: reason,
      )
    end
  end
end
