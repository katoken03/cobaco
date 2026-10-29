import { readFileSync } from 'fs';
import { parse } from 'yaml';
import { resolveDomainsFile } from './shell';

export type Domain = {
  name: string;
  type: 'php' | 'nodejs';
  php_version?: string;
  port?: number;
  pm2_name?: string;
  www_redirect?: boolean;
  ssl?: boolean;
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
