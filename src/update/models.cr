require "json"

# 更新の確認（issue #10 の第 1 段階）。
# GitHub Releases に出た新しい版を見つけて利用者へ知らせるところまでを担う。
# 取得と置き換えは第 2 段階であり、ここには含まない。
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

    def self.parse?(text : String) : Version?
      match = PATTERN.match(text.strip)
      return nil unless match

      Version.new(
        match[1].to_i,
        match[2].to_i,
        match[3].to_i,
        match[4]?.try(&.to_i),
      )
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

  # 確認の対象にするリリース。
  struct Release
    getter version : Version
    getter tag : String
    getter url : String
    # GitHub 上でプレリリースとして作られたか。
    getter prerelease : Bool

    def initialize(@version, @tag, @url, @prerelease = false)
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

  # 更新の確認の設定（設定ファイルの update セクション）。
  CHANNELS = %w[stable test]
end
