# 使っていない PHP-FPM を domains.yml にもとづいて止める

## Context

本番サーバーでは PHP 7.3 / 7.4 / 8.2 / 8.3 / 8.5 の FPM がすべて動いている。しかし domains.yml で使われているのは 8.5（shopping.flatsystems.net）だけである。ほかの 4 つはパッケージ標準の `www` プールを動かしているだけで、合わせて RSS 約 230MB を使っている。

`setup.sh` は全バージョンを毎回 enable と start するので、手で止めても再実行すると元に戻る。そこで「domains.yml で宣言されたバージョンの FPM だけを動かす」処理をスクリプトにして、再現できるようにする。

決定事項（ユーザー回答）:
- 新しいスクリプトは単体でも実行できるようにする。`setup.sh` と `add-domain.sh` の最後からも呼ぶ
- **止める前に必ず確認する**。止める予定のバージョンを表示し、「不要な PHP-FPM が起動しています。停止しますか? [y/N]」のように y/N を入力させる。y のときだけ止める
- 使っていなくても動かしておく、という例外指定の仕組みは作らない
- domains.yml がないときは何もしないでスキップする

## 1. 新規 `apply-php-fpm-services.sh`（root）

雛形は `apply-mysql.sh` / `configure-os.sh` と同じにする（色付き出力、EUID チェック、`set -euo pipefail`）。バージョンの一覧は、`apply-php-fpm-ini.sh` を source して `COBACO_PHP_VERSIONS` を使う。このファイルは source されたときには本体を実行しない作りになっている。

使い方:
```
bash apply-php-fpm-services.sh            # 確認してから止める
bash apply-php-fpm-services.sh --dry-run  # 表示だけ
bash apply-php-fpm-services.sh --yes      # 確認せずに止める（自動化用）
```

処理:
1. `/root/cobaco_config/domains.yml` がなければ info を出して `exit 0`
2. **使うバージョン**を集める
   - domains.yml の `type: php` のドメインの `php_version`（`yq e '.domains[] | select(.type == "php") | .php_version'`）
   - 安全のため、`/etc/php/<ver>/fpm/pool.d/` に `www.conf` 以外の `*.conf`（ドメイン用プール）があるバージョンも「使う」に含める。domains.yml に書かれていないのにプールが残っている場合は warn を出して止めない
3. インストール済みのバージョンごとに処理する（`systemctl list-unit-files php<ver>-fpm.service` で判定。`setup.sh:361` と同じ方法）
   - 使うバージョンなのに止まっている、または disabled → `systemctl enable --now` を実行して info を出す（起動するだけなので確認しない）
   - 使わないバージョンで、active または enabled → 「止める候補」に入れる
4. 止める候補があれば一覧（バージョン、使っていない理由）を表示して、確認する:
   ```
   [WARN] どのドメインも使っていない PHP-FPM が起動しています: 7.3 7.4 8.2 8.3
   不要な PHP-FPM を停止しますか? [y/N]:
   ```
   - y/Y のときだけ、各バージョンに `systemctl disable --now php<ver>-fpm` を実行する
   - **mask はしない**。あとでそのバージョンのドメインを追加したときに起動できるようにするため
   - N のとき、または端末がない（`[[ -t 0 ]]` が偽）ときは、「停止しませんでした」と表示して `exit 0`
   - `--yes` を付けたときは確認しない。`--dry-run` を付けたときは表示だけする
5. 最後に、各バージョンの状態（active/enabled）を一覧で表示する

止めても影響がないもの:
- `monitor.sh:338-341` は enabled な FPM だけを監視するので、disable したバージョンで警告は出ない
- `cobaco-php` / `composer`（CLI）は FPM とは別なので、そのまま使える

## 2. `add-domain.sh` の変更

- `validate_domain_config`（742 行目付近）: 今は FPM が止まっていると die で終了する。これを、unit があれば `systemctl enable --now php<ver>-fpm` で起動して先へ進むように変える。unit がない（未インストール）ときだけ、今のエラーメッセージで die する。dry-run のときは「起動予定」と表示するだけにする
- メイン処理の最後（全ドメインの処理が成功した後）に、dry-run でなければ `bash "${SCRIPT_DIR}/apply-php-fpm-services.sh"` を呼ぶ。止める候補があれば、ここで y/N を聞く。PHP バージョンを変えたときの古いバージョンも、ここで止める候補になる

## 3. `setup.sh` の変更

- 最後（監視のセットアップの後、完了メッセージの前）で `bash "${SCRIPT_DIR}/apply-php-fpm-services.sh"` を呼ぶ。インストール関数が全バージョンを enable・start するのはそのまま残し、最後にここで止めるかどうかを聞く
- domains.yml がない初回のセットアップでは、スクリプトがスキップするので、今の動作と変わらない

## 4. ドキュメント

- `DOC.md` の「## PHP 設定」の下に「### 使っていない PHP-FPM の停止（apply-php-fpm-services.sh）」を足す。内容は、何を「使う」と判定するか、確認の流れ、`--dry-run` と `--yes`、mask しない理由、戻し方（`systemctl enable --now php<ver>-fpm`。または domains.yml に書いて `add-domain.sh` を実行する）
- `AGENTS.md` のファイル構成に 1 行足す。「基本的な使い方」にも必要なら 1 行足す

## 5. コミットと適用

- Nginx catch-all の未コミット変更とは分けてコミットする（前回と同じく、hunk を選んでステージする）
- 例: `feat(php): stop PHP-FPM versions not used by domains.yml`
- push とサーバーへの適用は、そのつどユーザーの了承を得てから行う。適用は `cd /root/cobaco && git pull && bash apply-php-fpm-services.sh` で、y/N はユーザーが手で入力する。または、ユーザーの了承を得て `--yes` で実行する

## 検証

- ローカル: `bash -n apply-php-fpm-services.sh add-domain.sh setup.sh`
- サーバー:
  - `bash apply-php-fpm-services.sh --dry-run` → 止める候補が 7.3 / 7.4 / 8.2 / 8.3 で、8.5 は「使う」と表示されること
  - N と答えると何も変わらないこと（`systemctl list-units 'php*-fpm*'`）
  - y で止めた後: 8.5 だけが active になっていること。`https://shopping.flatsystems.net/` が 200 を返すこと。`free -m` でメモリが空いたこと
  - 再実行すると「止める候補なし」と表示され、確認を聞かれないこと（冪等性）
  - `add-domain.sh --dry-run shopping.flatsystems.net` がエラーにならないこと
