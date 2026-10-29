import { runOrExit, SCRIPT_DIR } from '../lib/shell';

export async function setup(args: string[]): Promise<void> {
  if (args.includes('-h') || args.includes('--help')) {
    console.log('Usage: cobaco setup');
    console.log('');
    console.log('Run the initial VPS setup (Nginx, PHP, PM2, MariaDB, firewall).');
    console.log('Run as root.');
    return;
  }

  await runOrExit(['bash', `${SCRIPT_DIR}/setup.sh`]);
}
