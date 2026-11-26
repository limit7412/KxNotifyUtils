require "../status/models"
require "../status/repository"
require "../status/usecase"
require "../upstream"

# BOOTH の合成監視（仕様書 3.3）。
#
# 公式のステータスページが無く、障害の告知はお知らせページに事後掲載される。
# そのため、トップと作者自身の商品ページが返るかで状態を推し量る。
#
# 購入後のダウンロード経路は監視しない。ログインが要るためである（仕様書 3.3）。
#
# models.cr を持たないのは、読む JSON がまだ無いからである。
# お知らせの題名を note に載せる仕組み（仕様書 3.3）はここに入っていない。
# 抽出は HTML の構造に依存し、その構造をまだ実物で見ていない（仕様書 12）。
module Booth
  class Repository < Status::SourceRepository
    TOP_URL = "https://booth.pm/ja"

    # top_url としきい値を受け取るのは spec から差し替えるためである。
    # 表示に出す url は定数のままにする（仕様書 4）。
    def initialize(
      @item_id : String,
      @top_url : String = TOP_URL,
      @latency_threshold : Time::Span = Status::Usecase::LATENCY_THRESHOLD,
    )
    end

    def service_id : String
      "booth"
    end

    def display_name : String
      "BOOTH"
    end

    def display_url : String
      TOP_URL
    end

    def source_kind : Status::SourceKind
      Status::SourceKind::Synthetic
    end

    # 作者自身の公開商品。上流の都合で消えないものを選ぶ（仕様書 3.3）。
    def item_url : String
      "#{@top_url}/items/#{@item_id}"
    end

    def observe : Status::Observation
      top, item = Upstream.get_all([@top_url, item_url])

      # 両方落ちて初めて届かなかったとみなす（仕様書 3.3）。
      # 二つとも理由を残す。片方だけを出すと、もう片方が何で落ちたか分からない。
      unless top.ok? || item.ok?
        return failure("BOOTH に届かない（#{top.reason} / #{item.reason}）")
      end

      Status::Observation.new(
        service_id: service_id,
        outcome: Status::Outcome::Success,
        checked_at: Time.utc,
        # 二つを並べて叩いているので、遅いほうが利用者の体感になる。
        latency: {top.elapsed, item.elapsed}.max,
        note: note_for(top, item),
        partial: !(top.ok? && item.ok?),
      )
    rescue error
      failure(error.message || error.class.name)
    end

    # 片方だけが落ちているときは、どちらかを出す。
    # 商品ページだけが落ちる場合は、その商品が消えた可能性もある。
    # 月次の点検でそこを見る（仕様書 9）ため、どちらが落ちたかを残す。
    #
    # 両方届いていれば、遅かった経路を出す。全体の時間は遅いほうと同じなので、
    # どちらが遅いかはここでしか分からない。しきい値に届かなければ空になる。
    private def note_for(top : Upstream::Fetch, item : Upstream::Fetch) : String
      return "商品ページが応答しない" unless item.ok?
      return "トップが応答しない" unless top.ok?

      Upstream.slowest_note([{"トップ", top}, {"商品ページ", item}], @latency_threshold)
    end

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
