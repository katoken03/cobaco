import { input, select } from '@inquirer/prompts';
import { loadDomains } from '../lib/domains';

export const BACK = Symbol('back');

// 選択肢の頭に番号を付ける (数字キー + Enter でも選べる)
export function numbered<T>(choices: { name: string; value: T; description?: string }[]) {
  return choices.map((c, i) => ({ ...c, name: `${i + 1}. ${c.name}` }));
}

// domains.yml から対象ドメインを選ぶ。'--all' か ドメイン名、戻るなら null
export async function pickDomain(options: { allowAll?: boolean; type?: 'php' | 'nodejs' } = {}): Promise<string | null> {
  const loaded = loadDomains();
  if (!loaded.ok) {
    console.error(loaded.message);
    return null;
  }

  const domains = loaded.domains.filter(d => !options.type || d.type === options.type);
  if (!domains.length) {
    console.log('対象のドメインが domains.yml にありません。');
    return null;
  }

  const choices: { name: string; value: string | typeof BACK; description?: string }[] = [];
  if (options.allowAll ?? true) {
    choices.push({ name: '全ドメイン (--all)', value: '--all', description: 'domains.yml の全ドメインが対象' });
  }
  for (const d of domains) {
    const detail = d.type === 'php' ? `php ${d.php_version ?? '-'}` : `nodejs :${d.port ?? '-'}`;
    choices.push({ name: `${d.name}  (${detail})`, value: d.name });
  }
  choices.push({ name: '← 戻る', value: BACK });

  const picked = await select({ message: '対象ドメイン', choices: numbered(choices), pageSize: 15 });
  return picked === BACK ? null : picked;
}

// 本番実行か dry-run かを選ぶ。dry-run なら ['--dry-run']、戻るなら null
export async function pickDryRun(): Promise<string[] | null> {
  const picked = await select({
    message: '実行モード',
    choices: numbered([
      { name: 'dry-run (変更せず確認だけ)', value: 'dry', description: '--dry-run を付けて実行' },
      { name: '本番実行', value: 'run', description: '実際に設定を変更する' },
      { name: '← 戻る', value: 'back' },
    ]),
  });
  if (picked === 'back') return null;
  return picked === 'dry' ? ['--dry-run'] : [];
}

export async function askText(message: string, options: { default?: string; required?: boolean } = {}): Promise<string> {
  const value = await input({
    message,
    default: options.default,
    validate: v => !options.required || v.trim() !== '' || '入力してください',
  });
  return value.trim();
}
