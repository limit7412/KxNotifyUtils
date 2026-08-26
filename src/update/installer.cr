require "digest/sha256"
require "json"
require "log"

require "./models"
require "./repository"

module Update
  # 取得した実行ファイルを次の起動で使えるようにする（issue #10 第 2 段階）。
  #
  # 実行中の exe は上書きできないが、リネームはできる。この性質だけを使う。
  # 走っている実行ファイルを .old へ退避し、取っておいた .new を元の場所へ移す。
  # exe のパスが変わらないため、SteamVR へ登録したマニフェストの
  # binary_path_windows は書き換えなくてよい。
  #
  # 取得と置き換えを分けてあるのは、置き換えが失敗すると起動しない exe が残る操作だからである。
  # 常駐している間は取得と検証までを行い、置き換えは起動シーケンスの先頭で行う。
  class Installer
    Log = ::Log.for("update")

    # 読み出しの単位。
    BUFFER_SIZE = 64 * 1024

    # 退避した実行ファイルを戻せなかった。
    #
    # 正規のパスに実行ファイルが無い状態であり、置き換えの失敗の中でも扱いが違う。
    # 取得しておいたものを捨ててはならない。捨てると復旧の材料が .old だけになり、
    # そちらも戻せなかったからここへ来ている。
    class RollbackFailed < Exception
      getter executable_path : String
      getter previous_path : String
      getter staged_path : String

      def initialize(@executable_path, @previous_path, @staged_path)
        super("退避した実行ファイルを戻せなかった: #{@previous_path} を #{@executable_path} へ戻す必要がある")
      end
    end

    # 取得しておいた実行ファイルに添える記録。
    #
    # 取得したときに一度照合しているが、置き換える前にもう一度照合する。
    # 取得から次の起動までの間に壊れたものを、そのまま実行ファイルとして置くわけにはいかない。
    struct Staged
      include JSON::Serializable

      getter tag : String
      getter digest : String
      getter size : Int64

      def initialize(@tag, @digest, @size)
      end
    end

    getter staged_path : String
    getter previous_path : String

    def initialize(
      @repository : Repository,
      @running_version : String,
      @executable_path : String,
      @staged_path : String,
      @previous_path : String,
    )
    end

    # 取得したものに添える記録の置き場所。
    def metadata_path : String
      "#{@staged_path}.json"
    end

    # リリースのアセットを取り、記録と一緒に残す。
    #
    # アセットを持たないリリースでは何もせず偽を返す。
    # 手で作った安定版に exe を添え忘れた場合がこれにあたり、
    # そのときは利用者にリリースページから取ってもらう。
    def download(release : Release) : Bool
      asset = release.asset
      unless asset
        Log.info { "置き換えに使えるアセットが無い: #{release.tag}" }
        return false
      end

      @repository.download(asset, @staged_path)
      File.write(metadata_path, Staged.new(release.tag, asset.digest, asset.size).to_json)
      Log.info { "次の起動で置き換える実行ファイルを取得した: #{release.tag}" }
      true
    end

    # 取得済みで、今のチャンネルに合い、記録と照合の通る実行ファイル。無ければ nil を返す。
    #
    # 合わないものはその場で捨てる。残しておいても次の起動でまた同じ照合に落ちるだけであり、
    # 取り直しの機会を与えたほうがよい。
    def staged(channel : String) : Staged?
      return nil unless File.exists?(metadata_path) && File.exists?(@staged_path)

      record = Staged.from_json(File.read(metadata_path))

      # 今のチャンネルが拾う版かを見る。
      #
      # 取得と置き換えの間には、設定を変えて再起動するだけの間がある。
      # test で取ったプレリリースを取得済みのまま stable へ変えられると、
      # 選び直した設定に反してプレリリースが入る。
      unless covered_by?(record.tag, channel)
        Log.info { "取得しておいた #{record.tag} は今のチャンネル（#{channel}）の対象ではないため捨てる" }
        discard
        return nil
      end

      # 実行中より新しいものだけを置く。
      # 取得してから起動しないまま日が経ち、その間に手で新しい版へ入れ替えられていると、
      # 取っておいた古いほうへ引き戻すことになる。
      unless newer_than_running?(record.tag)
        Log.info { "取得しておいた #{record.tag} は実行中の #{@running_version} より新しくないため捨てる" }
        discard
        return nil
      end

      return record if verified?(record)

      Log.warn { "取得しておいた実行ファイルが記録と合わないため捨てる: #{@staged_path}" }
      discard
      nil
    rescue exception : JSON::Error | IO::Error
      Log.warn(exception: exception) { "取得しておいた実行ファイルを確かめられないため捨てる" }
      discard
      nil
    end

    # 取得しておいたものを消す。
    #
    # 消せなくても投げない。呼ぶのは失敗した後の後始末の場面であり、
    # ここで投げると、元の失敗を伝える経路まで落ちる。
    def discard : Nil
      File.delete?(@staged_path)
      File.delete?(metadata_path)
    rescue exception : IO::Error
      Log.warn(exception: exception) { "取得しておいたものを消せなかった: #{@staged_path}" }
    end

    # 片方だけ残った取得を片付ける。
    #
    # 取得の最中に終了すると、書きかけの実行ファイルだけが残る。
    # 記録は取得が終わってから書くためである。
    # そのままでは最大で MAX_ASSET_SIZE 分の書きかけが次の取得まで居座る。
    #
    # 呼ぶのは起動時だけとする。取得の最中に呼ぶと、
    # 書いている途中のものを消すことになる。
    def discard_incomplete : Nil
      staged = File.exists?(@staged_path)
      metadata = File.exists?(metadata_path)
      return if staged == metadata

      Log.info { "途中で終わった取得を片付ける: #{@staged_path}" }
      discard
    end

    # 退避しておいた古い実行ファイルを消す。
    #
    # 置き換えた直後は、その exe がまだ走っているため消せない。
    # 次の起動で消す。消せなくても常駐は続ける。次の機会にまた試す。
    def discard_previous : Nil
      return unless File.exists?(@previous_path)

      File.delete(@previous_path)
      Log.info { "置き換え前の実行ファイルを消した: #{@previous_path}" }
    rescue exception : IO::Error
      Log.warn(exception: exception) { "置き換え前の実行ファイルを消せなかった: #{@previous_path}" }
    end

    # 実行ファイルを置き換える。
    #
    # 退避に成功した後で移動に失敗したら、退避したものを戻す。
    # 戻せなければ正規のパスに実行ファイルが無い状態が残るため、
    # 通常の失敗とは別の例外にして呼び出し側へ伝える。
    # そちらでは取得しておいたものを捨ててはならない。復旧の材料になる。
    def apply(record : Staged) : Bool
      # 実行ファイルが無ければ退避のしようがない。
      # このまま進むと、下の delete? が前回の失敗で残した .old を消してしまう。
      # 復旧の材料を減らすだけなので、置き換えの前に断る。
      unless File.exists?(@executable_path)
        raise RollbackFailed.new(@executable_path, @previous_path, @staged_path)
      end

      File.delete?(@previous_path)
      move(@executable_path, @previous_path)

      begin
        move(@staged_path, @executable_path)
      rescue exception
        begin
          move(@previous_path, @executable_path)
        rescue rollback
          Log.error(exception: rollback) do
            "退避した実行ファイルを戻せなかった。" \
            "#{@previous_path} を #{@executable_path} へ戻すか、" \
            "#{@staged_path} を置く必要がある"
          end
          raise RollbackFailed.new(@executable_path, @previous_path, @staged_path)
        end

        raise exception
      end

      # ここから先は後始末である。置き換えは済んでおり、成否は変わらない。
      # 投げると、置き換えが成功したのに失敗として扱われ、
      # 新しい実行ファイルを起動しないまま終わることになる。
      # 消せずに残っても、次の起動で discard_incomplete が片方だけの状態として片付ける。
      begin
        File.delete?(metadata_path)
      rescue exception : IO::Error
        Log.warn(exception: exception) { "置き換えた後の記録を消せなかった: #{metadata_path}" }
      end

      Log.info { "実行ファイルを #{record.tag} へ置き換えた" }
      true
    end

    # 実ファイルの入れ替え。
    #
    # 置き換えの成否はこの 3 回の移動だけで決まる。
    # 1 か所にまとめてあるのは、失敗の場合分けをここへ寄せるためであり、
    # spec ではここを差し替えて、戻しまで失敗する状況を作る。
    protected def move(from : String, to : String) : Nil
      File.rename(from, to)
    end

    # そのタグが、指定のチャンネルで拾う対象か。
    #
    # 見るのはタグの綴りだけである。GitHub のプレリリースの印は記録に持っていないが、
    # 判断したいのは「今のチャンネルならこの版を見つけたか」であり、
    # チャンネルの絞り込み（Usecase#newest_in）と同じ基準で足りる。
    private def covered_by?(tag : String, channel : String) : Bool
      return true if channel == "test"

      version = Version.parse?(tag)
      return true unless version

      version.stable?
    end

    # 取得しておいたものが実行中より新しいか。
    #
    # どちらかが版として読めなければ新しいものとして扱う。
    # 手元ビルド（0.1.0-dev）がこれにあたるが、そこへ辿り着くのは
    # 利用者が明示的に取得を押した場合だけであり、その意図を優先する。
    private def newer_than_running?(tag : String) : Bool
      running = Version.parse?(@running_version)
      staged = Version.parse?(tag)
      return true unless running && staged

      staged > running
    end

    # 記録された大きさと digest の両方を見る。
    # 大きさを先に見るのは、違っていれば読まずに落とせるためである。
    private def verified?(record : Staged) : Bool
      return false unless File.info(@staged_path).size == record.size

      digest_of(@staged_path) == record.digest
    end

    private def digest_of(path : String) : String
      digest = Digest::SHA256.new
      File.open(path, "rb") do |file|
        buffer = Bytes.new(BUFFER_SIZE)
        while (read = file.read(buffer)) > 0
          digest.update(buffer[0, read])
        end
      end
      digest.final.hexstring
    end
  end
end
