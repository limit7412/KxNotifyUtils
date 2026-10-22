require "../spec_helper"
require "../../src/runtime/tray"

# ツールチップは NIM_SETVERSION を呼んでいないため、
# シェルが読むのは終端の NUL を含めて 64 文字までである可能性がある。
describe Runtime::Tray do
  after_each { Runtime::I18n.locale = Runtime::I18n::DEFAULT_LOCALE }

  it "どの言語と状態の組み合わせでもツールチップが 63 文字に収まる" do
    too_long = [] of String
    Runtime::I18n::LOCALES.each_key do |locale|
      Runtime::I18n.locale = locale
      [true, false].each do |steamvr|
        Sleep::Reason.each do |reason|
          text = Runtime::Tray.tooltip_text(steamvr, reason)
          too_long << "#{locale} #{steamvr} #{reason}: #{text.size}" if text.size > 63
        end
      end
    end

    too_long.should be_empty
  end

  # 辞書に無いキーはキー名のまま返る。理由を足して文言を書き忘れると、キー名がそのまま出る。
  it "どの言語と状態の組み合わせでも辞書の文言で出す" do
    Runtime::I18n::LOCALES.each_key do |locale|
      Runtime::I18n.locale = locale
      Sleep::Reason.each do |reason|
        Runtime::Tray.tooltip_text(true, reason).should_not contain "tray.tip."
      end
    end
  end

  it "睡眠中の行は止めている間だけ出す" do
    Runtime::Tray.tooltip_text(true, Sleep::Reason::None).lines.size.should eq 2
    Runtime::Tray.tooltip_text(true, Sleep::Reason::Schedule).lines.size.should eq 3
  end
end
