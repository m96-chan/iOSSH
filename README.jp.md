# iOSSH

[English](README.md) | 日本語

> 余計な機能を足さない、iOS 向け SSH クライアント。

ターミナルとして正しく動くこと、速いこと、それ以外を持ち込まないこと。
Kitty Graphics Protocol による画像表示と、Metal による GPU レンダリングを前提に設計する。

> **Status: 設計フェーズ（実装未着手）**
> このドキュメントは実装前の設計合意文書を兼ねている。

<!-- TODO: スクリーンショット（iPhone / iPad） -->

---

## 1. 設計方針

| 柱 | 意味 |
| --- | --- |
| **Simple** | 機能を足さないことを設計判断の第一基準にする。「あると便利」は入れない |
| **Correct** | VT / Unicode / Kitty の挙動がデスクトップの端末と一致すること。幅計算・reflow・色で嘘をつかない |
| **Fast** | GPU レンダリングで ProMotion 120Hz を維持し、入力から描画までのレイテンシを最小にする |

対象は **iPhone / iPad 両方**、**iOS 17+**（Metal 3・Swift 6 strict concurrency を前提にするため）。

---

## 2. スコープ

### v1 でやること

- ホスト一覧の登録・編集
- 認証: パスワード / 公開鍵 / keyboard-interactive
- 資格情報を Keychain に保存、Face ID / Touch ID で保護
- ホスト鍵検証（TOFU + `known_hosts` 相当の永続化、変更時は警告）
- **シェルセッション 1 本**（PTY、ウィンドウサイズ追従）
- **24bit True Color / 256 色 / ANSI 16 色**
- **Kitty Graphics Protocol による画像表示**
- ハードウェアキーボード対応（iPad / Magic Keyboard）
- ソフトウェアキーボード上の補助キーバー（Ctrl / Esc / Tab / 矢印 / `|` / `~`）
- コピー & ペースト、テキスト選択
- フォントサイズ・カラーテーマ設定
- 切断検知と再接続

### v1 でやらないこと（意図的に落とす）

| 機能 | 落とす理由 |
| --- | --- |
| SFTP / ファイル転送 | 別アプリの領分。UI が一気に膨らむ |
| ポートフォワーディング | 常時接続が前提の機能で、iOS のバックグラウンド制限と相性が悪い |
| mosh | サーバ側に別バイナリを要求する。再接続 UX で代替する |
| tmux control mode | ネイティブ UI との統合は v1 の複雑度を超える |
| タブ / ペイン分割 | 「1 画面 1 セッション」を維持する。画面が狭い iPhone で特に有害 |
| エージェントフォワーディング | セキュリティ上の判断が必要で、v1 の検証範囲に収まらない |
| Sixel / iTerm2 画像プロトコル | 画像プロトコルは Kitty に一本化する |
| iCloud 同期 | 秘密鍵の同期は設計を慎重にやる必要があり、v1 では持たない |

これらは「将来やらない」ではなく「v1 に入れない」。追加するときは、この表から 1 行削るという意思決定を経る。

---

## 3. アーキテクチャ

```
        SwiftUI  (ホスト一覧 / 設定 / 接続フロー)
             │
      UIViewRepresentable
             ▼
   TerminalView (MTKView) ──► MetalRenderer ──┬──► GlyphAtlas  (MTLTexture)
             ▲                                └──► ImageStore  (Kitty graphics)
             │  grid snapshot + damage
             │
      TerminalEngine  (VT パース / グリッド / scrollback / Kitty 状態)
             ▲
             │  bytes
      SSHSession  (PTY channel, keepalive, 再接続)
             ▲
      Citadel / swift-nio-ssh
```

