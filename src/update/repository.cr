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

    # 一覧の 1 ページ目だけを見る。
    # 未認証の上限は IP あたり 60 回/時であり、起動時と 24 時間ごとの確認では掛からない。
    PER_PAGE = 20

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
    # 取り込みごとに作るため、安定版を出した後に 20 件を超えるプレリリースが積まれると、
    # その安定版は 1 ページ目から落ちる。
    # 一覧だけを見ていると、stable の利用者に対して候補が空になり、
    # 実際には更新があるのに「最新である」と判定してしまう。
    #
    # /releases/latest は下書きとプレリリースを除いた最新を返すため、
    # 積まれたプレリリースの数に関係なく安定版を 1 回の要求で得られる。
    #
    # test 側は一覧のままでよい。運用しているタグは版が単調に増えるので、
    # 最も新しい版は必ず作成順でも先頭付近に来る。
    def fetch_releases(channel : String) : Array(Release)
      channel == "test" ? fetch_all : fetch_latest_stable
    end

    private def fetch_all : Array(Release)
      response = get("#{BASE}/releases?per_page=#{PER_PAGE}")
      unless response.success?
        raise "GitHub API が #{response.status_code} を返した"
      end

      GitHubRepository.parse(response.body)
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

    private def self.build(payload : Payload) : Release?
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
