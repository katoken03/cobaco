import { existsSync, readFileSync } from 'fs';
import { join } from 'path';
import { parse } from 'yaml';
import { SCRIPT_DIR } from '../lib/shell';

type Domain = {
  name: string;
  type: 'php' | 'nodejs';
  php_version?: string;
  port?: number;
  pm2_name?: string;
  www_redirect?: boolean;
  ssl?: boolean;
};

type Column = {
  header: string;
  value: (d: Domain) => string;
};

const COLUMNS: Column[] = [
  { header: 'DOMAIN',   value: d => d.name },
  { header: 'TYPE',     value: d => d.type },
  { header: 'VERSION',  value: d => d.php_version ?? '-' },
  { header: 'PORT',     value: d => d.port?.toString() ?? '-' },
  { header: 'PM2',      value: d => d.pm2_name ?? '-' },
  { header: 'SSL',      value: d => (d.ssl ? 'yes' : 'no') },
  { header: 'WWW',      value: d => (d.www_redirect ? 'yes' : 'no') },
];

function renderTable(domains: Domain[]): void {
  const widths = COLUMNS.map(col =>
    Math.max(col.header.length, ...domains.map(d => col.value(d).length))
  );

  const row = (cells: string[]) =>
    cells.map((c, i) => c.padEnd(widths[i])).join('   ');

  const separator = widths.map(w => '─'.repeat(w)).join('───');

  console.log(row(COLUMNS.map(c => c.header)));
  console.log(separator);
  for (const domain of domains) {
    console.log(row(COLUMNS.map(c => c.value(domain))));
  }
}

export async function list(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco list');
    console.log('');
    console.log('List all domains defined in domains.yml.');
    return;
  }

  const domainsPath = join(SCRIPT_DIR, 'domains.yml');

  if (!existsSync(domainsPath)) {
    console.error(`Error: domains.yml not found at ${domainsPath}`);
    console.error('Copy domains.yml.sample to domains.yml and edit it.');
    process.exit(1);
  }

  const content = readFileSync(domainsPath, 'utf8');
  const parsed = parse(content) as { domains: Domain[] };

  if (!parsed?.domains?.length) {
    console.log('No domains defined in domains.yml.');
    return;
  }

  renderTable(parsed.domains);
}
