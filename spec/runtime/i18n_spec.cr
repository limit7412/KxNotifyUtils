require "../spec_helper"
require "../../src/runtime/i18n"

# 辞書は ja を正とする（issue #4）。
# キーやプレースホルダの食い違いはコンパイルでは見つからないため、ここで機械的に守る。
describe Runtime::I18n do
  after_each { Runtime::I18n.locale = Runtime::I18n::DEFAULT_LOCALE }

  it "全ロケールでキーの集合が一致する" do
    ja_keys = Runtime::I18n::LOCALES["ja"].keys.sort!
    Runtime::I18n::LOCALES.each do |locale, table|
      table.keys.sort!.should eq(ja_keys), "ロケール #{locale} のキーが ja と食い違っている"
    end
  end

  # プレースホルダが翻訳で欠けると、値が埋まらないまま表示される。
  it "全ロケールでプレースホルダが一致する" do
    ja = Runtime::I18n::LOCALES["ja"]
    mismatched = [] of String
    Runtime::I18n::LOCALES.each do |locale, table|
      next if locale == "ja"
      table.each do |key, text|
        placeholders = text.scan(Runtime::I18n::PLACEHOLDER).map(&.[0]).sort!
        expected = ja[key].scan(Runtime::I18n::PLACEHOLDER).map(&.[0]).sort!
        mismatched << "#{locale}: #{key}" unless placeholders == expected
      end
    end
    mismatched.should be_empty
  end

  it "ロケールに応じた文字列を返す" do
    Runtime::I18n.t("settings.footer.save").should eq "保存"

    Runtime::I18n.locale = "en"
    Runtime::I18n.t("settings.footer.save").should eq "Save"
  end

  it "どのロケールにも無いキーはキー名のまま返す" do
    Runtime::I18n.t("no.such.key").should eq "no.such.key"
  end

  it "プレースホルダを値で置き換え、値の無いものは残す" do
    text = Runtime::I18n.t("settings.sources.access_status", {"status" => "OK"})
    text.should contain "OK"
    text.should_not contain "{status}"

    kept = Runtime::I18n.t("settings.sources.access_status", {} of String => String)
    kept.should contain "{status}"
  end

  it "知らないロケールを設定しようとしたら既定へ倒す" do
    Runtime::I18n.locale = "fr"
    Runtime::I18n.locale.should eq Runtime::I18n::DEFAULT_LOCALE
  end

  describe ".resolve" do
    it "明示された ja と en はそのまま使う" do
      Runtime::I18n.resolve("ja").should eq "ja"
      Runtime::I18n.resolve("en").should eq "en"
    end

    # Windows 以外では system_locale が既定値に固定される。
    # auto の実際の判定（OS の表示言語）は実機でしか確かめられない。
    it "auto と想定外の値は OS の表示言語に従う" do
      Runtime::I18n.resolve("auto").should eq Runtime::I18n.system_locale
      Runtime::I18n.resolve("fr").should eq Runtime::I18n.system_locale
    end
  end
end
