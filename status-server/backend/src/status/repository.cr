require "./models"

module Status
  # 取得元。Statuspage 系も合成監視も同じ契約を満たす（仕様書 11.1）。
  abstract class SourceRepository
    abstract def service_id : String
    abstract def display_name : String
    # 配信 JSON の url に入れる、人が開く先（仕様書 4）。
    # 取得先とは限らない。Statuspage 系は summary.json ではなくページを指す。
    abstract def display_url : String
    abstract def source_kind : SourceKind
    # 例外を外に出さず、失敗は Observation の outcome として返す（仕様書 11.4）。
    # 一つの取得元の例外で実行全体が止まると、他のサービスまで更新が止まる。
    abstract def observe : Observation
  end

  # 書き出し先。R2 でも S3 でも同じ契約で扱う（仕様書 11.1）。
  abstract class FeedRepository
    abstract def load_state : State?
    abstract def save_state(state : State)
    abstract def save_feed(feed : Feed)
  end
end
