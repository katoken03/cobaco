# メニューに「新しいドメインを追加」を追加

## Context

`cobaco` メニューではドメイン追加が完結しない。`domains.yml` を手で編集し、そのあと「設定を適用」「PHP-FPM」「git clone」「デプロイ」を別々に、正しい順で実行する必要があって迷う。そこで root 用の項目「新しいドメインを追加」を作り、対話で基本項目を入力して `domains.yml` に追記し、そのまま初回デプロイまで 1 本の流れで進めるウィザードにする。

決めたこと (ユーザー回答):
- `domains.yml` には対話入力で自動追記する。mysql / basic_auth / php_settings などの細かい項目は後でエディタで書く
- 追記後に続けて行うこと: add-domain.sh (dry-run → 本番)、PHP-FPM の起動確認、git clone、初回デプロイ
- DNS を事前に確認し、このサーバーを向いていなければ警告して ssl を後回しにできる

## ウィザードの流れ (`cli/src/menu/add-domain-wizard.ts`)

最初にステップ一覧を表示する。各ステップは「実行 / スキップ / 中断」を選べる。コマンドを実行するステップは、既存メニューと同じく実行前にコマンドを表示して確認する。

1. **ドメイン名**: 小文字の FQDN だけを受け付ける。`domains.yml` の `name` / `ssl_subdomains` と重複したらエラーにして再入力させる
2. **type**: php / nodejs
   - php: `php_version` を選ぶ。選択肢はサーバーにある `/etc/php/*/fpm` から作り、新しい順に並べて先頭を既定にする
   - nodejs: `port` は既存の最大 port + 1 (なければ 3000) を既定にする。1024〜65535 の範囲で、他ドメインと重複しないこと。`pm2_name` はドメイン名の `.` を `-` にしたものを既定にし、重複は不可
3. **www_redirect**: confirm で選ぶ (既定 No)
4. **DNS 確認**: `node:dns` で `name` (www_redirect なら `www.` も) の A / AAAA を引き、このサーバーのグローバル IP (`os.networkInterfaces()`) と比べて結果を表示する
5. **ssl**: DNS が一致していれば既定 Yes。不一致または未解決なら既定 No にして「DNS 設定後に ssl: true にして『ドメイン設定を適用』」と案内する。ssl と www_redirect が両方 Yes のときは `ssl_subdomains: [www.<name>]` を自動で付ける (add-domain.sh の検証ルールに合わせる)
6. **プレビュー → 追記**: 追加する YAML を表示し、confirm したら追記する (方法は下記)
7. **add-domain.sh**: まず `bash add-domain.sh --dry-run <name>` を実行する。終了コードが 0 なら「本番実行しますか?」と聞いて `bash add-domain.sh <name>`。失敗したらその時点で止め、domains.yml を直して「ドメイン設定を適用」から再開するよう案内する
8. **PHP-FPM** (php のときだけ): `systemctl is-active php<ver>-fpm` が active でなければ `bash apply-php-fpm-services.sh` を実行する (使うバージョンが止まっていれば起動する)。active ならスキップしたことだけ表示する
9. **git clone** (リポジトリ URL を入力。空ならスキップ):
   - add-domain.sh が `/var/www/<name>` に `conf/` や `public/` を作った後なので `git clone` は使えない。cobaco ユーザーで `git init -b <branch>` → `remote add origin <url>` → `fetch origin` → `checkout -t origin/<branch>` を順に実行する (ブランチの既定は main)
   - URL が SSH 形式 (`git@` / `ssh://`) のとき: cobaco に `~/.ssh/id_ed25519` がなければ作るか聞き (`ssh-keygen -t ed25519 -N ""`)、公開鍵を表示して「GitHub の Deploy key に登録したら Enter」で待つ。fetch は `GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new'` で実行する
   - すでに `.git` があればスキップする
10. **初回デプロイ**: `sudo -u cobaco -i bash <SCRIPT_DIR>/deploy.sh [--branch X] <name>`。`-i` を付けるのは、nvm を読む `/etc/profile.d/nvm.sh` を通すため
11. **まとめ**: 各ステップの結果 (完了 / スキップ / 失敗) と、残りの手作業 (mysql・basic_auth・php_settings は domains.yml を編集してから「ドメイン設定を適用」、ssl を後回しにした場合の手順) を表示する

## domains.yml への追記 (`cli/src/lib/domains.ts` に `appendDomain` を追加)

利用者のコメントや書式を崩さないよう、`yaml` で全体を書き直すのではなくテキストとして末尾に追記する。
- `stringify([entry])` を 2 スペース字下げして、ファイル末尾に空行 + エントリとして追加する
- 書き込みの前に `domains.yml.bak` に退避し、一時ファイルに書いてから rename する。パーミッション (644) は元のファイルに合わせる
- 書き込み後に読み直し、`domains[]` に新しい `name` が入っているか確認する。入っていなければ (`domains:` が最後のトップレベルキーではない場合など) .bak から戻し、「手で追記してください」と表示してプレビューの YAML を出す

## メニューへの組み込み

- `catalog.ts` の「ドメイン」グループの先頭に「新しいドメインを追加」を置く (user: root)。`when` は「domains.yml への追記から初回デプロイまでを順番に案内する」
- `MenuItem.action` を使う。実行して確認する処理は `menu/index.ts` の `runItem` 内にあるので、`runCommand(cmd, { message }) => Promise<number | 'skipped'>` として切り出し、ウィザードと共用する
- 開発確認用に、環境変数 `COBACO_AS_ROOT=1` で root 項目を表示できるようにする (スクリプト側でも root を確認しているので、表示が出るだけで害はない)

## 変更ファイル

- 新規: `cli/src/menu/add-domain-wizard.ts`
- 変更: `cli/src/menu/catalog.ts`, `cli/src/menu/index.ts` (`runCommand` の切り出し), `cli/src/menu/inputs.ts` (必要な入力関数), `cli/src/lib/domains.ts` (`appendDomain` と重複チェック用のヘルパー), `cli/src/lib/shell.ts` (`COBACO_AS_ROOT`)
- ドキュメント: `DOC.md` の cobaco メニュー節に「新しいドメインを追加」の流れと、git clone の方式 (init + fetch) と Deploy key の手順を追記。AGENTS.md の基本的な使い方に「ドメイン追加はメニューの『新しいドメインを追加』でも可」と 1 行追記

## 検証

1. `bun run typecheck`
2. Mac: `domains.yml.sample` を scratchpad にコピーし、`COBACO_DOMAINS=<copy> COBACO_AS_ROOT=1 bun run dev` でウィザードを pty から操作する
   - 重複ドメイン・不正な FQDN・使用中の port が弾かれること
   - 追記後のファイルで既存のコメントと書式が保たれ、`yaml` でパースできること (diff で確認)
   - DNS 確認が実在ドメインと未登録ドメインの両方で期待どおりに表示されること
   - add-domain.sh 以降は Mac では root チェックで失敗するので、失敗時に止まって案内が出ることを確認する
3. VPS (root): テスト用のサブドメインで、ssl を後回しにして最後まで通す。domains.yml の追記内容、`/var/www/<name>/.git`、デプロイの成功を確認する。その後 DNS を設定し、ssl: true に変えて再適用できることも確認する
