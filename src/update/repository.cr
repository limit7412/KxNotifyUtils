require "http/client"
require "json"

require "./models"

module Update
  # リリースを取る境界。
  # 実 API を叩かずに usecase を確かめられるよう、抽象を挟む。
  abstract class Repository
    # 指定したチャンネルで候補になるリリースを返す。
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
    # 自動のプレリリースは最新の安定版の次のパッチとして作られるが、
    # メジャーやマイナーのプレリリースを手で作ることはできる。
    # その場合、後から積まれた自動のプレリリースのほうが版としては古くなり、
    # 作成順と版の順序が食い違う。1 ページ目だけを見ていると、
    # 手で作ったほうが押し出されて見つからない。
    #
    # 上限を置くのは、たどる回数を積まれた数に比例させないためである。
    # 未認証の上限は IP あたり 60 回/時であり、確認のたびに際限なくたどると
    # そこへ近づくほど確認そのものが失敗しやすくなる。
    # 300 件を超えて押し出されるほど積まれた場合は、ログに残して 1 ページ目側を採る。
    MAX_PAGES = 3

    # 常駐アプリの片手間の確認であり、待たされてまで通す価値は無い。
    # 主ループを止めないよう別のファイバで呼ぶが、それでも延々と待たせない。
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 5.seconds

    # GitHub API は User-Agent の無い要求を拒む。
    def initialize(@user_agent : String)
    end

    # 安定版と test でエンドポイントを変える。
    #
    # 一覧は作成の新しい順に返る。このリポジトリはプレリリースを master への
    # 取り込みごとに作るため、安定版を出した後にプレリリースが積まれ続けると、
    # その安定版はいずれ取得の範囲から落ちる。
    # 一覧だけを見ていると、stable の利用者に対して候補が空になり、
    # 実際には更新があるのに「最新である」と判定してしまう。
    #
    # /releases/latest は下書きとプレリリースを除いた最新を返すため、
    # 積まれたプレリリースの数に関係なく安定版を 1 回の要求で得られる。
    #
    # test 側は一覧をたどる。作成順と版の順序が食い違いうるためである（MAX_PAGES 参照）。
    def fetch_releases(channel : String) : Array(Release)
      channel == "test" ? fetch_all : fetch_latest_stable
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
