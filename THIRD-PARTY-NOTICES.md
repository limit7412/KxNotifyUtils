# THIRD-PARTY NOTICES

KxNotifyUtils は次のソフトウェアを静的リンクまたはコード同梱の形で利用している。
各ライセンスの全文は、それぞれのリポジトリに収録されているものを参照する。

配布物は KxNotifyUtils.exe の 1 ファイルであり、同梱の LICENSE ファイルを持たない。
そのため、この表記は実行ファイルへ埋め込み、設定ウィンドウの情報タブから全文を読めるようにしている。

## Crystal

- ライセンス: Apache License 2.0
- https://github.com/crystal-lang/crystal

Crystal のランタイムと標準ライブラリを含む。
Crystal 自体が同梱する Boehm GC（MIT 系のライセンス）と PCRE2（BSD ライセンス）を併せて含む。

## libui-ng

- ライセンス: MIT License
- https://github.com/libui-ng/libui-ng

設定編集ウィンドウの描画に用いる。静的ライブラリとしてリンクする。

## uing

- ライセンス: MIT License
- https://github.com/kojix2/uing

libui-ng の Crystal バインディング。

## OpenVR SDK

- ライセンス: BSD 3-Clause License
- https://github.com/ValveSoftware/openvr

openvr_api.dll 自体は同梱しない。
SteamVR がインストールしたものを実行時にロードして呼び出す。
本ツールは OpenVR のヘッダに記述された関数テーブルの構造と定数を写したコードを含むため、
その部分について BSD 3-Clause License の表記を掲げる。

## C++/WinRT

- ライセンス: MIT License
- https://github.com/microsoft/cppwinrt

NotifListenerShim（Windows 通知を取得する静的ライブラリ）のビルドに用いる。

## KxNotifyUtils

- ライセンス: MIT License
- https://github.com/limit7412/KxNotifyUtils
