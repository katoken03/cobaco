import { existsSync } from 'fs';
import { dirname, join, resolve } from 'node:path';

function resolveScriptDir(): string {
  const fromBinary = resolve(dirname(process.argv[0]), '..');
  const fromSource = resolve(import.meta.dir, '../../..');
  if (existsSync(join(fromBinary, 'add-domain.sh'))) return fromBinary;
  if (existsSync(join(fromSource, 'add-domain.sh'))) return fromSource;
  return fromBinary;
}

// cobaco リポジトリ直下 (add-domain.sh 等と同じディレクトリ)
export const SCRIPT_DIR = resolveScriptDir();

const COBACO_SYSTEM_DOMAINS = '/root/cobaco_config/domains.yml';

export type ResolveDomainsFileResult =
  | { ok: true; path: string; ignoredLocal?: boolean }
  | { ok: false; systemPath: string; localPath: string; samplePath: string };

export function resolveDomainsFile(): ResolveDomainsFileResult {
  const localPath = join(SCRIPT_DIR, 'domains.yml');
  const samplePath = join(SCRIPT_DIR, 'domains.yml.sample');

  if (existsSync(COBACO_SYSTEM_DOMAINS)) {
    return {
      ok: true,
      path: COBACO_SYSTEM_DOMAINS,
      ignoredLocal: existsSync(localPath),
    };
  }
  if (existsSync(localPath)) {
    return { ok: true, path: localPath };
  }
  return {
    ok: false,
    systemPath: COBACO_SYSTEM_DOMAINS,
    localPath,
    samplePath,
  };
}

export async function run(cmd: string[]): Promise<void> {
  const proc = Bun.spawn(cmd, {
    stdout: 'inherit',
    stderr: 'inherit',
    stdin: 'inherit',
  });
  const code = await proc.exited;
  if (code !== 0) process.exit(code);
}
