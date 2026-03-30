import { run, SCRIPT_DIR } from '../lib/shell';

export async function setup(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco setup');
    console.log('');
    console.log('Run the initial VPS setup (Nginx, PHP, PM2, MariaDB, firewall).');
    console.log('Requires sudo.');
    return;
  }

  await run(['sudo', 'bash', `${SCRIPT_DIR}/setup.sh`]);
}
