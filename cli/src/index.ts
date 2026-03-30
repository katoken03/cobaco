import { setup } from './commands/setup';
import { add } from './commands/add';
import { deploy } from './commands/deploy';

function printHelp(): void {
  console.log('cobaco <command> [options]');
  console.log('');
  console.log('Commands:');
  console.log('  setup               Run initial VPS setup');
  console.log('  add <domain>        Add a domain and generate Nginx config');
  console.log('  deploy <domain>     Deploy a domain (git pull + build + restart)');
  console.log('');
  console.log('Options:');
  console.log('  --all               Target all domains (add / deploy)');
  console.log('  --dry-run           Validate only, no changes (add)');
  console.log('  --branch <branch>   Branch to deploy (deploy, default: main)');
  console.log('  -h, --help          Show help');
  console.log('');
  console.log('Examples:');
  console.log('  cobaco setup');
  console.log('  cobaco add example.com');
  console.log('  cobaco add --dry-run example.com');
  console.log('  cobaco add --all');
  console.log('  cobaco deploy example.com');
  console.log('  cobaco deploy --branch develop example.com');
}

const [,, subcommand, ...args] = process.argv;

if (!subcommand || subcommand === '-h' || subcommand === '--help') {
  printHelp();
  process.exit(0);
}

switch (subcommand) {
  case 'setup':
    await setup(args);
    break;
  case 'add':
    await add(args);
    break;
  case 'deploy':
    await deploy(args);
    break;
  default:
    console.error(`Error: unknown command '${subcommand}'`);
    console.error('');
    printHelp();
    process.exit(1);
}
