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

キーボードのリサイズ UI テストは、英語キーボードの初回 QuickPath 案内を閉じてから補助行を操作する。初期状態のシミュレータでは、この OS の案内がアクセシビリティ階層に残るボタンを覆うことがある。CI は `ios-test-results` 成果物を 7 日間保存する。`CI.xcresult` という名前のフォルダへ展開して Xcode で開くと、失敗の詳細とスクリーンショットを確認できる。

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

## Tailscale 端末の取り込み

1. iPhone / iPad に Tailscale と「ショートカット」をインストールし、Tailscale にサインインして接続する。
2. iOSSH のホスト一覧から **Import from Tailscale**（下向き矢印）を開き、**Set Up Shortcut → Save Shortcut File** を選ぶ。「ファイルに保存」した `.shortcut` ファイルを開き、「ショートカットを追加」を押す。名前は **Import Tailscale Hosts** のままにする。同じ[署名済みファイル](../shortcuts/Import%20Tailscale%20Hosts.shortcut)と[確認用ソース](../shortcuts/README.md)をリポジトリにも収録している。
3. iOSSH に戻って **Fetch Devices** を押す。初回は、Tailscale の結果を取得して iOSSH に渡す許可を求められたら承認する。
4. 表示された一覧で登録するサーバーを選び、SSH ユーザー名を入力する。**Add** で認証方式 **Tailscale SSH**、ポート **22** として登録する。初期状態は全件未選択で、登録だけでは接続を開始しない。

