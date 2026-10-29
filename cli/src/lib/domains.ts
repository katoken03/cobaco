import { chmodSync, copyFileSync, readFileSync, renameSync, statSync, writeFileSync } from 'fs';
import { parse, stringify } from 'yaml';
import { resolveDomainsFile } from './shell';

export type Domain = {
  name: string;
  type: 'php' | 'nodejs';
  php_version?: string;
  port?: number;
  pm2_name?: string;
  www_redirect?: boolean;
  ssl?: boolean;
  ssl_subdomains?: string[];
  path_info?: boolean;
  basic_auth?: {
    title: string;
    users: { id: string; password: string }[];
  };
};

export type LoadDomainsResult =
  | { ok: true; domains: Domain[] }
  | { ok: false; message: string };

export function loadDomains(): LoadDomainsResult {
  const resolved = resolveDomainsFile();
  if (!resolved.ok) {
    return {
      ok: false,
      message:
        `Error: domains.yml not found: ${resolved.systemPath}\n` +
        `Copy ${resolved.samplePath} and edit it.`,
    };
  }

  try {
    const content = readFileSync(resolved.path, 'utf8');
    const parsed = parse(content) as { domains?: Domain[] } | null;
    return { ok: true, domains: parsed?.domains ?? [] };
  } catch (e) {
    return {
      ok: false,
      message: `Error: cannot read ${resolved.path}: ${(e as Error).message}`,
    };
  }
}

export type AppendDomainResult =
  | { ok: true; path: string; backupPath: string }
  | { ok: false; message: string };

// 新しいエントリを YAML の配列要素として返す (プレビューと追記で同じものを使う)
export function domainEntryYaml(entry: Domain, indent = '  '): string {
  return stringify([entry])
    .trimEnd()
    .split('\n')
    .map(line => indent + line)
    .join('\n');
}

// domains.yml の末尾にテキストとして追記する (コメントや書式は書き換えない)
export function appendDomain(entry: Domain): AppendDomainResult {
  const resolved = resolveDomainsFile();
  if (!resolved.ok) {
    return { ok: false, message: `domains.yml が見つかりません: ${resolved.systemPath}` };
  }
  const path = resolved.path;
  const content = readFileSync(path, 'utf8');
  const before = (parse(content) as { domains?: Domain[] } | null)?.domains ?? [];

  // 既存エントリと同じ字下げにそろえる
  const indent = [...content.matchAll(/^( *)- name:/gm)].at(-1)?.[1] ?? '  ';
  const next = `${content.trimEnd()}\n\n${domainEntryYaml(entry, indent)}\n`;

  let after: Domain[] = [];
  try {
    after = (parse(next) as { domains?: Domain[] } | null)?.domains ?? [];
  } catch {
    // 下で失敗扱いにする
  }
  const unchanged = JSON.stringify(after.slice(0, -1)) === JSON.stringify(before);
  if (!unchanged || after.length !== before.length + 1 || after.at(-1)?.name !== entry.name) {
    return {
      ok: false,
      message: 'domains.yml の末尾に追記できる形ではありません (domains: が最後のキーではない等)。手で追記してください。',
    };
  }

  // パスワードを含むので元のファイルと同じパーミッションにする
  const mode = statSync(path).mode & 0o777;
  const backupPath = `${path}.bak`;
  copyFileSync(path, backupPath);
  chmodSync(backupPath, mode);
  const tmpPath = `${path}.tmp-${process.pid}`;
  writeFileSync(tmpPath, next, { mode });
  chmodSync(tmpPath, mode);
  renameSync(tmpPath, path);
  return { ok: true, path, backupPath };
}
