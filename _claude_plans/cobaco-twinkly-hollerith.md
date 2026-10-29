# cobaco 対話メニュー (`cobaco` を引数なしで起動)

## Context

スクリプトが 15 本近くに増え、「どんな時に何を実行すればよいか」が分からなくなってきた。矢印キーと Enter (番号キーでも可) で選ぶだけで、用途の説明を読み、対象ドメインを選び、実行するコマンドを確認してから実行できるメニューを作る。

リポジトリには既に `cli/` (Bun + TypeScript、`bun build --compile` で単体バイナリ、setup / list / apply / deploy) がある。ただし DOC.md / AGENTS.md に記載がなく、`apply` / `setup` は `sudo` 前提で cobaco ユーザーの sudo 権限 (reload のみ) と合っていない。この CLI を拡張してメニューを載せ、あわせて現状に合わせて直す。

決めたこと (ユーザー回答):
- 既存 `cli/` を拡張する。VPS 上で bun を使ってビルドする
- 矢印キーに加えて番号キーでも選べるようにする (ConoHa Web コンソール対策)
- 実行前に同等のシェルコマンドを表示し、確認してから実行する
- 各項目に「どういう時に使うか」の説明を付ける
- root / cobaco で表示する項目を出し分ける
- 対象ドメインは domains.yml から一覧で選ぶ (`--all` / `--dry-run` も選択肢に出す)

## ライブラリ

`prompts` は 2021 年以降ほぼ更新が止まっているため、**`@inquirer/prompts`** を使う。
- `select` が数字キーで項目を選べる (番号入力の要件を満たす)
- カーソル位置の項目の `description` をリストの下に出せる (用途の説明にそのまま使える)
- `Separator` でグループ見出しを作れる
- Ctrl+C で `ExitPromptError` が飛ぶので、メニュー側で捕まえて静かに終了する

(@clack/prompts は見た目は良いが数字キー選択がないので見送る。実装前に ctx7 で `@inquirer/select` の数字キー対応を再確認する。)

## 構成

```
cli/src/
├── index.ts            # 引数なし + TTY → メニュー。-h はヘルプ。既存サブコマンドは残す
├── menu/
│   ├── index.ts        # メインループ: カテゴリ選択 → 項目選択 → 引数入力 → コマンド表示 → 確認 → 実行 → Enter で戻る
│   ├── catalog.ts      # メニュー項目の宣言 (下記)
│   └── inputs.ts       # 共通入力: ドメイン選択 / dry-run 確認 / テキスト入力
├── lib/
│   ├── shell.ts        # run() を終了コードを返す形に変更 (runOrExit を別に用意)。SCRIPT_DIR 解決を修正
│   └── domains.ts      # list.ts の Domain 型と読み込みを切り出し (list とメニューで共用)
└── commands/           # apply / setup から sudo を外す (root で直接実行する前提に)
```

### catalog.ts の項目定義

```ts
type MenuItem = {
  label: string;            // 例: 'ドメイン設定を適用'
  when: string;             // 例: 'domains.yml を編集した後に。Nginx・SSL・FPM プールを生成'
  user: 'root' | 'cobaco' | 'any';
  build: (ctx) => Promise<string[] | null>; // 引数を対話で集めて argv を返す。null で戻る
};
type MenuGroup = { label: string; items: MenuItem[] };
```

実行ユーザーは `process.getuid() === 0` で判定。対象外ユーザーの項目は出さない (グループが空なら見出しごと出さない)。実行は `run(['bash', join(SCRIPT_DIR, 'add-domain.sh'), ...])` のようにスクリプトを直接呼ぶ (sudo は使わない)。表示するコマンドは `bash add-domain.sh --dry-run example.com` のように SCRIPT_DIR からの相対で見せる。

### メニュー内容 (初版)

