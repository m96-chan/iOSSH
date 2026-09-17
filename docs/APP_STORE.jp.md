# App Storeリリース準備稿

[English](APP_STORE.md) | 日本語

実装済みの機能に基づく原稿です。初回提出は2026年9月16日にGuideline 2.1の追加情報要求で差し戻されました。Appleからバイナリの不具合は指摘されていません。個人のApple Developer契約とBundle ID `io.github.m96-chan.iossh` で公開を準備します。

旧 `moe.technologies.iossh` の開発ビルドとは別アプリとしてインストールされます。保存済みホスト、資格情報、設定、追加フォントは自動移行されません。端末一覧を取得する前に、新アプリから書き出した **Import Tailscale Hosts** で旧ショートカットを置き換えてください。[移行手順](../shortcuts/README.md#updating-from-the-previous-app-identifier)も参照してください。

## ストア掲載情報

- 公開名義の方針：**Yusuke Harada**の個人名義
- 名前：**iOSSH**
- サブタイトル：**iPhoneとiPadのためのSSHターミナル**
- カテゴリ案：**開発ツール**
- キーワード：`ssh,ターミナル,シェル,サーバー,コンソール,開発,linux,リモート`

### 説明文

iOSSHは、iPhoneとiPadからリモートのシェルを使うためのSSHクライアントです。接続先を保存し、パスワードや対応する秘密鍵で接続。カラー表示、スクロールバック、コピー＆ペースト、外部キーボードに対応したターミナルで作業できます。

iPadでは最大4つの接続タブを切り替え、ホスト一覧のサイドバーを必要に応じて表示できます。iPhoneでは、ひとつのターミナルに集中できる画面を使います。

日本語やシェルプロンプトの記号を表示するため、HackGen Console NFとNoto Sans CJK JPを同梱しています。文字サイズやテーマを変更したり、「ファイル」から等幅のTTF・OTFフォントを取り込んだりできます。対応するKitty Graphicsの画像転送も表示できます。

Tailscale SSHをお使いなら、Tailscaleアプリ経由で接続し、公式ショートカットアクションから選んだ端末を取り込めます。利用にはTailscaleアプリ、tailnetへの接続、同梱ショートカットの追加が必要です。接続先サーバーとtailnet側でもSSH接続が許可されている必要があります。

パスワード認証、OpenSSH形式のEd25519鍵、暗号化されていないECDSA PEM鍵に対応しています。RSA鍵とkeyboard-interactive認証には現在対応していません。

アプリに戻ったとき、接続が生きていれば同じシェルを再開します。切断後の再接続では新しいシェルが開きます。切断をまたいで作業を維持したい場合は、接続先のターミナルマルチプレクサーを利用してください。

## 審査用の準備

iOSSH専用のアカウントやサブスクリプションへのログインはありません。ターミナルの動作確認には、対応する認証方式で接続できるSSHサーバーが必要です。提出前に、維持管理できる審査用サーバーと認証情報をApp Review Informationへ登録します。認証情報はこのリポジトリに保存しません。シミュレータ専用のUIテスト用データは、審査用サーバーやリリース版のデモモードではありません。

Tailscaleは任意の機能です。通常のSSHはTailscaleなしで確認できます。端末の取り込みは **Import from Tailscale → Set Up Shortcut** から **Import Tailscale Hosts** を追加し、**Fetch Devices** を実行して登録する端末を選びます。

## Guideline 2.1への回答

Submission ID `9afe9cac-389d-4f2d-bb18-7f378de6ccf3`について、以下の情報が要求されました。完成した回答をApp Store Connectの審査メッセージと **App Review Information → Notes** の両方へ貼り付けます。角括弧の値はすべて置き換え、審査用サーバーの認証情報と録画はこのリポジトリへ保存しません。

### 回答案（日本語確認用）

1. **実機の画面録画**

実機のiPhoneまたはiPadで、アプリ起動 → 審査用SSHホストの追加 → 提供した認証情報で接続 → 実際のターミナル操作 → 切断、という通常の流れを録画して添付します。

iOSSH固有のアカウント登録、ログイン、アカウント削除はありません。ユーザー生成コンテンツをホストしないため、通報・ブロック機能もありません。有料デジタルコンテンツ、サブスクリプション、アプリ内課金はありません。

2. **目的と対象者**

iOSSHはiPhoneとiPad用のSSHターミナルクライアントです。モバイル端末からサーバーへ接続する開発者、システム管理者、そのほかの技術者を対象としています。標準互換のターミナル、パスワードと対応秘密鍵による認証、Unicodeと日本語入力、外部キーボード、フォントとテーマの設定、Kitty Graphics表示、iPadで最大4つの同時セッションタブを提供します。

3. **設定手順と審査用認証情報**

iOSSHアカウントは不要です。主機能は次の手順で確認できます。

1. iOSSHを起動して **Add Host** を選ぶ。
2. App Store Connectにのみ記載したSSHホスト、ポート、ユーザー名を入力し、認証方式に **Password** を選ぶ。
3. ホストを保存して選択し、審査用パスワードを入力する。初回はホスト鍵を確認して承認する。
4. ターミナルでコマンドを実行する。終了時は閉じるボタン、または **Terminal options → Disconnect** を使う。

```text
SSH host: [APP STORE CONNECTにのみ記載]
Port: [APP STORE CONNECTにのみ記載]
Username: [APP STORE CONNECTにのみ記載]
Authentication: Password
Password: [APP STORE CONNECTにのみ記載]
```

認証情報は審査期間中有効に保ちます。Tailscale取り込みは任意であり、SSHターミナルの審査には不要です。確認する場合は、別途インストールしたTailscaleアプリと設定済みtailnetが必要です。**Import from Tailscale → Set Up Shortcut** で同梱ショートカットを追加し、**Fetch Devices** からTailscale公式の **Find Devices** ショートカットアクションを実行します。

4. **外部サービス、ツール、プラットフォーム**

開発者が運営するバックエンド、アカウントサービス、解析、広告、決済、AIサービスはありません。主なネットワーク機能は、利用者が選択・管理するSSHサーバーへ直接接続します。Tailscaleは任意で、APIトークンを使わず、Tailscaleアプリと公式の **Find Devices** ショートカットアクションを介して利用します。Citadel、swift-nio-ssh、swift-crypto、SwiftTerm、libghostty-vtなど、SSH・暗号・ターミナル解析・描画のオープンソースライブラリを同梱しています。

5. **地域差**

機能や動作に地域差はありません。配信するすべての地域で同じように動作します。英語・日本語の表示と同梱CJKフォントはローカライズ機能であり、地域制限ではありません。

6. **規制産業と第三者コンテンツ**

iOSSHは汎用の開発者向けツールであり、規制産業のサービスではありません。ライセンスされた娯楽作品など、保護された第三者コンテンツは同梱しません。同梱する第三者ソフトウェアとフォントはオープンソースで、ライセンスは **Settings → Open source licenses** から確認できます。SSHセッション中に表示される内容は利用者が選んだサーバーから届くもので、iOSSHが提供するコンテンツではありません。

実際にAppleへ返信する際は、英語版の[Copy-ready response](APP_STORE.md#copy-ready-response)を使い、角括弧を置き換えます。

## 再提出チェックリスト

- 専用の審査用SSHサーバーを審査期間中オンラインに保つ。ホスト、ポート、ユーザー名、パスワードはApp Store Connectだけに記載する。
- 実機で、起動 → 審査用ホスト追加 → 接続 → ターミナル操作 → 切断の全手順を録画し、審査メッセージへ添付する。
- 完成した回答を審査メッセージと **App Review Information → Notes** の両方へ貼り付ける。
- 私用のホスト名、ユーザー名、IPアドレス、ターミナル履歴、第三者の映像が見えるストア画像は、審査用の安全なテストデータを使った画像へ差し替える。
- 再提出前にApp Privacy、年齢区分、輸出コンプライアンス、価格、配信地域、プライバシーポリシーURL、サポートURL、審査連絡先、選択ビルドを再確認する。

## リリース記録と毎回の確認

- 公開済みの[プライバシーポリシー](PRIVACY.jp.md)と[サポートページ](SUPPORT.jp.md)のURLをApp Store Connectへ登録した状態に保ち、アプリ内の **Settings → About** と一致させる。
- App Privacy、年齢区分、暗号化・輸出コンプライアンスの回答をリリースごとに確認する。SSHは依存ライブラリを通じて暗号処理を使う。`ITSAppUsesNonExemptEncryption` は、推測値ではなくApp Store Connectで明示的に回答するため、引き続き自動設定しない。
- **Settings → Open source licenses**で同梱ソフトウェアの表記と、別に用意したフォントのライセンスを確認する。ソフトウェアの表記は生成物であり、`scripts/generate_third_party_notices.py --check` が、アプリが実際にリンクしている依存関係との食い違いを検出して失敗する。`Package.resolved` に現れないまま全ビルドに含まれる libghostty-vt もこの対象に含めている。
- 最終ビルドのiPhone・iPadで、私用サーバーの情報を含めず、審査用の安全なテスト接続先によるストア向けスクリーンショットを撮影する。[開発ノート](DEVELOPMENT.jp.md)の実機確認を完了する。
- 提出ごとに審査担当者向けの連絡先と、有効なSSH接続情報を確認する。

Appleの資料：[アプリ情報の作成](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)、[ビルドのアップロード](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。
