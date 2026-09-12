# 開発・検証ノート

[English](DEVELOPMENT.md) | 日本語

Xcode 26 以降、Swift 6.2 以降を使用する。アプリの対応 OS は iOS 17 以降で、iPhone / iPad 両方に対応。SSHCore と TerminalCore は macOS 14 以降でも単体テストできる。

```sh
brew install xcodegen
make bootstrap
open iOSSH.xcodeproj
```

Metal コンパイラがないと表示されたら `xcodebuild -downloadComponent MetalToolchain` で追加する。iOSSH スキームとシミュレータを選択する。実機の場合は Signing & Capabilities で開発チームを設定する。Xcode が SwiftTerm のビルドプラグインの承認を求めることがある。固定したバージョンのプラグインは Git のバージョン情報をソースに生成するもので、CLI ビルドでは `-skipPackagePluginValidation` を指定して無人実行に対応している。

生成済み Xcode プロジェクトはコミットする。XcodeGen は再生成時のみ必要。`project.yml` を編集してから `xcodegen generate` を実行し、依存関係を変更した場合は `Package.resolved` もコミットする。SwiftTerm バックエンドでは Zig や XCFramework のダウンロードは不要。

```sh
make build                         # 署名なしのシミュレータ向けビルド
make test                          # SSHCore / TerminalCore 単体テスト
make test-ui SIMULATOR='iPhone 17'  # インストール済みの端末名を指定
```

GitHub Actions はパッケージ単体テスト、シミュレータ向けビルド、アプリ・UI テストを実行する。アプリ単体テストは接続キャンセル、認証中のリサイズ、接続直後の切断、入力失敗、ホスト鍵承認を確認する。UI テストはホストの追加・編集・削除、入力検証、設定、ターミナルの起動と認証キャンセルを確認する。起動引数 `--ui-testing` はテスト用で、ホスト情報をメモリ内に保存する。

## 実機向け Debug ビルド

Xcode の Settings > Accounts で Apple Account にサインインする。iPhone / iPad を Mac に接続してロックを解除し、ペアリングの確認が表示されたら承認する。Xcode から求められた場合は、端末の [デベロッパモード](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)を有効にする。

```sh
xcrun devicectl list devices
make device-build TEAM_ID=YOUR_TEAM_ID DEVICE_ID=YOUR_DEVICE_UDID
make device-run DEVICE_ID=YOUR_DEVICE_UDID
```

`DEVICE_ID` には Xcode の Devices and Simulators に表示される端末の UDID を指定する。インストール・起動時の `devicectl` は独自の device identifier も受け付ける。個人チームでも実機への開発用インストールが可能。上記コマンドは自動プロビジョニングで署名済みの **Debug** ビルドを作成し、実機へインストールして起動する。必要に応じて選択した端末をチームへ登録する。チーム ID はビルド時に渡すため、共有プロジェクトには保存しない。アプリの生成先は `build/DeviceDerivedData/Build/Products/Debug-iphoneos/iOSSH.app`。

