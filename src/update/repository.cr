require "http/client"
require "json"
require "set"

require "./models"

module Update
  # リリースを取る境界。
  # 実 API を叩かずに usecase を確かめられるよう、抽象を挟む。
  abstract class Repository
    # 候補になるリリースを返す。並び順は問わない。呼び出し側が版で比べる。
    # チャンネルは取り方を選ぶためだけに渡す。絞り込みは呼び出し側が行う。
    # 取れなかった場合は例外を投げる。呼び出し側が握る。
    abstract def fetch_releases(channel : String) : Array(Release)
  end

  # GitHub Releases API から取る実装。
  class GitHubRepository < Repository
    Log = ::Log.for("update")

    BASE = "https://api.github.com/repos/limit7412/KxNotifyUtils"

    # 一覧の 1 ページあたりの件数。100 が API の上限である。
    PER_PAGE = 100

    # 一覧をたどるページ数の上限。
    #
    # 一覧は作成の新しい順に返るが、版の順序とは食い違いうる。
    # 自動のプレリリースは最新の安定版の次のパッチとして作られる一方、
    # メジャーやマイナーのプレリリースや保守版の安定版は手で作れるためである。
    # そのため作成順の先頭だけを見るわけにいかず、ある程度の範囲を集めて版で比べる。
    #
    # 上限を置くのは、たどる回数を積まれた数に比例させないためである。
    # 未認証の上限は IP あたり 60 回/時であり、確認のたびに際限なくたどると
    # そこへ近づくほど確認そのものが失敗しやすくなる。
    # 上限に達したらログに残す。黙って切ると「全部見た」と読めてしまう。
    MAX_PAGES = 3

    # 常駐アプリの片手間の確認であり、待たされてまで通す価値は無い。
    # 主ループを止めないよう別のファイバで呼ぶが、それでも延々と待たせない。
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 5.seconds

    # GitHub API は User-Agent の無い要求を拒む。
    def initialize(@user_agent : String)
    end

    # 一覧と /releases/latest の両方を見て、重複を除いて返す。
    # チャンネルによる絞り込みは呼び出し側が行う。ここは候補を集めるだけである。
    #
    # 一覧だけでは足りない。作成の新しい順に返るため、安定版を出した後に
    # プレリリースが積まれ続けると、その安定版はいずれ取得の範囲から落ちる。
    #
    # /releases/latest だけでも足りない。これが返すのは GitHub が latest とした 1 件、
    # すなわち下書きとプレリリースを除いて最も新しく作られたものであり、
    # 版番号が最大のものとは限らない。2.0.0 の後に保守版の 1.5.1 を出すと、
    # 返るのは 1.5.1 になり、1.6.0 の利用者には 2.0.0 が見えなくなる。
    #
    # 両方を合わせれば、版番号で比べる候補が一覧から得られ、
    # 一覧の範囲から押し出された安定版も latest から拾える。
    def fetch_releases(channel : String) : Array(Release)
      GitHubRepository.merge(fetch_all, fetch_latest_stable)
    end

    # タグで重複を除く。一覧と latest は同じリリースを返しうる。
    # 通信から切り離して spec で確かめられるようにしてある。
    def self.merge(releases : Array(Release), extra : Array(Release)) : Array(Release)
      seen = releases.map(&.tag).to_set
      releases + extra.reject { |release| seen.includes?(release.tag) }
    end

    private def fetch_all : Array(Release)
      releases = [] of Release

      (1..MAX_PAGES).each do |page|
        response = get("#{BASE}/releases?per_page=#{PER_PAGE}&page=#{page}")
        unless response.success?
          raise "GitHub API が #{response.status_code} を返した"
        end

        payloads = Array(Payload).from_json(response.body)
        releases.concat(payloads.compact_map { |payload| GitHubRepository.build(payload) })

        # 上限に満たない件数で返ってきたら最後のページである。
        break if payloads.size < PER_PAGE

        if page == MAX_PAGES
          Log.warn do
            "リリースが #{MAX_PAGES * PER_PAGE} 件を超えている。" \
            "これより古いリリースは更新の確認の対象にしない"
          end
        end
      end

      releases
    end

    # 安定版が 1 つも無いリポジトリでは 404 が返る。
    # 取れなかったのではなく「無い」ので、空として扱う。
    private def fetch_latest_stable : Array(Release)
      response = get("#{BASE}/releases/latest")
      return [] of Release if response.status_code == 404
      unless response.success?
        raise "GitHub API が #{response.status_code} を返した"
      end

      GitHubRepository.parse_one(response.body)
    end

    private def get(url : String) : HTTP::Client::Response
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      begin
        query = uri.query
        client.get(
          query ? "#{uri.path}?#{query}" : uri.path,
          HTTP::Headers{
            "Accept"     => "application/vnd.github+json",
            "User-Agent" => @user_agent,
          },
        )
      ensure
        client.close
      end
    end

    # 版として読めないタグと下書きは黙って捨てる。
    # 確認の目的は新しい版を見つけることであり、
    # 運用しているタグの綴りから外れたものを見つけられなくても実害が無い。
    #
    # 応答の読み取りだけを spec で確かめられるよう、通信から切り離してある。
    def self.parse(body : String) : Array(Release)
      Array(Payload).from_json(body).compact_map { |payload| build(payload) }
    end

    # /releases/latest は配列ではなく 1 件を返す。
    def self.parse_one(body : String) : Array(Release)
      release = build(Payload.from_json(body))
      release ? [release] : [] of Release
    end

    # ページごとの読み取りからも使うため、クラス内に公開しておく。
    def self.build(payload : Payload) : Release?
      return nil if payload.draft
      version = Version.parse?(payload.tag_name)
      return nil unless version

      Release.new(version, payload.tag_name, payload.html_url, payload.prerelease)
    end

    # 応答のうち、確認に使う項目だけを読む。
    struct Payload
      include JSON::Serializable

      getter tag_name : String
      getter html_url : String
      getter prerelease : Bool = false
      getter draft : Bool = false
    end
  end
end
