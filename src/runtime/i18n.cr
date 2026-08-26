require "json"
require "./win32"

module Runtime
  # UI 文字列の辞書（issue #4）。
  #
  # 対象はトレイのメニューとバルーン、設定ウィンドウの表示である。
  #
  # 設定の検証エラーは対象にしない。同じ文字列がダイアログとログの両方へ出るため、
  # ここで引くと「設定の検証エラー: ...」のログが混在言語になる。
  # 分けるには ValidationError が整形済みの文字列ではなくキーと値を運ぶ形へ変える必要があり、
  # それはログの言語をどうするかの決定と一緒に行う（issue #4）。
  #
  # 翻訳はコンパイル時に埋め込む。配布物は exe 1 ファイルであり（仕様書 8.2 節）、
  # 翻訳ファイルを exe の隣へ置く方式はその決定と衝突するためである。
  module I18n
    LOCALES = {
      "ja" => Hash(String, String).from_json({{ read_file("#{__DIR__}/../../locales/ja.json") }}),
      "en" => Hash(String, String).from_json({{ read_file("#{__DIR__}/../../locales/en.json") }}),
    }

    # ja を正とする。en に無いキーは ja の文字列で表示される。
    DEFAULT_LOCALE = "ja"

    PLACEHOLDER = /\{(\w+)\}/

    # GetUserDefaultUILanguage の下位 10 ビットが主言語を表す。日本語は 0x11。
    LANG_JAPANESE = 0x11_u16

    @@locale : String = DEFAULT_LOCALE

    def self.locale : String
      @@locale
    end

    # 起動時に一度だけ呼ぶ。
    # 画面は起動時に組み立てるため、動作中に切り替えても表示が追従しない。
    def self.locale=(locale : String) : String
      @@locale = LOCALES.has_key?(locale) ? locale : DEFAULT_LOCALE
    end

    # 設定の language の値から使うロケールを決める。
    # "auto" と想定外の値は OS の表示言語に従う。想定外の値は検証が弾くため、
    # ここへ来るのは検証を通らない経路（読めなかった設定の既定値など）に限られる。
    def self.resolve(setting : String) : String
      LOCALES.has_key?(setting) ? setting : system_locale
    end

    def self.system_locale : String
      {% if flag?(:windows) %}
        primary = LibWin32.get_user_default_ui_language & 0x3FF_u16
        primary == LANG_JAPANESE ? "ja" : "en"
      {% else %}
        # Windows 以外で動くのは spec と型検査だけである。結果を環境に依らせない。
        DEFAULT_LOCALE
      {% end %}
    end

    def self.t(key : String) : String
      LOCALES[@@locale][key]? || LOCALES[DEFAULT_LOCALE][key]? || key
    end

    # ログへ出すための文字列。選択言語に依らず既定の言語で引く。
    # ログは開発者が読むものであり、実行環境ごとに言語が変わると読み比べられない。
    def self.log_text(key : String) : String
      LOCALES[DEFAULT_LOCALE][key]? || key
    end

    # プレースホルダ（{status} など）を値で置き換える。
    # 1 回の走査で置き換えるのは、値に含まれる { } を再解釈しないためである。
    def self.t(key : String, vars : Hash(String, String)) : String
      t(key).gsub(PLACEHOLDER) do |match, m|
        vars[m[1]]? || match
      end
    end
  end
end
