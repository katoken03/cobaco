import { confirm, input, select } from '@inquirer/prompts';
import { existsSync, readdirSync, readFileSync } from 'fs';
import { promises as dns } from 'node:dns';
import { hostname, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { appendDomain, domainEntryYaml, loadDomains, type Domain } from '../lib/domains';
import { SCRIPT_DIR } from '../lib/shell';
import { BLUE, DIM, GREEN, NC, pause, RED, runCommand, YELLOW } from './exec';
import { askText, numbered } from './inputs';

const COBACO_HOME = '/home/cobaco';
const COBACO_SSH_KEY = `${COBACO_HOME}/.ssh/id_ed25519`;
const FALLBACK_PHP_VERSIONS = ['8.5', '8.3', '8.2', '7.4', '7.3'];
const FQDN = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$/;

type StepStatus = '完了' | 'スキップ' | '失敗';
type StepResult = { title: string; status: StepStatus; note?: string };

class Abort extends Error {}

const STEPS = [
  'ドメインの情報を入力して domains.yml に追記',
  'ドメイン設定を適用 (add-domain.sh: dry-run → 本番)',
  'PHP-FPM の起動確認 (php のみ)',
  'アプリのリポジトリを取得 (git)',
  '初回デプロイ (deploy.sh)',
];

// ─────────────────────────────────────────────
// 入力
// ─────────────────────────────────────────────

function installedPhpVersions(): string[] {
  try {
    const versions = readdirSync('/etc/php').filter(v => existsSync(`/etc/php/${v}/fpm`));
    if (versions.length) return versions.sort((a, b) => Number(b) - Number(a));
  } catch {
    // /etc/php がない (開発環境など)
  }
  return FALLBACK_PHP_VERSIONS;
}

function usedHosts(domains: Domain[]): Set<string> {
  return new Set(domains.flatMap(d => [d.name, ...(d.ssl_subdomains ?? [])]));
}

async function askDomainName(domains: Domain[]): Promise<string> {
  const used = usedHosts(domains);
  const name = await input({
    message: 'ドメイン名 (例: example.com)',
    transformer: v => v.trim().toLowerCase(),
    validate: v => {
      const n = v.trim().toLowerCase();
      if (!FQDN.test(n)) return 'ドメイン名の形式が正しくありません';
      if (used.has(n)) return `${n} は domains.yml に既にあります`;
      return true;
    },
  });
  return name.trim().toLowerCase();
}

async function askNodejs(name: string, domains: Domain[]): Promise<{ port: number; pm2_name: string }> {
  const ports = new Set(domains.map(d => d.port).filter((p): p is number => typeof p === 'number'));
  const defaultPort = ports.size ? Math.max(...ports) + 1 : 3000;
  const port = await input({
    message: 'アプリのリッスンポート',
    default: String(defaultPort),
    validate: v => {
      const p = Number(v);
      if (!Number.isInteger(p) || p < 1024 || p > 65535) return '1024〜65535 の数値で指定してください';
      if (ports.has(p)) return `${p} は他のドメインで使っています`;
      return true;
    },
  });

  const pm2Names = new Set(domains.map(d => d.pm2_name).filter(Boolean));
  const pm2Name = await input({
    message: 'PM2 プロセス名',
    default: name.replace(/\./g, '-'),
    validate: v => {
      if (!/^[A-Za-z0-9._-]+$/.test(v.trim())) return '英数字と . _ - で指定してください';
      if (pm2Names.has(v.trim())) return `${v.trim()} は他のドメインで使っています`;
      return true;
    },
  });
  return { port: Number(port), pm2_name: pm2Name.trim() };
}

// ─────────────────────────────────────────────
// DNS
// ─────────────────────────────────────────────

function isPrivateAddress(addr: string): boolean {
  return (
    /^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)/.test(addr) ||
    /^(::1$|fe80:|fc|fd)/i.test(addr)
  );
}

