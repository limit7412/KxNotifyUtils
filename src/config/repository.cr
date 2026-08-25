require "json"
require "./models"

module Config
  # PNG ファイルの先頭 8 バイト。
  PNG_SIGNATURE = Bytes[137, 80, 78, 71, 13, 10, 26, 10]

  # 設定ファイルの読み書きを担う境界。
  # 検証と反映は usecase 側にあり、ここはファイルとの往復だけを行う。
  abstract class Repository
    abstract def path : String
    abstract def exists? : Bool
    abstract def load : Root
    abstract def save(root : Root) : Nil
    # sound と icon に指定されたファイルの存在確認。検証に使う。
    abstract def file_exists?(path : String) : Bool
    # icon に指定されたファイルが PNG かどうか。検証に使う。
    abstract def png_file?(path : String) : Bool
    # 外部エディタでの編集を検知するための更新時刻。取得できない場合は nil を返す。
    abstract def modified_at : Time?
  end

  # 実ファイルに対する Repository 実装。
  class FileRepository < Repository
    getter path : String

    def initialize(@path : String)
    end

    def exists? : Bool
      File.exists?(@path)
    end

    def load : Root
      Root.from_json(File.read(@path))
    end

    def save(root : Root) : Nil
      Dir.mkdir_p(File.dirname(@path))
      # 書き込み中に落ちても設定を失わないよう、一時ファイルへ書いてから置き換える。
      temporary = "#{@path}.tmp"
      File.write(temporary, root.to_pretty_json)
      File.rename(temporary, @path)
    end

    # 存在するだけでなく通常のファイルであることを確かめる。
    # ディレクトリを通すと、アイコンは読み込みに失敗して既定へ落ち、
    # 通知音はそのパスがそのままシンクへ送られる。
    def file_exists?(path : String) : Bool
      File.file?(path)
    end

    # 中身まで見て PNG かどうかを判断する。
    # シンクへは読み出した内容をそのまま base64 で渡すため、
    # 拡張子だけを見て通すと、PNG でないデータが表示できないアイコンとして送られる。
    def png_file?(path : String) : Bool
      return false unless File.file?(path)

      File.open(path) do |file|
        header = Bytes.new(PNG_SIGNATURE.size)
        next false unless file.read_fully?(header)
        header == PNG_SIGNATURE
      end
    rescue
      false
    end

    def modified_at : Time?
      File.info(@path).modification_time
    rescue
      nil
    end
  end
end
