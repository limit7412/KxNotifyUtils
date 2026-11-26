require "awscr-s3"
require "log"
require "../status/models"
require "../status/repository"

# 配信と内部の記録の置き場所（仕様書 6、11.2）。
#
# 使うのは S3 互換 API だけなので、同じ実装のまま S3 にも向けられる。
# 変えるのはエンドポイントと鍵で、呼び出し側はどちらかを知らない。
module R2
  class Repository < Status::FeedRepository
    Log = ::Log.for("r2")

    # ワールドが読む先（仕様書 6）。
    # 版を上げるときは、この隣に v2/ を並べて六か月は両方を配る（仕様書 9）。
    FEED_KEY = "v1/status.json"

    # 合成監視の履歴と前回値（仕様書 6）。カスタムドメインを割り当てない。
    STATE_KEY = "state.json"

    # 配信物に付ける（仕様書 5.2 の手順 6）。
    # TTL はここで決まる。Cache Rules はキャッシュの対象に入れるだけで、
    # 実際の保持時間はオブジェクトのこの値に従う（仕様書 6）。
    FEED_HEADERS = {
      "Content-Type"  => "application/json; charset=utf-8",
      "Cache-Control" => "public, max-age=30",
    }

    # 内部の記録は誰にも配らないので、キャッシュの指示を付けない。
    STATE_HEADERS = {
      "Content-Type" => "application/json",
    }

    # R2 は region を見ないが、SigV4 の署名には要る。
    # S3 互換の実装が置き場所を問わないときに使う決まり文句を渡す。
    REGION = "auto"

    def initialize(
      endpoint : String,
      access_key_id : String,
      secret_access_key : String,
      @public_bucket : String,
      @state_bucket : String,
    )
      @client = Awscr::S3::Client.new(
        region: REGION,
        aws_access_key: access_key_id,
        aws_secret_key: secret_access_key,
        endpoint: endpoint,
      )
    end

    # 前回の記録を読む（仕様書 5.2 の手順 4）。
    #
    # 読めない理由で処理は分けない。初回でまだ無いのか、壊れているのか、
    # 版が違うのかにかかわらず、履歴なしとして進む（仕様書 5.2）。
    #
    # ログのほうは分ける。鍵や設定の誤りは毎回同じように起き、初回の空振りと
    # 同じ顔をされると、何年でも気付けないままになる。
    def load_state : Status::State?
      state = Status::State.from_json(@client.get_object(@state_bucket, STATE_KEY).body)
      return state if state.supported?

      Log.warn do
        "state の版が違うので履歴なしで進む " \
        "v=#{state.version} 読める版=#{Status::State::SCHEMA_VERSION}"
      end
      nil
    rescue Awscr::S3::NoSuchKey
      # 初回はここへ来る。上流の S3 実装が別のコードを返す場合は
      # 下の rescue が拾うので、履歴なしで進むことに変わりはない。
      Log.info { "state がまだ無い。履歴なしで始める" }
      nil
    rescue error
      Log.error(exception: error) { "state を読めなかったので履歴なしで進む" }
      nil
    end

    def save_state(state : Status::State) : Nil
      put(@state_bucket, STATE_KEY, state.to_json, STATE_HEADERS)
    end

    # 配信する（仕様書 5.2 の手順 6）。
    # 失敗しても再試行しない。次の実行に任せる（仕様書 5.3）。
    def save_feed(feed : Status::Feed) : Nil
      put(@public_bucket, FEED_KEY, feed.to_json, FEED_HEADERS)
    end

    # 本文は Bytes にしてから渡す。
    #
    # awscr-s3 は Content-Length を body.size から作るが、String#size が数えるのは
    # 文字であってバイトではない。note には上流由来の文字列が入り（仕様書 4）、
    # そこに日本語が一字でもあると、実際より短い長さを送ることになる。
    # Bytes#size はバイト数なので、このずれが起きない。
    private def put(bucket : String, key : String, body : String, headers : Hash(String, String)) : Nil
      @client.put_object(bucket, key, body.to_slice, headers)
    end
  end
end
