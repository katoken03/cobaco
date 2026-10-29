import { printDomains } from '../commands/list';
import { askText, pickDomain, pickDryRun } from './inputs';

// build: 引数を対話で集め、リポジトリ直下から実行するコマンドを返す。null ならメニューに戻る
// action: コマンドを使わずメニュー内で完結する処理
export type MenuItem = {
  label: string;
  when: string;
  user: 'root' | 'cobaco' | 'any';
  build?: () => Promise<string[] | null>;
  action?: () => Promise<void>;
};

export type MenuGroup = {
  label: string;
  when: string;
  items: MenuItem[];
};

// 引数を集めない固定コマンド
const fixed = (...cmd: string[]) => async () => cmd;

export const CATALOG: MenuGroup[] = [
  {
    label: 'ドメイン',
    when: 'ドメインの一覧・設定の適用・DB・デプロイ',
    items: [
      {
        label: 'ドメイン一覧',
        when: 'domains.yml に宣言されたドメインを表で確認する',
        user: 'any',
        action: async () => {
          printDomains();
        },
      },
      {
        label: 'ドメイン設定を適用',
        when: 'domains.yml にドメインを追加・編集した後に。Nginx 設定・SSL・ドキュメントルート・FPM プールを生成する',
        user: 'root',
        build: async () => {
          const target = await pickDomain();
          if (!target) return null;
          const dryRun = await pickDryRun();
          if (!dryRun) return null;
          return ['bash', 'add-domain.sh', ...dryRun, target];
        },
      },
      {
        label: 'DB を適用',
        when: 'domains.yml の mysql (DB・ユーザー) だけを変えたときに。MariaDB に反映する',
        user: 'root',
        build: async () => {
          const target = await pickDomain();
          if (!target) return null;
          const dryRun = await pickDryRun();
          if (!dryRun) return null;
          return ['bash', 'apply-mysql.sh', ...dryRun, target];
        },
      },
      {
        label: 'デプロイ',
        when: 'アプリを更新したいときに。git pull・ビルド・再起動を行う (cobaco ユーザーで実行)',
        user: 'cobaco',
        build: async () => {
          const target = await pickDomain();
          if (!target) return null;
          const branch = await askText('ブランチ', { default: 'main', required: true });
          return ['bash', 'deploy.sh', ...(branch === 'main' ? [] : ['--branch', branch]), target];
        },
      },
    ],
  },
  {
    label: 'PHP',
    when: 'PHP-FPM の ini・使うバージョン・Composer',
    items: [
      {
        label: 'FPM 共通 ini を反映',
        when: 'templates/php/<ver>/99-cobaco.ini を変更した後に。配置して FPM を reload する',
        user: 'root',
        build: fixed('bash', 'apply-php-fpm-ini.sh'),
      },
      {
        label: '使わない PHP-FPM を停止',
        when: 'ドメインの php_version を変えた・ドメインを消した後に。domains.yml で使うバージョンの FPM だけを動かす',
        user: 'root',
        build: async () => {
          const dryRun = await pickDryRun();
          if (!dryRun) return null;
          return ['bash', 'apply-php-fpm-services.sh', ...dryRun];
        },
      },
      {
        label: 'Composer / php シムを配置',
        when: '初回、または Composer を更新したいときに。ディレクトリに応じて PHP バージョンを切り替える composer / cobaco-php / php を配置する',
        user: 'root',
        build: fixed('bash', 'install-composer.sh'),
      },
    ],
  },
  {
    label: 'セキュリティ',
    when: 'SSH の接続元 IP・ファイアウォール・fail2ban・Nginx・OS',
    items: [
      {
        label: 'SSH 許可 IP の一覧',
        when: 'SSH を許可している接続元 IP と UFW の状態を確認する',
        user: 'root',
        build: fixed('bash', 'bin/ssh-allow', 'list'),
      },
      {
        label: 'SSH 許可 IP を追加',
        when: '新しい場所 (自宅・オフィス等) から SSH 接続したいときに。UFW と fail2ban の除外に登録する',
        user: 'root',
        build: async () => {
          const ip = await askText('IP または CIDR (例: 203.0.113.5)', { required: true });
          const memo = await askText('メモ (例: office)');
          return ['bash', 'bin/ssh-allow', 'add', ip, ...(memo ? [memo] : [])];
        },
      },
      {
        label: 'SSH 許可 IP の管理 (削除・再適用・off/on)',
        when: 'ssh-allow の番号メニューを開く。削除や、絞り込みの一時解除 (off) / 再開 (on) はここから',
        user: 'root',
        build: fixed('bash', 'bin/ssh-allow'),
      },
      {
        label: 'ファイアウォール設定',
        when: '初回、またはポート構成を変えたときに。UFW で Web / SSH / メール(任意) だけを許可する',
        user: 'root',
        build: fixed('bash', 'configure-firewall.sh'),
      },
      {
        label: 'fail2ban 設定',
        when: '初回、または BAN 条件を変えたいときに。SSH の総当たりを BAN し、全ポートを遮断する',
        user: 'root',
        build: fixed('bash', 'configure-fail2ban.sh'),
      },
      {
        label: '未知の Host を拒否 (Nginx catch-all)',
        when: '初回に。IP 直打ちや知らないドメインへのアクセスを 444 / TLS 拒否で落とす',
        user: 'root',
        build: fixed('bash', 'configure-nginx-default.sh'),
      },
      {
        label: 'OS の調整',
        when: '初回に。ICMP リダイレクト無効化・不要サービスの mask・root の PM2 停止を行う',
        user: 'root',
        build: fixed('bash', 'configure-os.sh'),
      },
    ],
  },
  {
    label: '監視',
    when: 'monitor.sh の試し実行・通知テスト・タイマー配置',
    items: [
      {
        label: '監視を試しに実行',
        when: 'monitor.yml を変えた後に。通知を送らずに検知結果だけを表示する',
        user: 'root',
        build: fixed('bash', 'monitor.sh', '--dry-run'),
      },
      {
        label: '通知テスト',
        when: 'Webhook の設定を確認したいときに。テスト通知を 1 件送る',
        user: 'root',
        build: fixed('bash', 'monitor.sh', '--test-notify'),
      },
      {
        label: '監視タイマーを配置',
        when: '初回に。monitor.sh を定期実行する systemd timer と logrotate を配置する',
        user: 'root',
        build: fixed('bash', 'install-monitor.sh'),
      },
    ],
  },
  {
    label: '初期構築',
    when: '新しい VPS のセットアップ',
    items: [
      {
        label: 'サーバー初回セットアップ',
        when: '新しい VPS で最初に (SETUP_USERS.md の後)。Nginx・PHP・Node.js/PM2・MariaDB 等を入れる。再実行しても安全',
        user: 'root',
        build: fixed('bash', 'setup.sh'),
      },
    ],
  },
];