function serverAddresses(): Set<string> {
  const addrs = Object.values(networkInterfaces())
    .flat()
    .filter(a => a && !a.internal && !isPrivateAddress(a.address))
    .map(a => a!.address.toLowerCase());
  return new Set(addrs);
}

async function lookup(host: string): Promise<string[]> {
  const [v4, v6] = await Promise.all([
    dns.resolve4(host).catch(() => [] as string[]),
    dns.resolve6(host).catch(() => [] as string[]),
  ]);
  return [...v4, ...v6].map(a => a.toLowerCase());
}

// すべての名前の A / AAAA がこのサーバーを向いていれば true
async function checkDns(hosts: string[]): Promise<boolean> {
  const server = serverAddresses();
  console.log('');
  console.log(`このサーバーの IP: ${server.size ? [...server].join(', ') : '(判定できません)'}`);

  let allOk = true;
  for (const host of hosts) {
    const addrs = await lookup(host);
    if (!addrs.length) {
      console.log(`  ${RED}✗${NC} ${host}: 名前解決できません`);
      allOk = false;
      continue;
    }
    const ok = server.size > 0 && addrs.every(a => server.has(a));
    console.log(`  ${ok ? `${GREEN}✓` : `${YELLOW}!`}${NC} ${host}: ${addrs.join(', ')}`);
    if (!ok) allOk = false;
  }
  if (!allOk) {
    console.log(`${YELLOW}DNS がこのサーバーを向いていません。ssl: true だと Let's Encrypt の取得に失敗します。${NC}`);
  }
  return allOk;
}

// ─────────────────────────────────────────────
// ステップの進行
// ─────────────────────────────────────────────

async function stepHeader(index: number, detail?: string): Promise<boolean> {
  console.log('');
  console.log(`${BLUE}── ${index + 1}/${STEPS.length} ${STEPS[index]}${NC}`);
  if (detail) console.log(`${DIM}${detail}${NC}`);
  const picked = await select({
    message: 'このステップを',
    choices: numbered([
      { name: '実行する', value: 'run' },
      { name: 'スキップする', value: 'skip' },
      { name: '中断する', value: 'abort' },
    ]),
  });
  if (picked === 'abort') throw new Abort();
  return picked === 'run';
}

// コマンドを順に実行する。1 つでも失敗したら false
async function runAll(cmds: string[][]): Promise<boolean> {
  for (const cmd of cmds) {
    if ((await runCommand(cmd, { confirm: false })) !== 0) return false;
  }
  return true;
}

async function stepDomainsYml(domains: Domain[]): Promise<Domain> {
  const name = await askDomainName(domains);
  const type = await select<'php' | 'nodejs'>({
    message: '種類',
    choices: numbered<'php' | 'nodejs'>([
      { name: 'PHP', value: 'php', description: 'PHP-FPM で動かす (WordPress / Laravel など)' },
      { name: 'Node.js', value: 'nodejs', description: 'PM2 で動かし、Nginx からリバースプロキシする (Next.js など)' },
    ]),
  });

  const entry: Domain = { name, type };
  if (type === 'php') {
    entry.php_version = await select({
      message: 'PHP バージョン',
      choices: numbered(installedPhpVersions().map(v => ({ name: v, value: v }))),
    });
  } else {
    Object.assign(entry, await askNodejs(name, domains));
  }

  entry.www_redirect = await confirm({ message: `www.${name} でも受け付けますか?`, default: false });

  const hosts = entry.www_redirect ? [name, `www.${name}`] : [name];
  const dnsOk = await checkDns(hosts);
  entry.ssl = await confirm({
    message: "SSL (Let's Encrypt) を有効にしますか?",
    default: dnsOk,
  });
  if (entry.ssl && entry.www_redirect) entry.ssl_subdomains = [`www.${name}`];

  console.log('');
  console.log('domains.yml に次を追記します:');
  console.log(domainEntryYaml(entry));
  if (!(await confirm({ message: '追記しますか?', default: true }))) throw new Abort();

  const result = appendDomain(entry);
  if (!result.ok) {
    console.log(`${RED}[ERROR]${NC} ${result.message}`);
    throw new Abort();
  }
  console.log(`${GREEN}[OK]${NC}   ${result.path} に追記しました (変更前: ${result.backupPath})`);
  return entry;
}

