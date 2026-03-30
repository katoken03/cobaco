import { run, SCRIPT_DIR } from '../lib/shell';

export async function deploy(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco deploy <domain>');
    console.log('       cobaco deploy --all');
    console.log('       cobaco deploy --branch <branch> <domain>');
    console.log('');
    console.log('Deploy a domain (git pull + build + restart).');
    console.log('Run as the deploy user (no sudo required).');
    console.log('');
    console.log('Options:');
    console.log('  --all              Deploy all domains defined in domains.yml');
    console.log('  --branch <branch>  Branch to deploy (default: main)');
    return;
  }

  if (!args.includes('--all') && !args.find(a => !a.startsWith('-'))) {
    console.error('Error: domain name is required.');
    console.error('Usage: cobaco deploy <domain> | --all');
    process.exit(1);
  }

  await run(['bash', `${SCRIPT_DIR}/deploy.sh`, ...args]);
}
