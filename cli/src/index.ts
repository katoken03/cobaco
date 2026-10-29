import { setup } from './commands/setup';
import { apply } from './commands/apply';
import { deploy } from './commands/deploy';
import { list } from './commands/list';
import { runMenu } from './menu';

function printHelp(): void {
  console.log('cobaco <command> [options]');
  console.log('');
  console.log('Commands:');
  console.log('  (none) / menu         Interactive menu (arrow keys or numbers + Enter)');
  console.log('  setup                 Run initial VPS setup');
  console.log('  list                  List all domains defined in domains.yml');
  console.log('  apply <domain>        Apply domain config defined in domains.yml');
  console.log('  deploy <domain>       Deploy a domain (git pull + build + restart)');
  console.log('');
  console.log('Options:');
  console.log('  --all                 Target all domains (apply / deploy)');
  console.log('  --dry-run             Validate only, no changes (apply)');
  console.log('  --branch <branch>     Branch to deploy (deploy, default: main)');
  console.log('  -h, --help            Show help');
  console.log('');
  console.log('Examples:');
  console.log('  cobaco');
  console.log('  cobaco setup');
  console.log('  cobaco apply example.com');
  console.log('  cobaco apply --dry-run example.com');
  console.log('  cobaco apply --all');
  console.log('  cobaco deploy example.com');
  console.log('  cobaco deploy --branch develop example.com');
}

const [,, subcommand, ...args] = process.argv;

if (!subcommand && process.stdin.isTTY && process.stdout.isTTY) {
  await runMenu();
  process.exit(0);
}

if (!subcommand || subcommand === '-h' || subcommand === '--help') {
  printHelp();
  process.exit(0);
}

switch (subcommand) {
  case 'menu':
    await runMenu();
    break;
  case 'setup':
    await setup(args);
    break;
  case 'list':
    await list(args);
    break;
  case 'apply':
    await apply(args);
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
