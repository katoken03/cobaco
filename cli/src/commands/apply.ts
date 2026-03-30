import { run, SCRIPT_DIR } from '../lib/shell';

export async function apply(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco apply <domain>');
    console.log('       cobaco apply --all');
    console.log('       cobaco apply --dry-run <domain>');
    console.log('');
    console.log('Apply domain config defined in domains.yml (Nginx, SSL, docroot).');
    console.log('Requires sudo.');
    console.log('');
    console.log('Options:');
    console.log('  --all        Apply all domains defined in domains.yml');
    console.log('  --dry-run    Validate and preview without making changes');
    return;
  }

  if (!args.includes('--all') && !args.find(a => !a.startsWith('-'))) {
    console.error('Error: domain name is required.');
    console.error('Usage: cobaco apply <domain> | --all');
    process.exit(1);
  }

  await run(['sudo', 'bash', `${SCRIPT_DIR}/add-domain.sh`, ...args]);
}
