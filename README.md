# RevOmate

Bit Trade One の左手デバイス **Rev-O-mate (BFROM11BK)** を macOS ネイティブ
（Swift + IOKit）で設定するためのツール群。公式 OSS
（[`bit-trade-one/BFROM11BK_Rev-O-mate`](https://github.com/bit-trade-one/BFROM11BK_Rev-O-mate)）
から抽出した HID プロトコルを土台にした再実装。

> 標準の C#/Windows 設定ツールの置き換えを目的とした macOS 版。
> 最小対応 **macOS 26 (Tahoe) / Apple Silicon**。デバイスは標準 USB-HID なので特権・kext 不要。

## 構成

| ターゲット | 役割 |
|---|---|
| `RevOmateKit` | コア: HID トランスポート・ワイヤプロトコル・フラッシュモデル |
| `revomate` (CLI) | 疎通スパイク: `version` / `probe` / `dump` |
| `RevOmateApp` | SwiftUI アプリ雛形（接続・version 表示・フラッシュバックアップ） |

## プロトコル要点

- 設定通信は **Vendor HID インターフェイス**（VID `0x22EA` / PID `0x004B` / UsagePage `0xFF00` / Usage `0x01`）。
- 64B OUT → 64B IN の同期リクエスト/レスポンス、**Report ID なし**。
- 主要コマンド: `0x11` flash read(≤62B) / `0x12` write(≤58B) / `0x13` 64KiB sector erase / `0x56` version。
- 外部 SPI フラッシュ **M25P16 (2 MiB)** に全設定を保存。アドレスは BE、フラッシュ内スカラは LE。
- 詳細は Life リポジトリ `03.Projects/revomate/protocol-spec.md`。

## 使い方（CLI スパイク）

実機を接続して:

```sh
swift run revomate version        # ファームウェアバージョン
swift run revomate probe          # base/script ヘッダと先頭スクリプトを表示
swift run revomate dump backup.bin  # フラッシュ全 2 MiB をバックアップ
```

> 初回に macOS の入力監視/USB アクセス許可を求められた場合は許可すること
> （`swift run` からの実行では実行元ターミナルに紐づく）。

## アプリ雛形

```sh
swift run RevOmateApp
```

Connect でデバイスを開いて FW バージョンとスクリプト数を表示、Dump… で
フラッシュをバックアップ。UI（ダイヤル/ボタン割り当て・LED・マクロ編集）は今後。

## ステータス

- [x] M0 疎通（vendor IF open + `0x56`）
- [x] M1 フラッシュ全ダンプ（バックアップ）
- [ ] M2 各設定領域のパーサ（Base / Function / Encoder / SW / Script）
- [ ] M3 書き込みパス（sector erase → write → 読み戻し検証）
- [ ] M4 設定 UI
- [ ] M5 マクロ（スクリプト）エディタ