async function stepAddDomain(entry: Domain): Promise<StepResult> {
  const title = STEPS[1];
  if (!(await stepHeader(1, 'Nginx 設定・ドキュメントルート・SSL・PHP-FPM プール・DB を作る'))) {
    return { title, status: 'スキップ' };
  }

  if ((await runCommand(['bash', 'add-domain.sh', '--dry-run', entry.name], { confirm: false })) !== 0) {
    return { title, status: '失敗', note: 'dry-run でエラー。domains.yml を直してから「ドメイン設定を適用」で再実行' };
  }
  const code = await runCommand(['bash', 'add-domain.sh', entry.name], {
    message: 'dry-run は成功しました。本番実行しますか?',
  });
  if (code === 'skipped') return { title, status: 'スキップ', note: 'dry-run のみ実行' };
  if (code !== 0) return { title, status: '失敗', note: '出力を確認し「ドメイン設定を適用」で再実行' };
  return { title, status: '完了' };
}

async function stepPhpFpm(entry: Domain): Promise<StepResult> {
  const title = STEPS[2];
  if (entry.type !== 'php') return { title, status: 'スキップ', note: 'Node.js のため不要' };

  const service = `php${entry.php_version}-fpm`;
  const active = Bun.spawnSync(['systemctl', 'is-active', '--quiet', service]).exitCode === 0;
  if (active) {
    console.log('');
    console.log(`${BLUE}── 3/${STEPS.length} ${title}${NC}`);
    console.log(`${GREEN}[OK]${NC}   ${service} は起動しています`);
    return { title, status: 'スキップ', note: `${service} は起動済み` };
  }

  if (!(await stepHeader(2, `${service} が止まっています。apply-php-fpm-services.sh で起動する`))) {
    return { title, status: 'スキップ' };
  }
  const ok = await runAll([['bash', 'apply-php-fpm-services.sh']]);
  return { title, status: ok ? '完了' : '失敗' };
}

async function ensureSshKey(): Promise<void> {
  if (!existsSync(COBACO_SSH_KEY)) {
    const create = await confirm({
      message: `cobaco の SSH 鍵 (${COBACO_SSH_KEY}) がありません。作成しますか?`,
      default: true,
    });
    if (!create) return;
    const ok = await runAll([
      ['sudo', '-u', 'cobaco', 'ssh-keygen', '-t', 'ed25519', '-N', '', '-C', `cobaco@${hostname()}`, '-f', COBACO_SSH_KEY],
    ]);
    if (!ok) return;
  }

  console.log('');
  console.log('この公開鍵をリポジトリの Deploy key (読み取り専用) に登録してください:');
  console.log('');
  console.log(readFileSync(`${COBACO_SSH_KEY}.pub`, 'utf8').trim());
  console.log('');
  await pause('登録したら Enter');
}

