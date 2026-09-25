# BOOTH 用トップ画像

BOOTH の商品ページに載せるトップ画像の候補を置く。
一覧ではサムネイルが正方形に切り抜かれるため、どの候補も 1:1 で作ってある。

| 候補 | 方向性 |
| --- | --- |
| `out/thumbnail-a.png` | 暗い背景に見出しと通知カードを重ね、何が起きるかを一目で見せる |
| `out/thumbnail-b.png` | 明るい背景でアプリアイコンを主役にし、一覧で目を引く |
| `out/thumbnail-c.png` | VR 空間に通知が浮かぶ様子を描き、使っているときの見え方を伝える |
| `out/thumbnail-d.png` | 大きな文字と機能の箇条書きで説明する |

配色は `tools/generate_icon.py` のアイコンに合わせた。
通知カードは XSOverlay の通知ポップアップを模したもので、実際の画面を撮ったものではない。
A と C には「無料」の表記があるので、有料で出す場合は `thumbnail.html` から消す。

## 書き出し

`thumbnail.html` が原稿で、`render.mjs` が各候補を 1600x1600 の PNG に書き出す。

```sh
cd booth
npm install
npm run render
```

Playwright が同梱のブラウザを見つけられない環境では、`CHROMIUM_PATH` に Chromium の実行ファイルを渡す。