同梱ショートカットは公式の [Find Devices アクション](https://tailscale.com/docs/features/mac-ios-shortcuts)をフィルターなしで実行し、各端末の MagicDNS、IPv4、IPv6 の順に利用できるアドレスを選ぶ。手動で作る場合は **Tailscale → Find Devices**、**iOSSH → Review Tailscale Hosts** の順に追加し、**Hostnames** に Devices の **MagicDNS Address** プロパティを指定する（IPv4 / IPv6 でも可）。表示名や端末オブジェクト全体を文字列として渡さない。

取得には Tailscale アプリで選択中のアカウントを使い、iOSSH への API トークン設定は不要。一覧は SSH の有効化や接続許可を示すものではないため、[Tailscale SSH](https://tailscale.com/docs/features/tailscale-ssh) を設定したサーバーを選ぶ。正規化したホスト名 / IP・ユーザー名・ポートが同じ既存登録はスキップし、設定と資格情報を維持する。短い端末名・完全な DNS 名・IP の相互対応は、別名情報がない場合には判定できない。接続時の初回・変更時ホスト鍵確認は引き続き行う。

受け取った候補はメモリ内で保持する。Cancel で破棄し、保存には明示的な選択とユーザー名が必要。SSH 接続中に受け取った場合もセッションを保持し、他のアプリ内シートや認証の終了後に表示する。入力は空行を除く 512 件・64 KiB まで。大きな tailnet は Find Devices のフィルターで分けて取得できる。ショートカットの失敗・キャンセル時は直前の候補一覧を確認できる。

取得に失敗した場合は、ショートカットから返されたエラー説明を iOSSH に表示する。**Open Shortcuts** で **Import Tailscale Hosts** が存在するか確認し、直接実行して停止するアクションを調べる。見当たらなければ **Set Up Shortcut** から同梱ファイルを追加する。

`TailscaleHostImportTests` では正規化、上限、重複、検証、保存失敗時の取消を、`TailscaleImportInboxTests` では App Intent の受信とコールバック処理を検証する。`TailscaleImportPresentationTests` は実際の UI を表示し、認証を優先することと、端末確認・セッション切替中の接続保持を確認する。`TailscaleImportUITests` は架空の端末を使い、iPhone / iPad で選択、保存される SSH 設定、キャンセル、セットアップを検証する。Tailscale 公式アクションの実行と初回許可は、両アプリをインストールした実機で確認する必要がある。

## iPad ワークスペース

iPad ではサイドバーの保存済みホストを選ぶと、新しい接続を開くか、そのホストで直近に使ったセッションへ戻る。タブ列の **+**、**Command-T**、ホストのコンテキストメニューの **New Session** は、同じホストへの追加接続も含め、独立したシェルを開く。切断済みも含め最大 4 タブを保持できる。タブを閉じるとそのシェルだけを終了し、切断済みタブの出力は明示的に再接続・終了するまで残る。

サイドバーを隠すとターミナルが広がる。ウィンドウ幅が 700 ポイント未満になると、サイドバーとタブ列をツールバーの Hosts・Sessions メニューへ切り替える。Sessions メニューから各タブの選択・終了ができる。リサイズしても全接続と端末状態を保持する。iPhone は同じセッション所有方式を使い、全画面の 1 接続を維持する。

詳細領域の最上部 1 行にサイドバーの表示切り替え、タブ、セッション操作をまとめ、接続先を中央に表示する別のタイトル行は置かない。設定はサイドバー下部、狭い表示では **Hosts** 選択画面から開く。iPad のターミナルは角丸と小さな内側余白を使い、ソフトウェアキーボード上の表示領域を確保しながら文字が角にかかることを防ぐ。

認証画面の **Later** は要求を保留して他のタブを使えるようにする。元のタブの **Continue** から再表示し、**Cancel** はその接続試行を終了する。ホスト鍵と資格情報の回答は、要求元のセッション・接続試行・要求に結び付ける。非表示タブが新しい認証シートを自動表示することはない。

外付けキーボードでは **Command-W** で終了、**Command-Shift-[ / ]** で切り替え、**Command-1…4** で並び順から選択、**Command-,** で設定を開く。ターミナルに入力先があるときに有効になり、入力欄の通常の編集ショートカットは維持する。セッション切り替えでは日本語の未確定文字と一時的な Ctrl 状態を取り消す。非同期の貼り付けは送信前にセッションや接続試行が変わると破棄し、別タブには送らない。PTY のサイズ変更を後続のユーザー入力より先に送信する。

描画するのは選択中のターミナルだけ。非表示セッションも出力をパースし、上限付きの履歴を保持して、アプリ復帰時に接続を確認する。ワークスペース全体でデコード済み Kitty 画像のキャッシュ 64 MiB を共有し、1 画像は 16 MiB まで。メモリ警告では画像キャッシュを解放し、SSH 接続や端末のテキストは保持する。

利用可能な iPad シミュレータ名で `make test-ui SIMULATOR='iPad Pro 11-inch (M5)'` を実行する。`iPadWorkspaceUITests` は接続タブ、認証の保留、同じホストへの複数接続、タブ上限、終了、サイドバー変更、キーボード領域を確認する。`WorkspaceLayoutTests` は制御可能な通信層と実際の適応型 UI を使い、広い・狭い・縦長の領域で描画ビューの所有と PTY サイズ、再接続しないことを確認する。iPad 専用テストは iPhone ではスキップする。ウィンドウ操作、Magic Keyboard・トラックパッド、フローティングキーボードの操作、連続出力の性能は iPad 実機でも確認が必要。

## ターミナル

ターミナルをタップしてキーボードを表示する。補助行には Ctrl / Esc / Tab / 矢印 / パイプ / チルダを用意。外付けキーボードの修飾キー、アプリケーションカーソルモード、bracketed paste に対応する。上下スワイプで履歴を移動し、長押ししてドラッグすると選択できる。編集メニューまたは Command-C / Command-V でコピー・ペーストする。設定からフォントサイズとダーク / ライトの配色を変更できる。

標準フォントとして **HackGen Console NF を 9pt** で使用し、日本語と Starship 用の Nerd Font 記号に対応する。保存済みのフォントサイズは維持する。行高はフォント本来の高さを端末のピクセル単位に丸め、小さいサイズでブロックアートを縦長にする余分な行間は追加しない。未収録の文字は、追加フォントの使用時も含め、同梱 **Noto Sans CJK JP** の Regular / Bold で補う。絵文字は OS のカラー絵文字フォールバックを利用する。半角と全角の送り幅は 1:2。幅の広い記号もパーサが指定するセル数に収め、Powerline の区切りはセルの端まで描画する。設定では選択中のフォントのプレビュー、日本語フォールバック、すべての同梱フォントのライセンスを確認できる。サーバー側のプロンプトの文字幅設定も、端末の Unicode 幅と一致させる必要がある。

全角文字の後半セルは、前半セルの解決済みの色と文字装飾を引き継ぐ。SwiftTerm 1.20.0 が後半セルへ古い既定背景色を設定する挙動を補正し、日本語の右半分に白い四角が出る問題を防ぐ。GPU テストでは全角スペースと後続の英数字も含め、画面全体を独立したグリフ描画と比較する。

ブロック要素の半分・八分の一・四分割などは、セル境界にそろえたピクセルの矩形として描画する。セル寸法が奇数でも補完する図形は同じ境界を共有し、フォントの余白・斜体・アンチエイリアスによる ANSI アートの隙間を防ぐ。網掛けやその他の文字はフォントで描画する。

SwiftTerm 1.20.0 はカーソルを含む段落をリサイズ時の再折り返し対象から外す。幅を狭めると、接続先が再描画するまでその段落の右端が切れる場合がある。改行で完了した段落は再折り返しされる。

設定から「ファイル」にある等幅 `.ttf` / `.otf` フォントを追加できる。iOSSH の Application Support にコピーしてこのアプリ内で登録し、OS 全体にはインストールしない。選択は次回起動時も復元し、選択中の追加フォントを削除すると標準フォントへ戻る。

日本語入力には端末カーソル位置の UIKit 入力欄を使う。変換中の文字と候補の編集は確定まで端末内に保持し、変換中の削除・キャンセルで送信済みのサーバーの文字を消さない。

最終行は不透明な補助キー行の上に配置する。キーボードの変化・アプリ復帰・再接続時には、その時点のキーボードと補助キー行の位置から表示領域を再計算し、行数・列数を PTY へ送る。

キーボードの高さが変わっても文字・画像のピクセルサイズを保ち、表示できる行数だけを変える。停止中の Metal ビューも描画先の寸法をビューに同期し、シェルからの出力がなくても再描画する。iPad ではキーボードが画面外へ移動した通知を受けると古いキーボードガイドを除外し、非表示後の下端の余分な空白を解消する。補助キー行が表示されたままの場合は、実際の高さ分の領域を確保する。

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

## App Store公開準備

Bundle IDとShortcutsのコールバックURLスキームは `io.github.m96-chan.iossh` を使う。共有プロジェクトの `DEVELOPMENT_TEAM` は空のままにし、ビルド時にチームを指定する。旧 `moe.technologies.iossh` とは別アプリとして共存し、保存済みホスト、Keychainの資格情報、設定、信頼済みホスト鍵、追加フォントは自動移行されない。新アプリから書き出したファイルで旧 **Import Tailscale Hosts** ショートカットを同名のまま置き換え、新アプリから端末一覧を取得する。[ショートカットの移行手順](../shortcuts/README.md#updating-from-the-previous-app-identifier)を参照。

[ストア掲載文と審査メモ](APP_STORE.jp.md)、[サポート](SUPPORT.jp.md)、[プライバシーポリシー](PRIVACY.jp.md)は、公開に必要な残りの情報を確定するまで草案とする。アプリのプライバシーマニフェストは、アプリ内設定用のUserDefaultsへのアクセスを理由 `CA92.1` で申告している。

ソフトウェアのライセンス本文は `App/Resources/ThirdPartyNotices.txt` に同梱し、**Settings → Open source licenses**から閲覧できる。依存更新時はリンク対象を確認し、Xcodeが解決したチェックアウトから再生成する。

```sh
python3 scripts/generate_third_party_notices.py --checkouts build/DerivedData/SourcePackages/checkouts
python3 scripts/generate_third_party_notices.py --checkouts build/DerivedData/SourcePackages/checkouts --check
```

実際に使用したDerivedDataのパスを指定する。生成処理は通信せず、固定されたGitオブジェクトを読む。Citadelのbcrypt、SwiftNIOのcpp_magic.h、BoringSSL、fiat-cryptoのC実装の表記も含む。フォントの表記は別の**Font licenses**にある。`xcodegen generate`で、本文とアプリのプライバシーマニフェストをリソースへ追加する。

提出前には、最終アーカイブに含むSDKのプライバシー申告を確認する。SwiftTerm 1.20.0にはKittyのローカルファイル・共有メモリ転送に `stat` / `fstat` があり、独自のプライバシーマニフェストはない。iOSSHはKitty画像を別処理で扱い、直接転送だけを受け付けるため、このSDK内の処理は使用しない。残るコードに対してiOS向けSDKの変更が必要かは引き続き確認する。シンボルが含まれることだけでApp Storeの拒否を断定せず、検証を通すために用途の異なる承認理由を追加しない。

## ローカルで確認済みの項目

2026-09-12、Xcode 26.5 / Swift 6.3.2 で検証:

- バージョン 0.1.0 build 10 はブロック・四分割文字をセル境界に合わせて描画し、ANSI アートのギザギザを修正。旧描画は新規ブロックマスク・GPU テストの全 8 ケースで失敗し、修正後は 9 / 16pt・2倍 / 3倍密度のすべてで成功。両 Simulator でアプリ・描画 77 テストとネイティブのリサイズ・レイアウト検証も成功した。ユーザーの元 ANSI アートをローカルで修正前後に描画して目視比較し、一時入力と診断テストはリポジトリに含めていない。署名済みビルドを両実機へ Wi-Fi でインストールし、両方で起動を確認。iPhone も画面ロック解除後に起動した。
- iPhone / iPad 対象の iOS Simulator 向けアプリビルドが成功。
- バージョン 0.1.0 build 9 は初期フォントサイズを 9pt にし、余分な 2pt の行間を除去。2倍密度の画面では、9pt の HackGen セルが 10×25px から 10×21px になる。両 Simulator でアプリ・描画テスト 75 件とネイティブリサイズ・GPU テストが成功。フォールバックと Powerline・絵文字の検証を 9 / 16pt、2倍 / 3倍密度へ拡張した。iPhone の日本語かな入力、iPad の設定・ネイティブワークスペースレイアウト・連続キーボード開閉も成功。署名済みビルドを両実機へ Wi-Fi でインストールして起動を確認。更新後の実際の SSH 出力との比較は手動確認が必要。
- バージョン 0.1.0 build 8 はキーボード開閉時のターミナル描画の引き伸ばしと、iPad 下端に残るキーボード由来の空白を修正。修正前に、出力停止中の再描画欠落と iPad の余分な空白を再現した。iPhone・iPad Simulator で既存のアプリ・描画テスト 75 件と新規のネイティブリサイズ・GPU テスト 2 件が成功。各端末で 3 回連続のキーボード開閉を確認し、iPad の標準の閉じるボタンも検証した。iPad のワークスペース・レイアウト、iPhone の日本語かな入力・アプリ復帰・再接続も成功。署名・プロファイル確認後、iPhone 17e と iPad Air（第 4 世代）へ Wi-Fi でインストールして起動を確認。ユーザーの実際の SSH 出力での確認は引き続き必要。
- バージョン 0.1.0 build 7 は採用した B 案をアプリアイコンに設定。提供された PNG の構図を保ち、アプリアイコン用の 1024 ピクセルに縮小した。実機・Simulator 向けビルド、署名、両端末のプロファイル確認が成功。iPhone 17e と iPad Air（第 4 世代）へ Wi-Fi 経由でインストールして起動を確認し、両端末から取得したアイコン画像でも B 案への更新を確認。
- バージョン 0.1.0 build 6 は iPad のタブを最上部へ移し、接続先の重複タイトルを削除。設定をサイドバーへ移し、ターミナルを角丸にした。ネイティブ iPad 画面テスト、iPad ワークスペース UI の 2 フロー、両端末の設定、iPhone のキーボード・復帰・再接続フローが成功。スクリーンショットを確認し、署名済みビルドを iPad Air（第 4 世代）へ Wi-Fi 経由でインストールして起動を確認。
- バージョン 0.1.0 build 5 で iPad ワークスペースを追加。iPad Pro 11-inch (M5) と iPhone 17 の Simulator でアプリ・描画の 75 テストが成功。ネイティブ iPad 画面テストは広い・狭い・縦長の領域で成功し、3 シェルと表示中の描画ビュー 1 個を保持した。新規 iPad UI の 2 フローと既存 iPhone UI の全 5 テストが成功し、実際のかなキーボードによる候補選択・確定も確認。画像上限の共有を含む TerminalCore の全 26 テストも成功。build 5 は iPad Air（第 4 世代）に Wi-Fi 経由でインストールして起動を確認し、ユーザーも動作を確認済み。ウィンドウ操作、外付け入力、連続出力の性能を含む全面的な実機受け入れ確認は残る。
- 個人チーム署名の Debug ビルドを署名検証し、iPhone 17e / iOS 26.6.1 にインストール。開発者証明書の信頼後に起動を確認。初期ビルドで Tailscale SSH サーバーに接続できることはユーザーが確認済み。
- バージョン 0.1.0 build 3 は、署名・個人チームのプロファイル・同梱 HackGen Regular / Bold のチェックサムを検証し、同じ iPhone に Wi-Fi 経由で更新済み。ユーザーの画面ロック解除後に更新版の起動を確認。このビルドでの日本語入力はユーザーが実機で確認済み。ユーザーの Starship テーマ、画面ロックからのセッション復帰、Tailscale check mode は実機確認が引き続き必要。
- バージョン 0.1.0 build 4 は、署名と同梱 HackGen / Noto フォントのチェックサムを検証し、同じ iPhone に Wi-Fi 経由で更新して起動を確認。修正前の GPU 出力で右半分の白背景を再現し、修正後の画面全体は独立した基準画像と RGB 各成分 1 以内の差で一致。ユーザーの接続先の出力での実機確認は継続する。
- SSHCore: Tailscale 認証・上限付き認証バナー・既存接続の確認（相手の応答、拒否、タイムアウト、待機キャンセル）を含む単体・プロトコルテスト 24 件が成功。任意の実 OpenSSH 結合テストは初期検証で成功し、今回の更新ではスキップ。
- TerminalCore: 21 テスト / パラメータ化を含む 24 ケースが成功。全角の両半分の色・装飾と、改行済み日本語段落の再折り返しを確認。
- アプリ・描画: iPhone 17 / iOS 26.5 Simulator で 53 テストが成功。既存接続の保持、Tailscale サインイン、HackGen の収録・ラスタライズ、フォントの取り込み・削除・再取り込み、Noto JP フォールバック、日本語変換、キーボードの表示領域を確認。GPU の画面全体の比較により、右半分の背景色の問題の再現と修正も確認。
- UI: build 4 で日本語かな入力と設定の 2 テストが再度成功。以前の iPhone 17 の全体実行と対象を絞った再実行では計 5 テストが成功。キーボード表示、アプリ復帰、再接続、画面回転、実際のかなキーボードによる候補選択・確定を確認。未確定文字と候補バーのスクリーンショットも確認。初期検証では iPad Pro 11-inch (M5) / iOS 26.5 Simulator のターミナル起動・認証キャンセルも成功。
- Metal の GPU 描画・ブレンド検証スクリプトが成功。ターミナルと iPad 初回起動画面のスクリーンショットも確認済み。

## 残る受け入れ検証

- 実機での Keychain 生体認証、外付けキーボード、バックグラウンド動作、多言語入力。
- 実サーバーに接続した `vttest` / `esctest`、Neovim / Helix の画像プラグイン互換性。
- Instruments による 120Hz、大量出力、メモリ圧、アイドル時の消費電力の計測。
- Display P3 出力、メイン actor 外へのパーサ隔離、将来の libghostty-vt バックエンド。
- keyboard-interactive、対応する鍵形式の拡充、reflow 前後の画像配置の保持。
