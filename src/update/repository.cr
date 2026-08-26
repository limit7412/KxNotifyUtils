require "http/client"
require "json"

require "./models"

module Update
  # リリース一覧を取る境界。
  # 実 API を叩かずに usecase を確かめられるよう、抽象を挟む。
  abstract class Repository
    # 新しい順に並んだリリースを返す。
    # 取れなかった場合は例外を投げる。呼び出し側が握る。
    abstract def fetch_releases : Array(Release)
  end

  # GitHub Releases API から取る実装。
  class GitHubRepository < Repository
    Log = ::Log.for("update")

    ENDPOINT = "https://api.github.com/repos/limit7412/KxNotifyUtils/releases"

    # 未認証の上限は IP あたり 60 回/時である。
    # 確認は起動時と 24 時間ごとなので、この上限には掛からない。
    #
    # 応答は新しい順に並ぶが、必要なのは先頭の数件だけである。
    # 全件を読むと古いリリースが増えるほど無駄が増えるので、1 ページ目だけを見る。
    PER_PAGE = 20

    # 常駐アプリの片手間の確認であり、待たされてまで通す価値は無い。
    # 主ループを止めないよう別のファイバで呼ぶが、それでも延々と待たせない。
    CONNECT_TIMEOUT = 5.seconds
    READ_TIMEOUT    = 5.seconds

    # GitHub API は User-Agent の無い要求を拒む。
    def initialize(@user_agent : String)
    end

    def fetch_releases : Array(Release)
      response = get("#{ENDPOINT}?per_page=#{PER_PAGE}")
      unless response.success?
        raise "GitHub API が #{response.status_code} を返した"
      end

      GitHubRepository.parse(response.body)
    end

    private def get(url : String) : HTTP::Client::Response
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = READ_TIMEOUT
      begin
        client.get(
          "#{uri.path}?#{uri.query}",
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
      Array(Payload).from_json(body).compact_map do |payload|
        next if payload.draft
        version = Version.parse?(payload.tag_name)
        next unless version

        Release.new(version, payload.tag_name, payload.html_url, payload.prerelease)
      end
    end

    # 応答のうち、確認に使う項目だけを読む。
    private struct Payload
      include JSON::Serializable

      getter tag_name : String
      getter html_url : String
      getter prerelease : Bool = false
      getter draft : Bool = false
    end
  end
end
