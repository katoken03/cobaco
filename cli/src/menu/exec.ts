import { confirm, input } from '@inquirer/prompts';
import { run, SCRIPT_DIR } from '../lib/shell';

export const RED = '\x1b[0;31m';
export const YELLOW = '\x1b[1;33m';
export const GREEN = '\x1b[0;32m';
export const BLUE = '\x1b[0;34m';
export const DIM = '\x1b[2m';
export const NC = '\x1b[0m';

// 表示用。空白や記号を含む引数だけクォートする
export function shellQuote(args: string[]): string {
  return args
    .map(a => (/^[\w@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`))
    .join(' ');
}

export async function pause(message = 'Enter でメニューに戻る'): Promise<void> {
  await input({ message, theme: { prefix: '' } });
}

// コマンドを表示して確認してから実行する (confirm: false なら確認しない)。終了コード、実行しなければ 'skipped'
export async function runCommand(
  cmd: string[],
  options: { message?: string; confirm?: boolean } = {},
): Promise<number | 'skipped'> {
  console.log('');
  console.log(`${DIM}# ${SCRIPT_DIR} で実行${NC}`);
  console.log(`${BLUE}$ ${shellQuote(cmd)}${NC}`);
  if (options.confirm !== false && !(await confirm({ message: options.message ?? '実行しますか?', default: true }))) {
    return 'skipped';
  }

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
  return code;
}
