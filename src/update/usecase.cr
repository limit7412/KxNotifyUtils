require "log"

require "./models"
require "./repository"

module Update
  # 確認の結末。
  #
  # 「新しい版が無い」と「確かめられなかった」を呼び出し側が書き分けられるよう、
  # nil ではなく結末そのものを返す。
  # 自動の確認はどちらも黙るが、手動で押したときに黙るのは無反応と区別が付かない。
  enum Outcome
    # 新しい版が出ている。
    Available
    # 実行中の版が最新である。
    UpToDate
    # 一覧を取れなかった。回線が無いか、API が応えなかった。
    Unreachable
    # 実行中の版を比べられない。手元ビルドの 0.1.0-dev がこれにあたる。
    Unknown
  end

  struct CheckResult
    getter outcome : Outcome
    getter release : Release?

    def initialize(@outcome, @release = nil)
    end

    def available? : Bool
      @outcome.available?
    end
  end

  # 新しい版を探し、見つけたかどうかを覚える。
  class Usecase
    Log = ::Log.for("update")

    # 直近の確認で見つけた新しい版。無ければ nil。
    # 設定ウィンドウの情報タブがこれを読む。
    getter available : Release? = nil

    # 一覧を取れた確認が一度でもあったか。
    # 「新しい版は無い」と「まだ確かめていない」を情報タブで書き分けるために持つ。
    getter? checked : Bool = false

    def initialize(@repository : Repository)
      # 知らせ済みの版。同じ版を確認のたびに知らせないための記録である。
      @notified = nil.as(Version?)
    end

    # 自動の確認。
    # 新しい版でも、既に知らせた版なら UpToDate として返し、二度は知らせない。
    def check_quietly(current : String, channel : String) : CheckResult
      result = check(current, channel)
      release = result.release
      return result unless result.available? && release

      if @notified == release.version
        return CheckResult.new(Outcome::UpToDate, release)
      end

      @notified = release.version
      result
    end

    # 新しい版を探す。
    #
    # 手元ビルドの版（0.1.0-dev）は運用しているタグの綴りから外れており、
    # 何と比べても順序が決まらない。確認そのものを行わず Unknown を返す。
    def check(current : String, channel : String) : CheckResult
      running = Version.parse?(current)
      if running.nil?
        Log.debug { "実行中の版を比べられないため確認しない: #{current}" }
        return CheckResult.new(Outcome::Unknown)
      end

      releases = fetch
      return CheckResult.new(Outcome::Unreachable) unless releases

      @checked = true
      newest = newest_in(releases, channel)
      if newest.nil? || newest.version <= running
        @available = nil
        return CheckResult.new(Outcome::UpToDate)
      end

      Log.info { "新しい版が出ている: #{newest.tag}（実行中は #{current}）" }
      @available = newest
      CheckResult.new(Outcome::Available, newest)
    end

    # 回線が無い環境では起動のたびに失敗する。
    # 利用者に対処のしようが無いため、警告ログに留めて知らせない（issue #10）。
    private def fetch : Array(Release)?
      @repository.fetch_releases
    rescue exception
      Log.warn(exception: exception) { "更新の確認に失敗した" }
      nil
    end

    # 応答の並び順に頼らず、対象のうち最も新しいものを選ぶ。
    private def newest_in(releases : Array(Release), channel : String) : Release?
      candidates = channel == "test" ? releases : releases.select(&.stable?)
      candidates.max_by?(&.version)
    end
  end
end
