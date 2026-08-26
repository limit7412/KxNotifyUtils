require "json"

# 更新の確認と置き換え（issue #10）。
# GitHub Releases に出た新しい版を見つけて知らせ、取得して次の起動で置き換えるまでを担う。
module Update
  # リリースのタグが表す版。
  #
  # 運用しているタグは `X.Y.Z` と `X.Y.Z-testN` の 2 つだけである（PR #9、PR #11）。
  # それ以外の綴りは版として扱わない。手元ビルドの `0.1.0-dev` がこれにあたり、
  # 比較の対象にならないことを parse? が nil を返すことで表す。
  struct Version
    include Comparable(Version)

    # 手動で作る安定版のタグには v が付くことがあり、リリースの手順が剥がしている。
    # 確認する側は API のタグをそのまま読むため、ここでも受け付ける。
    PATTERN = /\A[vV]?(\d+)\.(\d+)\.(\d+)(?:-test(\d+))?\z/

    getter major : Int32
    getter minor : Int32
    getter patch : Int32
    # プレリリースの番号。安定版では nil になる。
    getter test : Int32?

    def initialize(@major, @minor, @patch, @test = nil)
    end

    # 数値は Int32 に収まる範囲でだけ読む。
    # 正規表現は桁数を見ないため、設定へ手で書かれた桁あふれの綴りも一致してしまう。
    # to_i は範囲外で例外を投げ、設定の読み込みの外で呼ぶ経路（起動時の復元）ごと落とす。
    def self.parse?(text : String) : Version?
      match = PATTERN.match(text.strip)
      return nil unless match

      major = match[1].to_i?
      minor = match[2].to_i?
      patch = match[3].to_i?
      return nil unless major && minor && patch

      if number = match[4]?
        test = number.to_i?
        return nil unless test
        return Version.new(major, minor, patch, test)
      end

      Version.new(major, minor, patch)
    end

    def stable? : Bool
      @test.nil?
    end

    # 同じ X.Y.Z なら安定版のほうが新しい（SemVer のプレリリースと同じ扱い）。
    # 0.0.2-test1 は 0.0.2 より古く、0.0.1 より新しい。
    def <=>(other : Version) : Int32
      return @major <=> other.major unless @major == other.major
      return @minor <=> other.minor unless @minor == other.minor
      return @patch <=> other.patch unless @patch == other.patch

      mine = @test
      theirs = other.test
      return 0 if mine.nil? && theirs.nil?
      return 1 if mine.nil?
      return -1 if theirs.nil?
      mine <=> theirs
    end

    def to_s(io : IO) : Nil
      io << @major << '.' << @minor << '.' << @patch
      if number = @test
        io << "-test" << number
      end
    end
  end

  # リリースに添付された実行ファイル（issue #10 第 2 段階）。
  #
  # digest を持たないものは扱わない。置き換えるのは実行ファイルそのものであり、
  # 取ってきたものが本当にそのリリースのものかを確かめずに置くわけにはいかない。
  # 確かめられなければ、リリースページを開いてもらうところまでで止める。
  struct Asset
    # sha256 の 16 進表記。API は "sha256:..." で返すが、接頭辞は落として持つ。
    getter digest : String
    getter url : String
    getter size : Int64

    DIGEST_PREFIX = "sha256:"
    # 16 進 64 桁。桁数と字種を見ておかないと、照合の相手として使えない値を持ち込む。
    DIGEST_PATTERN = /\A[0-9a-f]{64}\z/

    def initialize(@digest, @url, @size)
    end

    # API の応答から、置き換えに使えるものだけを組み立てる。
    #
    # 名前で絞るのは、リリースに別のアセットが増えても取り違えないためである。
    # 大きさを見るのは、宣言と実物の食い違いを取得の側で打ち切れるようにするためである。
    def self.parse?(name : String, url : String, digest : String?, size : Int64) : Asset?
      return nil unless name == ASSET_NAME
      return nil unless size > 0
      return nil unless digest && digest.starts_with?(DIGEST_PREFIX)

      hex = digest[DIGEST_PREFIX.size..].downcase
      return nil unless DIGEST_PATTERN.matches?(hex)

      Asset.new(hex, url, size)
    end
  end

  # 確認の対象にするリリース。
  struct Release
    getter version : Version
    getter tag : String
    getter url : String
    # GitHub 上でプレリリースとして作られたか。
    getter prerelease : Bool
    # 置き換えに使えるアセット。digest が無いか、名前が違えば nil になる。
    getter asset : Asset?

    def initialize(@version, @tag, @url, @prerelease = false, @asset = nil)
    end

    # 安定版のチャンネルで拾う対象か。
    #
    # タグの綴りと GitHub の印の両方を見る。
    # プレリリースは `X.Y.Z-testN` で自動生成されるので普段はどちらも同じことを言うが、
    # 手動で作ったリリースにプレリリースの印だけが付くことはありうる。
    def stable? : Bool
      !@prerelease && @version.stable?
    end
  end

  # 集めた候補と、集めきれたかどうか。
  #
  # 取得には上限があるため、「新しい版は無い」と言い切れないことがある。
  # 集めきれていないのに最新だと言うと、実際には出ている版を見落としたまま
  # 利用者へ「最新である」と伝えることになる。
  struct Catalog
    getter releases : Array(Release)
    # 上限に掛からず最後まで取れたか。
    getter? complete : Bool

    def initialize(@releases, @complete = true)
    end
  end

  # 更新の確認の設定（設定ファイルの update セクション）。
  CHANNELS = %w[stable test]

  # リリースに添付される実行ファイルの名前（PR #9、PR #11）。
  ASSET_NAME = "KxNotifyUtils.exe"
end