| グループ | 項目 | スクリプト | ユーザー |
|---|---|---|---|
| ドメイン | ドメイン一覧 | (list.ts を内部呼び出し) | any |
| | ドメイン設定を適用 | `add-domain.sh <domain\|--all> [--dry-run]` | root |
| | DB を適用 | `apply-mysql.sh <domain\|--all> [--dry-run]` | root |
| | デプロイ | `deploy.sh [--branch X] <domain\|--all>` | cobaco |
| PHP | FPM 共通 ini を反映 | `apply-php-fpm-ini.sh` | root |
| | 使わない PHP-FPM を停止 | `apply-php-fpm-services.sh [--dry-run]` | root |
| | Composer / php シムを配置 | `install-composer.sh` | root |
| セキュリティ | SSH 許可 IP 一覧 / 追加 / 削除 / 再適用 / 絞り込み off・on | `ssh-allow <sub>` (add は IP とメモを入力、remove は一覧から選択) | root |
| | ファイアウォール設定 | `configure-firewall.sh` | root |
| | fail2ban 設定 | `configure-fail2ban.sh` | root |
| | 未知の Host を拒否 (Nginx catch-all) | `configure-nginx-default.sh` | root |
| | OS の調整 | `configure-os.sh` | root |
| 監視 | 監視を試しに実行 | `monitor.sh --dry-run` | root |
| | 通知テスト | `monitor.sh --test-notify` | root |
| | 監視タイマーを配置 | `install-monitor.sh` | root |
| 初期構築 | サーバー初回セットアップ | `setup.sh` | root |

ドメイン選択は domains.yml の `name` を並べ、先頭に「全ドメイン (--all)」、末尾に「← 戻る」。deploy のブランチは既定 `main` のテキスト入力。各ドメインの hint に `type / php_version` を出す。domains.yml が見つからなければ list.ts と同じ案内を表示してメニューに戻る。

ssh-allow はリポジトリの `bin/ssh-allow` を呼ぶ (未配置の環境でも動くように)。

### 実行フロー

1. 選んだ項目の引数を集める → `$ bash add-domain.sh --dry-run example.com` を表示
2. `confirm('実行しますか?')` (既定 Yes)。No ならメニューへ
3. stdin/stdout を継承して実行。終了コードを `[OK]` / `[ERROR] exit N` で表示
4. 「Enter でメニューに戻る」→ 1 つ上の階層へ。トップで「終了」を選ぶか Ctrl+C で終了

## SCRIPT_DIR 解決の修正

現状は `dirname(process.argv[0])` を見ているが、コンパイル済み Bun では `argv[0]` が `bun` になり、シンボリックリンク経由でも壊れる。`realpathSync(process.execPath)` の親の親 (`cli/cobaco` → リポジトリ直下) を使い、従来どおり `add-domain.sh` の存在で確認する。開発時 (`bun run`) は `import.meta.dir` からの解決を残す。

## インストール: `install-cli.sh` (新規・root)

- bun を `/usr/local/lib/bun` に入れる (`BUN_INSTALL` 指定、バージョン固定、入っていれば skip)
- `cd cli && bun install --frozen-lockfile && bun run build`
- `/usr/local/bin/cobaco` → `<repo>/cli/cobaco` のシンボリックリンク (root / cobaco 両方が使える)
- `package.json` の build target を `bun-linux-x64` のまま、ARM VPS 用に `uname -m` で `bun-linux-arm64` に切り替え
- 冪等。git pull 後に再実行すれば再ビルドされる
- setup.sh の最後の案内に「`bash install-cli.sh` でメニューを導入」を追記

## ドキュメント

- AGENTS.md: ファイル構成に `cli/` と `install-cli.sh` を追加。「基本的な使い方」に「迷ったら `cobaco`」を追記
- DOC.md: `cobaco` メニューの節 (導入方法、ユーザーによる出し分け、項目追加の方法 = catalog.ts に 1 件足す)。新しいスクリプトを追加したら catalog.ts にも登録する旨を明記

## 変更ファイル

- 新規: `cli/src/menu/{index,catalog,inputs}.ts`, `cli/src/lib/domains.ts`, `install-cli.sh`
- 変更: `cli/src/index.ts`, `cli/src/lib/shell.ts`, `cli/src/commands/{list,apply,setup}.ts`, `cli/package.json` (+ `@inquirer/prompts`、build スクリプト), `cli/bun.lock`, `setup.sh` (案内のみ), `AGENTS.md`, `DOC.md`

## 検証

1. Mac: `cd cli && bun install && bun run dev` でメニュー表示、矢印・数字キー・Ctrl+C の動作、コマンド表示を確認 (domains.yml はリポジトリ直下のものを読めるよう、開発時のみ `COBACO_DOMAINS` 環境変数で上書き可能にする)
2. `bunx tsc --noEmit` で型チェック
3. VPS: root で `bash install-cli.sh` → `cobaco` → 「ドメイン設定を適用」→ 1 ドメイン → `--dry-run` で実行し、表示コマンドと実際の出力が一致すること
4. cobaco ユーザーで `cobaco` → root 専用項目が出ないこと、「デプロイ」が動くこと
5. ConoHa Web コンソールで数字キー選択ができること
6. `cobaco list` / `cobaco deploy example.com` など既存サブコマンドがそのまま動くこと
