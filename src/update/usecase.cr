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

    # 直近の確認に使ったチャンネル。まだ確認できていなければ nil。
    #
    # 結果と一緒に覚えておかないと、設定を test から stable へ変えたときに、
    # 直前に見つけたプレリリースが次の確認まで表示に残る。
    # 逆向きでは、プレリリースを一度も調べていないのに「最新である」と出る。
    getter checked_channel : String? = nil

    def initialize(@repository : Repository)
      @available = nil.as(Release?)
      # 知らせ済みの版。同じ版を確認のたびに知らせないための記録である。
      # 起動のたびに知らせ直さないよう、設定へ残して次の起動で復元する。
      @notified = nil.as(Version?)
    end

    # 知らせ済みの版のタグ。設定へ書き戻すために使う。
    def notified_tag : String
      @notified.try(&.to_s) || ""
    end

    # 設定から復元する。版として読めない値は記録が無いものとして扱う。
    def notified_tag=(tag : String) : Nil
      @notified = Version.parse?(tag)
    end

    # 知らせた版として覚える。
    # 自動の確認は check_quietly が自分で覚えるが、手動の確認は check を通るため、
    # 知らせた側が明示的に呼ぶ。呼ばないと次の確認や再起動で同じ版をもう一度知らせる。
    #
    # 記録より古い版で上書きしない。チャンネルを往復したときに、
    # 既に伝えてある版より古いものへ記録が下がると、その版をまた知らせることになる。
    def mark_notified(release : Release) : Nil
      notified = @notified
      return if notified && notified >= release.version

      @notified = release.version
    end

    # 今のチャンネルで見つけている新しい版。
    # 別のチャンネルで確認した結果は、設定と食い違うため返さない。
    def available(channel : String) : Release?
      return nil unless @checked_channel == channel
      @available
    end

    # 今のチャンネルで確認が成り立ったか。
    # 「新しい版は無い」と「まだ確かめていない」を情報タブで書き分けるために使う。
    def checked?(channel : String) : Bool
      @checked_channel == channel
    end

    # 自動の確認。
    # 知らせた版と同じか、それより古い版なら UpToDate として返し、二度は知らせない。
    #
    # 等値で見るわけにはいかない。チャンネルを往復すると記録が入れ替わるためである。
    # stable の 2.0.0 を知らせた後に test の 2.1.0-test1 を知らせて stable へ戻すと、
    # 記録は 2.1.0-test1 になっており、等値では 2.0.0 を未通知と判断して知らせ直す。
    # 「これ以上に新しいものは既に伝えてある」と読めば、往復しても増えない。
    def check_quietly(current : String, channel : String) : CheckResult
      result = check(current, channel)
      release = result.release
      return result unless result.available? && release

      notified = @notified
      if notified && notified >= release.version
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

      releases = fetch(channel)
      return CheckResult.new(Outcome::Unreachable) unless releases

      @checked_channel = channel
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
    private def fetch(channel : String) : Array(Release)?
      @repository.fetch_releases(channel)
    rescue exception
      Log.warn(exception: exception) { "更新の確認に失敗した" }
      nil
    end

    # 応答の並び順に頼らず、対象のうち最も新しいものを選ぶ。
    #
    # stable では repository が安定版だけを返すが、ここでも絞る。
    # 絞りをどちらか一方に任せると、片方を直したときにもう片方が黙って通してしまう。
    private def newest_in(releases : Array(Release), channel : String) : Release?
      candidates = channel == "test" ? releases : releases.select(&.stable?)
      candidates.max_by?(&.version)
    end
  end
end