ビルド済みアプリのインストールだけなら `make device-install DEVICE_ID=YOUR_DEVICE_UDID` を実行する。一時的に端末へ接続できない場合は `device-build` の `DEVICE_ID` を省略して汎用 iOS 向けにビルドできるが、インストールには対象端末を含む署名プロファイルが必要。[無料の個人チームのプロファイルは 7 日で期限切れになる](https://developer.apple.com/support/compare-memberships/)ため、その後は再ビルド・再インストールする。ブレークポイントや対話的なログ確認には、Xcode で同じチームと実機を選択し、iOSSH スキームを Debug 構成で実行する。

実機では管理下のサーバーを登録し、ホスト鍵フィンガープリントを照合してシェルを開く。日本語の変換・確定、画面回転、コピー・ペースト、保存済み資格情報の生体認証、画面ロック後の同じシェルへの復帰を確認する。ローカルネットワークへの接続時は iOS のネットワーク利用許可が表示される場合がある。

インストールに成功しても開発者が未信頼で起動できない場合は、端末の「設定 → 一般 → VPN とデバイス管理」で、このビルドの署名に使用した Apple Account の開発者証明書を信頼する。確認や再起動の案内が表示されたら従う。Apple のサンプルにも[個人チームでの設定手順](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)がある。

## 接続

ホスト名 / IP、ポート、ユーザー名、認証方法を登録する。パスワード・鍵認証で資格情報を空にして保存すると、接続時に入力を求める。接続画面で入力した資格情報は、**Save in Keychain** を有効にしない限りその接続だけに使用する。

**Tailscale SSH** では、先に iOS の Tailscale アプリを接続する。接続先の MagicDNS 端末名（または完全な `.ts.net` 名 / Tailscale IP）、ポート 22、サーバー上のユーザー名を入力し、Authentication で **Tailscale SSH** を選ぶ。サーバー側で Tailscale SSH が有効で、tailnet の SSH ポリシーが接続を許可している必要がある。この方式は SSH の `none` 認証を使用し、資格情報の読み込み・保存・入力を行わない。既存ホストの認証方法は保持するため、切り替える場合はホストを編集する。名前解決は OS のリゾルバと接続済みの Tailscale アプリを利用する。[Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh)・[MagicDNS](https://tailscale.com/docs/features/magicdns) を参照。

check mode の承認メッセージは接続中に表示する。Tailscale の HTTPS サインインボタンをタップし、アプリ内の Safari 画面で承認する。この方式では SSH 認証を最大 5 分待機する。リンクを自動で開くことはなく、初回・変更時のホスト鍵検証も行う。バックグラウンドでも認証待ちの接続を保持するが、承認中に通信が切れたり認証期限を過ぎたりした場合は、承認後に再接続する。

秘密情報は `WhenPasscodeSetThisDeviceOnly` と `biometryCurrentSet` を指定した Keychain に保存し、SwiftData や UserDefaults には書き込まない。保存する前に端末のパスコードと Face ID / Touch ID を設定する。生体認証が利用できない場合も保護を弱めず、接続ごとの入力を利用する。登録済みの生体情報を変更すると、保存済みの資格情報が使えなくなる場合がある。

対応する鍵形式:

- OpenSSH 形式の Ed25519 秘密鍵。非暗号化、または Citadel 対応の暗号化（AES-128/256-CTR、bcrypt rounds は 32 未満）。
- 暗号化されていない ECDSA P-256 / P-384 / P-521 の PEM 秘密鍵。
- 現在の依存ライブラリの RSA 実装は古い `ssh-rsa` を使用するため、RSA は未対応。keyboard-interactive も依存ライブラリに実装がない。

初回接続では SHA-256 のホスト鍵フィンガープリントを表示する。信頼できる経路で照合してから承認する。承認済みの鍵は Application Support に保存し、変更を検出した場合は接続を拒否する。ホスト一覧から削除しても信頼済み鍵は残す。アプリ内のホスト鍵リセット機能は未実装。

画面ロック・バックグラウンド移行時は SSH 接続、端末バッファ、カーソルを保持する。復帰時は既存接続を確認して現在の端末サイズを反映し、再認証や別のシェルの起動は行わない。明示的な Close / Disconnect は引き続き接続を閉じる。接続先が閉じた、または応答しなくなった場合は Reconnect を案内する。再接続ではホスト鍵を再検証し、新しい認証済みシェルを開くため、終了したシェルの復元はできない。iOS はアプリをサスペンドすることがあり、セッションを保持してもバックグラウンドでの無期限な通信は保証できない。[Apple のバックグラウンド実行ガイド](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)を参照。

## ターミナル

ターミナルをタップしてキーボードを表示する。補助行には Ctrl / Esc / Tab / 矢印 / パイプ / チルダを用意。外付けキーボードの修飾キー、アプリケーションカーソルモード、bracketed paste に対応する。上下スワイプで履歴を移動し、長押ししてドラッグすると選択できる。編集メニューまたは Command-C / Command-V でコピー・ペーストする。設定からフォントサイズとダーク / ライトの配色を変更できる。

標準フォントとして **HackGen Console NF** を同梱し、日本語と Starship 用の Nerd Font 記号に対応する。半角と全角の送り幅は 1:2。幅の広い記号もパーサが指定するセル数に収め、Powerline の区切りはセルの端まで描画する。設定では選択中のフォントのプレビューと同梱フォントのライセンスを確認できる。サーバー側のプロンプトの文字幅設定も、端末の Unicode 幅と一致させる必要がある。

設定から「ファイル」にある等幅 `.ttf` / `.otf` フォントを追加できる。iOSSH の Application Support にコピーしてこのアプリ内で登録し、OS 全体にはインストールしない。選択は次回起動時も復元し、選択中の追加フォントを削除すると標準フォントへ戻る。

日本語入力には端末カーソル位置の UIKit 入力欄を使う。変換中の文字と候補の編集は確定まで端末内に保持し、変換中の削除・キャンセルで送信済みのサーバーの文字を消さない。

最終行は不透明な補助キー行の上に配置する。キーボードの変化・アプリ復帰・再接続時には、その時点のキーボードと補助キー行の位置から表示領域を再計算し、行数・列数を PTY へ送る。

ターミナルの protocol によりビューを SwiftTerm から分離する。パーサの状態は `MainActor` に隔離し、不変のスナップショットでセル、damage、カーソル、画像をレンダラに渡す。スナップショットの通知をまとめ、Metal は上限付きグリフアトラスとトリプルバッファを使用し、各バッファの変更行を更新する。非アクティブ時は描画を停止する。

Kitty 画像は direct base64 の RGB / RGBA / PNG に対応し、転送量・画像・配置数に上限を設ける。未対応コマンドにはプロトコル上のエラーを返す。リサイズ時は通常の画像配置を破棄するため、接続先アプリによる再描画が必要。Unicode placeholder の配置はテキストに追従して reflow 後も保持する。別の値が接続先の要求に合うことを検証するまでは `TERM=xterm-256color` を使う。

`swift Packages/TerminalRender/Scripts/validate-metal.swift` はシェーダーパイプラインをコンパイルして GPU で描画し、線形空間のアルファ合成を検証する。

## 実 SSH 結合テスト

管理下の SSH サーバーを使う任意の SSHCore テスト:

```sh
IOSSH_TEST_SSH_HOST=127.0.0.1 \
IOSSH_TEST_SSH_PORT=22222 \
IOSSH_TEST_SSH_USER="$USER" \
IOSSH_TEST_SSH_KEY_PATH=/absolute/path/to/test_ed25519 \
swift test --package-path Packages/SSHCore --filter SSHIntegrationTests
```

テスト専用の鍵・アカウントを使う。PTY 出力、リモートの `stty` によるサイズ確認、切断、ホスト鍵を再承認しない再接続を検証する。アプリの信頼済みホストや資格情報ストアは変更しない。環境変数がない場合、このテストはスキップする。

## ローカルで確認済みの項目

2026-09-12、Xcode 26.5 / Swift 6.3.2 で検証:

- iPhone / iPad 対象の iOS Simulator 向けアプリビルドが成功。
- 個人チーム署名の Debug ビルドを署名検証し、iPhone 17e / iOS 26.6.1 にインストール。開発者証明書の信頼後に起動を確認。初期ビルドで Tailscale SSH サーバーに接続できることはユーザーが確認済み。
- バージョン 0.1.0 build 3 は、署名・個人チームのプロファイル・同梱 HackGen Regular / Bold のチェックサムを検証し、同じ iPhone に Wi-Fi 経由で更新済み。起動確認は実機の画面ロックで停止。ユーザーの Starship テーマ、日本語入力、画面ロックからのセッション復帰、Tailscale check mode は、この更新で実機確認が引き続き必要。
- SSHCore: Tailscale 認証・上限付き認証バナー・既存接続の確認（相手の応答、拒否、タイムアウト、待機キャンセル）を含む単体・プロトコルテスト 24 件が成功。任意の実 OpenSSH 結合テストは初期検証で成功し、今回の更新ではスキップ。
- TerminalCore: 18 テスト / パラメータ化を含む 19 ケースが成功。
- アプリ・描画: iPhone 17 / iOS 26.5 Simulator で 48 テストが成功。既存接続の保持、Tailscale サインイン、HackGen の収録・ラスタライズ、フォントの取り込み・削除・再取り込み、日本語変換、キーボードの表示領域を確認。
- UI: iPhone 17 の全体実行と対象を絞った再実行で計 5 テストが成功。キーボード表示、アプリ復帰、再接続、画面回転、実際のかなキーボードによる候補選択・確定を確認。未確定文字と候補バーのスクリーンショットも確認。初期検証では iPad Pro 11-inch (M5) / iOS 26.5 Simulator のターミナル起動・認証キャンセルも成功。
- Metal の GPU 描画・ブレンド検証スクリプトが成功。ターミナルと iPad 初回起動画面のスクリーンショットも確認済み。

## 残る受け入れ検証

- 実機での Keychain 生体認証、外付けキーボード、バックグラウンド動作、多言語入力。
- 実サーバーに接続した `vttest` / `esctest`、Neovim / Helix の画像プラグイン互換性。
- Instruments による 120Hz、大量出力、メモリ圧、アイドル時の消費電力の計測。
- Display P3 出力、メイン actor 外へのパーサ隔離、将来の libghostty-vt バックエンド。
- keyboard-interactive、対応する鍵形式の拡充、reflow 前後の画像配置の保持。
