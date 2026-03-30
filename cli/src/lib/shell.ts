import { dirname, resolve } from 'path';

// バイナリ自身のパスから親ディレクトリ (シェルスクリプト置き場) を解決する
export const SCRIPT_DIR = resolve(dirname(process.argv[0]), '..');

export async function run(cmd: string[]): Promise<void> {
  const proc = Bun.spawn(cmd, {
    stdout: 'inherit',
    stderr: 'inherit',
    stdin: 'inherit',
  });
  const code = await proc.exited;
  if (code !== 0) process.exit(code);
}
