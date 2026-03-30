import { run, SCRIPT_DIR } from '../lib/shell';

export async function add(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco add <domain>');
    console.log('       cobaco add --all');
    console.log('       cobaco add --dry-run <domain>');
    console.log('');
    console.log('Add a domain and generate Nginx config. Requires sudo.');
    console.log('');
    console.log('Options:');
    console.log('  --all        Apply all domains defined in domains.yml');
    console.log('  --dry-run    Validate and preview without making changes');
    return;
  }

  if (!args.includes('--all') && !args.find(a => !a.startsWith('-'))) {
    console.error('Error: domain name is required.');
    console.error('Usage: cobaco add <domain> | --all');
    process.exit(1);
  }

  await run(['sudo', 'bash', `${SCRIPT_DIR}/add-domain.sh`, ...args]);
}
