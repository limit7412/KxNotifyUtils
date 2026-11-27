require "../spec_helper"

# 固定動画の oEmbed の実応答（2026-09-03、ブラウザから取得）。
# 読むのは title だけだが、本文は実物のまま置く。
# html の項目に引用符のエスケープが入るので、ヒアドキュメントではなくファイルに持つ。
private def oembed_json : String
  File.read(File.join(__DIR__, "fixtures", "oembed.json"))
end

describe Youtube::OEmbed do
  it "実応答から題を読む" do
    Youtube::OEmbed.from_json(oembed_json).title.should eq "5070Ti 動作チェック UMA New World (PC/google play) "
  end

  it "題が無ければ読めない" do
    expect_raises(JSON::SerializableError) do
      Youtube::OEmbed.from_json(%({"type": "video"}))
    end
  end
end
