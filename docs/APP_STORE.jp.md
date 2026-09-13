# App Storeリリース準備稿

[English](APP_STORE.md) | 日本語

実装済みの機能に基づく原稿です。App Store Connectには未提出です。個人のApple Developer契約とBundle ID `io.github.m96-chan.iossh` で公開を準備します。

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

## 公開までに必要な情報・確認

- 新しいBundle IDの配布用チームへの登録を確認し、App Store Connectのアプリ情報を作成して、署名付きアーカイブを検証する。
- ストア名の空き状況、主言語、価格、配信国を確定する。
- 実際の問い合わせ先を含めて[プライバシーポリシー案](PRIVACY.jp.md)と[サポートページ案](SUPPORT.jp.md)を確定・公開する。App Store ConnectへのURL登録とともに、アプリ内からも開けるリンクを設ける。
- 配布する実装に基づき、App Privacy、年齢区分、暗号化・輸出コンプライアンスの回答を確定する。SSHは依存ライブラリを通じて暗号処理を使うため、`ITSAppUsesNonExemptEncryption` を推測で自動設定していない。
- **Settings → Open source licenses**で同梱ソフトウェアの表記と、別に用意したフォントのライセンスを確認する。
- 最終ビルドのiPhone・iPadで、私用サーバーの情報を含めず、テスト用接続先によるストア向けスクリーンショットを撮影する。[開発ノート](DEVELOPMENT.jp.md)の実機確認を完了する。
- 審査担当者向けの連絡先と、動作するSSH接続情報を用意する。

Appleの資料：[アプリ情報の作成](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app)、[ビルドのアップロード](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)、[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。