async function stepGit(entry: Domain): Promise<{ result: StepResult; branch: string }> {
  const title = STEPS[3];
  const webroot = `/var/www/${entry.name}`;

  if (existsSync(join(webroot, '.git'))) {
    console.log('');
    console.log(`${GREEN}[OK]${NC}   ${webroot} は既に Git リポジトリです`);
    return { result: { title, status: 'スキップ', note: '取得済み' }, branch: 'main' };
  }
  if (!(await stepHeader(3, `${webroot} に cobaco ユーザーでリポジトリを取得する (git init → fetch → checkout)`))) {
    return { result: { title, status: 'スキップ', note: '後で git で取得' }, branch: 'main' };
  }
  if (!existsSync(webroot)) {
    console.log(`${RED}[ERROR]${NC} ${webroot} がありません。先に「ドメイン設定を適用」を実行してください。`);
    return { result: { title, status: '失敗', note: `${webroot} がない` }, branch: 'main' };
  }

  const url = await askText('リポジトリの URL (例: git@github.com:owner/repo.git)', { required: true });
  const branch = await askText('ブランチ', { default: 'main', required: true });
  if (/^(git@|ssh:\/\/)/.test(url)) await ensureSshKey();

  const git = ['sudo', '-u', 'cobaco', 'git', '-C', webroot];
  const ok = await runAll([
    [...git, 'init', '-b', branch],
    [...git, 'remote', 'add', 'origin', url],
    [...git, '-c', 'core.sshCommand=ssh -o StrictHostKeyChecking=accept-new', 'fetch', 'origin'],
    [...git, 'checkout', '-t', `origin/${branch}`],
  ]);
  return {
    result: ok
      ? { title, status: '完了' }
      : { title, status: '失敗', note: `${webroot}/.git を確認 (やり直すなら rm -rf ${webroot}/.git)` },
    branch,
  };
}

async function stepDeploy(entry: Domain, branch: string): Promise<StepResult> {
  const title = STEPS[4];
  if (!existsSync(`/var/www/${entry.name}/.git`)) {
    return { title, status: 'スキップ', note: 'リポジトリ取得後に「デプロイ」(cobaco ユーザー) で実行' };
  }
  if (!(await stepHeader(4, 'cobaco ユーザーで git pull・ビルド・再起動を行う'))) {
    return { title, status: 'スキップ', note: '後で「デプロイ」(cobaco ユーザー) で実行' };
  }
  const branchArgs = branch === 'main' ? [] : ['--branch', branch];
  const ok = await runAll([
    ['sudo', '-u', 'cobaco', '-i', 'bash', join(SCRIPT_DIR, 'deploy.sh'), ...branchArgs, entry.name],
  ]);
  return { title, status: ok ? '完了' : '失敗' };
}

function printSummary(entry: Domain | null, results: StepResult[]): void {
  const color = { 完了: GREEN, スキップ: YELLOW, 失敗: RED } as const;
  console.log('');
  console.log(`${BLUE}── まとめ${entry ? `: ${entry.name}` : ''}${NC}`);
  for (const r of results) {
    console.log(`  ${color[r.status]}${r.status}${NC}  ${r.title}${r.note ? `${DIM} — ${r.note}${NC}` : ''}`);
  }
  if (!entry) return;

  console.log('');
  console.log('この後必要に応じて:');
  console.log('  - DB・ベーシック認証・php_settings・path_info は domains.yml を編集してから「ドメイン設定を適用」');
  if (!entry.ssl) {
    console.log('  - DNS を設定したら domains.yml の ssl を true にして「ドメイン設定を適用」');
  }
}

export async function addDomainWizard(): Promise<void> {
  const loaded = loadDomains();
  if (!loaded.ok) {
    console.error(loaded.message);
    return;
  }

  console.log('');
  console.log('新しいドメインを次の順に追加します (各ステップはスキップ・中断できます):');
  STEPS.forEach((s, i) => console.log(`  ${i + 1}. ${s}`));
  console.log('');

  let entry: Domain | null = null;
  const results: StepResult[] = [];
  try {
    entry = await stepDomainsYml(loaded.domains);
    results.push({ title: STEPS[0], status: '完了' });

    const added = await stepAddDomain(entry);
    results.push(added);
    if (added.status !== '完了') throw new Abort();

    results.push(await stepPhpFpm(entry));
    const git = await stepGit(entry);
    results.push(git.result);
    results.push(await stepDeploy(entry, git.branch));
  } catch (e) {
    if (!(e instanceof Abort)) throw e;
    console.log('');
    console.log(`${YELLOW}中断しました。${NC}`);
  }
  printSummary(entry, results);
}
