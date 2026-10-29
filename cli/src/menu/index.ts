import { confirm, input, select } from '@inquirer/prompts';
import { isRoot, run, SCRIPT_DIR } from '../lib/shell';
import { CATALOG, type MenuGroup, type MenuItem } from './catalog';
import { numbered } from './inputs';

const RED = '\x1b[0;31m';
const GREEN = '\x1b[0;32m';
const BLUE = '\x1b[0;34m';
const DIM = '\x1b[2m';
const NC = '\x1b[0m';

const EXIT = Symbol('exit');
const BACK = Symbol('back');

function visibleItems(group: MenuGroup, root: boolean): MenuItem[] {
  return group.items.filter(item =>
    item.user === 'any' || (item.user === 'root') === root
  );
}

// 表示用。空白や記号を含む引数だけクォートする
function shellQuote(args: string[]): string {
  return args
    .map(a => (/^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`))
    .join(' ');
}

async function pause(): Promise<void> {
  await input({ message: 'Enter でメニューに戻る', theme: { prefix: '' } });
}

async function runItem(item: MenuItem): Promise<void> {
  if (item.action) {
    await item.action();
    await pause();
    return;
  }

  const cmd = await item.build!();
  if (!cmd) return;

  console.log('');
  console.log(`${DIM}# ${SCRIPT_DIR} で実行${NC}`);
  console.log(`${BLUE}$ ${shellQuote(cmd)}${NC}`);
  if (!(await confirm({ message: '実行しますか?', default: true }))) return;

  console.log('');
  // Ctrl+C はスクリプトだけを止め、メニューには戻る
  const ignore = () => {};
  process.on('SIGINT', ignore);
  const code = await run(cmd).finally(() => process.off('SIGINT', ignore));
  console.log('');
  if (code === 0) {
    console.log(`${GREEN}[OK]${NC}   完了しました`);
  } else {
    console.log(`${RED}[ERROR]${NC} 終了コード ${code}`);
  }
  await pause();
}

async function groupMenu(group: MenuGroup, items: MenuItem[]): Promise<void> {
  let last: MenuItem | undefined;
  while (true) {
    const picked = await select<MenuItem | typeof BACK>({
      message: group.label,
      choices: numbered<MenuItem | typeof BACK>([
        ...items.map(item => ({ name: item.label, value: item, description: item.when })),
        { name: '← 戻る', value: BACK },
      ]),
      default: last,
      pageSize: 15,
    });
    if (picked === BACK) return;
    last = picked;
    await runItem(picked);
  }
}

export async function menu(): Promise<void> {
  const root = isRoot();
  const groups = CATALOG
    .map(group => ({ group, items: visibleItems(group, root) }))
    .filter(g => g.items.length > 0);

  console.log(`cobaco メニュー (${root ? 'root' : 'cobaco'} で実行中)`);
  console.log(`${DIM}矢印キーまたは番号で選び Enter。Ctrl+C で終了${NC}`);
  if (!root) {
    console.log(`${DIM}サーバー設定の項目は root でログインすると表示されます${NC}`);
  }

  let last: (typeof groups)[number] | undefined;
  while (true) {
    const picked = await select<(typeof groups)[number] | typeof EXIT>({
      message: '何をしますか?',
      choices: numbered<(typeof groups)[number] | typeof EXIT>([
        ...groups.map(g => ({ name: g.group.label, value: g, description: g.group.when })),
        { name: '終了', value: EXIT },
      ]),
      default: last,
      pageSize: 15,
    });
    if (picked === EXIT) return;
    last = picked;
    await groupMenu(picked.group, picked.items);
  }
}

export async function runMenu(): Promise<void> {
  try {
    await menu();
  } catch (e) {
    // Ctrl+C
    if (e instanceof Error && e.name === 'ExitPromptError') return;
    throw e;
  }
}
