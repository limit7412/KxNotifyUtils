# AGENTS

## review

Always review in Japanese.

## document / comment

コメントやドキュメンテーションなど日本語の文章を書くときは下記を読む
  - .claude/skills/japanese-tech-writing
  - .claude/skills/cognitive-rhythm-writing

## github

- 機能実装時はデフォルトブランチへのPRを作成する
- ある程度の単位でcommit、pushしPRとissueが存在すれば更新する
- PRに付いた指摘が無いか都度確認してあれば必要な対応か検討して、必要なら修正する
  - 付いた指摘に対してはcommit idをつけて返答をしてresolveする
- PRのスコープ外の問題が発覚した場合は別途issueを作成する
- issueの解決を目的とした場合は修正中都度issueの本文を更新し必要に応じてコメントをつける

## deploy

status-server（集約サーバー）のデプロイについて

- dev環境へはgithub actionsを通して（他タスクと競合しない限り）自由にデプロイして構わない
- 必要であればdev環境へmaster以外のブランチの内容をデプロイしても構わない
- prod環境へは本体の正式版の公開で自動的にデプロイされる。それ以外で（手動実行などで）prod環境へデプロイするのは指示があったときだけにする
