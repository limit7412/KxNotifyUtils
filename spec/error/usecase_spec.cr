require "../spec_helper"
require "../../src/error/usecase"

# 例外の文脈はログと利用者向けの通知の両方へ出る（issue #4）。
# 言語の決め方が違うため、同じキーから別々に引けることをここで守る。
describe Error::Usecase do
  it "通知のタイトルは表示用の解決を通す" do
    titles = [] of String
    usecase = Error::Usecase.new
    usecase.notifier = ->(title : String, _body : String) { titles << title; true }
    usecase.display_text = ->(key : String) { "表示: #{key}" }

    usecase.guard("error.relay") { raise "壊れた" }

    titles.should eq ["表示: error.relay"]
  end

  it "解決を差し込む前はキーをそのまま渡す" do
    titles = [] of String
    usecase = Error::Usecase.new
    usecase.notifier = ->(title : String, _body : String) { titles << title; true }

    usecase.guard("error.relay") { raise "壊れた" }

    titles.should eq ["error.relay"]
  end

  it "例外のメッセージを本文にする" do
    bodies = [] of String
    usecase = Error::Usecase.new
    usecase.notifier = ->(_title : String, body : String) { bodies << body; true }

    usecase.guard("error.relay") { raise "壊れた" }

    bodies.should eq ["壊れた"]
  end

  it "例外を握りつぶして後続を止めない" do
    reached = false
    usecase = Error::Usecase.new

    usecase.guard("error.relay") { raise "壊れた" }
    reached = true

    reached.should be_true
  end

  # 通知を出せないこと自体で落とすと、常駐そのものが止まる。
  it "通知に失敗しても例外を投げず、出せなかったことを返す" do
    usecase = Error::Usecase.new
    usecase.notifier = ->(_title : String, _body : String) { raise "トレイが無い" }

    usecase.notify("題", "本文").should be_false
  end

  # 出たことにして先へ進む呼び出し側があるため、出せたかどうかを返す（issue #10）。
  it "出せたときは真を返す" do
    usecase = Error::Usecase.new
    usecase.notifier = ->(_title : String, _body : String) { true }

    usecase.notify("題", "本文").should be_true
  end

  it "フックを差し込む前は出せなかったものとして扱う" do
    Error::Usecase.new.notify("題", "本文").should be_false
  end
end