**`TerminalEngine` は protocol として定義する。** 実装（libghostty-vt バインディング）を差し替え可能にしておく。理由は [11. リスク](#11-既知のリスク--未決事項) を参照。

---

## 4. 技術選定

各レイヤについて「採用したもの」と「採用しなかったもの」を記録する。

| レイヤ | 採用 | 理由 | 却下した選択肢 |
| --- | --- | --- | --- |
| SSH | **[Citadel](https://github.com/orlandos-nl/Citadel)**（[apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh) の高レベルラッパ） | Pure Swift、SPM のみで完結、iOS を公式サポート。C ツールチェインのビルド管理が不要 | **libssh2 ラッパ（[SwiftSH](https://github.com/Frugghi/SwiftSH)）**: C 依存とクロスビルド管理のコスト。**NMSSH**: メンテナンス停滞。**swift-nio-ssh 直接**: クライアント実装を自前で組む必要があり、Citadel がやっていることを再発明する |
| VT エンジン | **[libghostty-vt](https://mitchellh.com/writing/libghostty-is-coming)**（Ghostty から切り出された C API） | **Kitty Graphics Protocol をエンジン側で実装済み**。SIMD パース、Unicode 幅計算、reflow、scrollback が実戦で枯れている。ゼロ依存（libc すら不要）で組み込みやすい | **自前 VT パーサ**: 工数が過大で、正しさの担保が最も難しい部分を自分で背負うことになる |
| VT エンジン（退避先） | **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** の `Terminal`（UI 非依存部分のみ） | libghostty-vt の API が未安定なため、protocol 越しに切り替えられる退避先を用意する。ただし Kitty Graphics は自前実装が必要になる | — |
| 描画 | **自前 Metal レンダラ**（`MTKView` + インスタンス描画） | CoreText 系は行ごとに `NSAttributedString` を再構築して描くため、セル数が多い・更新が速い状況で CPU バウンドになる。Kitty 画像もテキストと同じパイプラインでテクスチャ合成でき、z-index を素直に扱える | **CoreText 直描画**: 上記の通り CPU バウンド。**CALayer 合成**: セル単位のレイヤは数が多すぎる |
| グリフ | **CoreText で動的ラスタライズ → アトラステクスチャにキャッシュ** | 端末はセルサイズ固定で使用フォントサイズも少数。ヒント付きラスタの方が字が鮮明 | **MSDF**: スケールフリーという利点が端末では活きず、小さいサイズで品質が落ちる。アトラス生成の前処理も増える |
| UI | **SwiftUI（シェル）+ UIKit（ターミナル・キー入力）** | `MTKView` とキーイベント（`pressesBegan` / `UIKeyCommand` / `UIKeyInput`）は UIKit 側で扱うのが確実 | **全 SwiftUI**: 修飾キーや押下/離鍵の扱いで取りこぼしが出る |
| 永続化 | **Keychain（資格情報・秘密鍵）+ SwiftData（ホスト設定）** | 秘密情報と設定を物理的に分離する | 単一ストアにまとめる案 |
| 並行処理 | **Swift 6 strict concurrency**、エンジンは actor に隔離 | SSH 受信・VT パース・描画のスレッド境界を型で固定する | — |

---

## 5. GPU レンダリング設計

「GPU を使いたい」に対する具体的な方針。

### 描画トリガ

`MTKView.enableSetNeedsDisplay = true` の **damage 駆動**。毎フレーム回す方式は取らない。
アイドル時に GPU を焼かないことが、モバイルでは品質要件そのものになる。

### パス構成

1. **背景セル** — セル矩形をインスタンス描画（背景色のみ）
2. **グリフ** — アトラスの UV を参照してテキストを描く
3. **装飾** — 下線 / 二重下線 / 波線 / 取り消し線 / 罫線
4. **画像** — Kitty graphics のテクスチャを z-index 順に合成（テキストの前後どちらにも入りうる）
5. **カーソル** — ブロック / バー / アンダーライン、点滅

### バッファ戦略

- セルごとの instance buffer（cell index / atlas UV / fg・bg のパック色 / 属性ビット）
- `MTLBuffer` をトリプルバッファ化し、`DispatchSemaphore` で CPU と GPU の追い越しを制御
- エンジンの damage 情報を使い、**変更のあった行だけ** instance を書き換える

### 色

- 24bit True Color をそのまま扱う。256 色・ANSI 16 色はテーマのパレットから解決
- Display P3 / wide color に対応し、**ブレンドはリニア空間**で行う（アルファ合成の破綻を避ける）

### 電力・ライフサイクル

- バックグラウンド移行時に描画を停止する（バックグラウンドでの GPU 作業は許されない）
- ProMotion では `preferredFramesPerSecond` を上限に、実描画は damage 駆動のまま

---

## 6. Kitty Protocol 対応範囲

Kitty には目的の異なる仕様が複数ある。本プロジェクトでの扱いを明示する。

| 仕様 | 対応 | 範囲 |
| --- | --- | --- |
| **24bit True Color** | v1 必須 | `CSI 38;2;R;G;Bm` / `CSI 48;2;R;G;Bm`、256 色、ANSI 16 色。Kitty 固有ではないが「色が出る」のベースライン |
| **[Kitty Graphics Protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)** | v1 | 下記参照 |
| **[Kitty Keyboard Protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)** | v1.1 | `CSI > u` / `CSI < u` / `CSI = u` によるプログレッシブ拡張、フラグのスタック push/pop。iPad + 外付けキーボードで Neovim / Helix を使うときに効く |

### Graphics Protocol の詳細

| 項目 | v1 の対応 |
| --- | --- |
| 転送方式 | **direct（base64 チャンク）のみ** — iOS ではファイル経由 / 共有メモリ転送が現実的でない |
| フォーマット | RGB / RGBA / PNG |
| 配置 | セルアンカー配置、`z` によるテキストとの前後関係、カラム/ロウオフセット、スケーリング |
| 削除 | `d` による各種削除コマンド |
| Unicode placeholder | 対応（Neovim の image プラグイン等が使う） |
| アニメーション | **v1 対象外** |

### `TERM` の扱い

Kitty 固有機能を要求されるため、対応が揃った時点で `TERM=xterm-kitty` を名乗る。
ただし接続先に `xterm-kitty` の terminfo が無いケースがあるため、**ホストごとに `TERM` を上書きできる設定**を持つ（既定は `xterm-256color`、Kitty 機能を使いたいホストで切り替える）。

---

## 7. リポジトリ構成（これから作る形）

```
iOSSH/
├─ App/                   # SwiftUI エントリポイント、画面
├─ Packages/
│  ├─ SSHCore/            # Citadel ラッパ、認証、known_hosts、再接続
│  ├─ TerminalCore/       # TerminalEngine protocol + libghostty-vt バインディング
│  └─ TerminalRender/     # Metal レンダラ、GlyphAtlas、シェーダ
├─ Vendor/
│  └─ libghostty-vt.xcframework   # Zig でクロスビルドしたもの
├─ README.md              # 英語版
└─ README.jp.md           # 日本語版
```

アプリターゲットは薄く保ち、ロジックはローカル SPM パッケージに置く。
各パッケージは単体でテストできること（`TerminalCore` は UI なしでバイト列 → グリッドの検証が回ること）を構成の条件とする。

---

## 8. 開発環境

| 必要なもの | 用途 |
| --- | --- |
| Xcode 16+ / iOS 17 SDK | アプリ本体 |
| Swift 6 | strict concurrency |
| [Zig](https://ziglang.org/) | libghostty-vt を `aarch64-ios` / `aarch64-ios-simulator` 向けにクロスビルドし XCFramework を生成 |

```bash
git clone https://github.com/m96-chan/iOSSH.git
cd iOSSH
make bootstrap   # TODO: libghostty-vt のビルドと XCFramework 生成
open iOSSH.xcodeproj
```

---

## 9. 動作確認・受け入れ基準

「動いた」と言える条件を先に決めておく。

- **VT 互換性**: `vttest` の基本項目、`esctest` の主要スイートが通る
- **色**: `ls --color=always` / `htop` / `nvim` が実機と同じ色で出る。True Color のグラデーションに縞が出ない
- **Kitty 画像**: `kitten icat image.png`（または `timg -p kitty`）で画像が表示される / スクロールに追従する / 削除コマンドで消える / テキストとの前後関係が `z` の指定どおり
- **性能**: `yes` や大量ログの流し込み時にドロップフレームがない。実機で 120Hz を維持（Instruments の Metal System Trace で確認）
- **リサイズ**: 画面回転・キーボード表示でセル数が変わったとき、reflow が壊れない
- **接続**: 回線断 → 復帰で再接続でき、ホスト鍵の変更が検知される

---

## 10. セキュリティ方針

- 秘密鍵・パスワードは **Keychain** に保存し、生体認証をアクセス条件にする
- ホスト鍵は TOFU で記録し、**変更時はブロッキングな警告**を出す（黙って受け入れない）
- 秘密鍵をアプリ外（クラウド同期・バックアップ）に出さない
- Secure Enclave は P-256 のみ対応のため、`ecdsa-sha2-nistp256` 鍵であれば SE 保管が可能（v1.1 候補、要検証）

---

## 11. 既知のリスク / 未決事項

| リスク | 影響 | 対処 |
| --- | --- | --- |
| **libghostty-vt の API が未安定**（breaking change 前提で開発中） | エンジン層の書き直しが発生しうる | `TerminalEngine` protocol で隔離し、SwiftTerm エンジンへ退避できる状態を保つ。バージョンを固定して追従タイミングを自分で決める |
| **iOS のバックグラウンド実行制限** | サスペンドで SSH 接続が切れる | 常時接続を諦め、**再接続 UX** で吸収する（mosh を入れない判断とセット） |
| **Citadel の対応範囲が未検証** | PTY / window-change / ed25519・ECDSA 鍵 / keyboard-interactive が足りない可能性 | 実装着手前に PoC で確認する。不足分は swift-nio-ssh 層に降りて埋める |
| **Zig クロスビルドの CI 組み込み** | ビルド再現性 | XCFramework の生成を `make` で固定し、成果物をリリースに添付 |
| **Kitty Graphics のメモリ圧** | 大きな画像の連投でメモリ警告 | `ImageStore` に上限とエビクションを持たせる |

---

## 12. ロードマップ

- **v0.1** — 接続 / 認証 / PTY / CoreText 描画でとりあえず動く
- **v1.0** — Metal レンダラ、True Color、Kitty Graphics、鍵管理、再接続
- **v1.1** — Kitty Keyboard Protocol、Secure Enclave 鍵、テーマ追加

---

## 13. ライセンス

MIT（予定）

## 参照

- [Kitty: Terminal graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/)
- [Kitty: Keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/)
- [Libghostty Is Coming — Mitchell Hashimoto](https://mitchellh.com/writing/libghostty-is-coming)
- [ghostty-org/ghostling](https://github.com/ghostty-org/ghostling) — libghostty C API の最小実装例
- [apple/swift-nio-ssh](https://github.com/apple/swift-nio-ssh)
- [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel)
- [migueldeicaza/SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
