import { loadDomains, type Domain } from '../lib/domains';

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
  { header: 'AUTH',     value: d => (d.basic_auth?.title ? 'yes' : 'no') },
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

  if (!printDomains()) process.exit(1);
}

// 一覧を表示する。domains.yml が読めなければ false
export function printDomains(): boolean {
  const loaded = loadDomains();
  if (!loaded.ok) {
    console.error(loaded.message);
    return false;
  }

  if (!loaded.domains.length) {
    console.log('No domains defined in domains.yml.');
    return true;
  }

  renderTable(loaded.domains);
  return true;
}
