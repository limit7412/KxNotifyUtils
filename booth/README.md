# BOOTH 用トップ画像

BOOTH の商品ページに載せるトップ画像の候補を置く。
一覧ではサムネイルが正方形に切り抜かれるため、どの候補も 1:1 で作ってある。

| 候補 | 方向性 |
| --- | --- |
| `out/thumbnail-a.png` | 暗い背景に見出しと通知カードを重ね、何が起きるかを一目で見せる |
| `out/thumbnail-b.png` | 明るい背景でアプリアイコンを主役にし、一覧で目を引く |
| `out/thumbnail-c.png` | VR 空間を背景に商品名を大きく置き、その下に通知を 1 つだけ見せる |
| `out/thumbnail-d.png` | 大きな文字と機能の箇条書きで説明する |
| `out/thumbnail-e.png` | VR 内の場面に縁取りの見出しと機能を重ねる。VRChat 向けアプリのスキ数上位に最も多い構成 |
| `out/thumbnail-f.png` | 「HMD を外すのがめんどくさい」という困りごとを大きく書き、その答えとして通知を見せる |

配色は `tools/generate_icon.py` のアイコンに合わせた。
通知カードは XSOverlay の通知ポップアップ（左上の丸いアイコン、中央寄せのタイトル、区切り線、本文）を模したもので、実際の画面を撮ったものではない。
A、C、E、F には「無料」の表記があるので、有料で出す場合は `thumbnail.html` から消す。

E は `assets/scene.jpg` に VR 内のスクリーンショットを置くと、それを背景に敷く。
置かないときは描画した部屋を背景に使う。

## 書き出し

`thumbnail.html` が原稿で、`render.mjs` が各候補を 1600x1600 の PNG に書き出す。

```sh
cd booth
npm install
npm run render
```

Playwright が同梱のブラウザを見つけられない環境では、`CHROMIUM_PATH` に Chromium の実行ファイルを渡す。
