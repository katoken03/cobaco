import { select } from '@inquirer/prompts';
import { showRootItems } from '../lib/shell';
import { CATALOG, type MenuGroup, type MenuItem } from './catalog';
import { DIM, NC, pause, runCommand } from './exec';
import { numbered } from './inputs';

const EXIT = Symbol('exit');
const BACK = Symbol('back');

function visibleItems(group: MenuGroup, root: boolean): MenuItem[] {
  return group.items.filter(item =>
    item.user === 'any' || (item.user === 'root') === root
  );
}

async function runItem(item: MenuItem): Promise<void> {
  if (item.action) {
    await item.action();
    await pause();
    return;
  }

  const cmd = await item.build!();
  if (!cmd) return;
  if ((await runCommand(cmd)) !== 'skipped') await pause();
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
  const root = showRootItems();
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
