import { existsSync, realpathSync } from 'fs';
import { dirname, join, resolve } from 'node:path';

function resolveScriptDir(): string {
  // コンパイル済みバイナリ: <repo>/cli/cobaco (/usr/local/bin/cobaco はそのシンボリックリンク)
  const fromBinary = resolve(dirname(realpathSync(process.execPath)), '..');
  const fromSource = resolve(import.meta.dir, '../../..');
  if (existsSync(join(fromBinary, 'add-domain.sh'))) return fromBinary;
  if (existsSync(join(fromSource, 'add-domain.sh'))) return fromSource;
  return fromBinary;
}

// cobaco リポジトリ直下 (add-domain.sh 等と同じディレクトリ)
export const SCRIPT_DIR = resolveScriptDir();

const COBACO_SYSTEM_DOMAINS = '/root/cobaco_config/domains.yml';

export type ResolveDomainsFileResult =
  | { ok: true; path: string }
  | { ok: false; systemPath: string; samplePath: string };

export function resolveDomainsFile(): ResolveDomainsFileResult {
  const samplePath = join(SCRIPT_DIR, 'domains.yml.sample');
  // 開発用: 手元の domains.yml を読ませる
  const systemPath = process.env.COBACO_DOMAINS || COBACO_SYSTEM_DOMAINS;

  if (existsSync(systemPath)) {
    return { ok: true, path: systemPath };
  }
  return {
    ok: false,
    systemPath,
    samplePath,
  };
}

export function isRoot(): boolean {
  return process.getuid?.() === 0;
}

// メニューの root 項目を表示するか (COBACO_AS_ROOT=1 は開発時の表示確認用。各スクリプトも root を確認する)
export function showRootItems(): boolean {
  return isRoot() || process.env.COBACO_AS_ROOT === '1';
}

// 終了コードを返す (メニューから使う)
export async function run(cmd: string[]): Promise<number> {
  const proc = Bun.spawn(cmd, {
    cwd: SCRIPT_DIR,
    stdout: 'inherit',
    stderr: 'inherit',
    stdin: 'inherit',
  });
  return await proc.exited;
}

// 失敗したらその終了コードで終了する (サブコマンドから使う)
export async function runOrExit(cmd: string[]): Promise<void> {
  const code = await run(cmd);
  if (code !== 0) process.exit(code);
}
