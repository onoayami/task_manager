# TaskTimer

macOS のメニューバーで動く、タスクごとの作業時間計測アプリです（SwiftUI・単一ファイル）。

## 主な機能

- タスクごとの計測の開始・一時停止・再開・停止（複数タスクの同時計測に対応）
- スリープ・画面ロック時の自動一時停止
- 今日の時間の手動編集・リセット、タスクの名前変更・削除（一括操作あり）
- タスクごとの「今日のメモ」
- 日付の切り替え時刻の設定（例：4:00 にすると深夜 3 時の作業は前日扱い）
- 日別の記録を CSV / Markdown で書き出し

## 動作環境

- macOS 13 以降
- Swift コンパイラ（Command Line Tools for Xcode）

## インストール

`インストール.command` をダブルクリックしてください。
`TaskTimer.app` をビルドして「アプリケーション」フォルダに入れ、起動します。
Command Line Tools が無い場合は、インストールのダイアログが表示されます。

手動でビルドする場合:

```bash
swiftc -O -parse-as-library TaskTimer.swift -o TaskTimer
```
