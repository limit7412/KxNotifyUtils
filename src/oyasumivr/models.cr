require "json"

# OyasumiVR 連携（issue #54）。
#
# OyasumiVR は内蔵の OSCQuery サーバで睡眠モードの状態を公開している。
# ここでは、その状態を読んで睡眠中かを sleep コンテキストへ渡す。
# OyasumiVR の状態を書き換えることはしない。
module OyasumiVR
  # HOST_INFO の応答。
  # 見つけたサーバが OyasumiVR のものかを名前で確かめるためだけに読む。
  struct HostInfo
    include JSON::Serializable

    @[JSON::Field(key: "NAME")]
    getter name : String = ""
  end

  # OSCQuery のノード 1 つ分の応答。
  #
  # 型を示す TYPE は読まない。OyasumiVR は Bool を独自に "F" と書いており、
  # OSCQuery の型表記として読むと Float と取り違える。
  struct Node
    include JSON::Serializable

    @[JSON::Field(key: "VALUE")]
    getter value : Array(JSON::Any) = [] of JSON::Any
  end

  # 設定ウィンドウに出す連携の状態。
  enum Status
    # 連携を使っていない。
    Disabled
    # OyasumiVR のサーバを見つけていない。
    NotFound
    # 見つけていて、睡眠モードは切れている。
    Connected
    # 見つけていて、睡眠モードに入っている。
    Asleep
  end
end
