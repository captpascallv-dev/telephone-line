// SPDX-License-Identifier: MPL-2.0
import { loadDsh } from './resolve-modules.mjs';

const cmdline = await loadDsh('@deepseek-ai/dsh-cmdline');
const commander = await loadDsh('commander', 'index.js');
const { parseCmdline } = cmdline;
const { Command } = commander;

export const name = 'telephone-line-headless-startup';
export const inject = ['cmdlineArgs'];
export const HEADLESS_STARTUP_SERVICE = 'headlessStartup';

function headlessCommand() {
  return new Command()
    .name('dsh --profile headless')
    .description('Answer one task through DSH, optionally resuming an exact native session, then exit.')
    .helpOption('-h, --help', 'show this help')
    .option('--resume <sessionId>', 'resume this exact native DSH session id')
    .option('--session-out <path>', 'write the native session id to this file')
    .argument('[task...]', 'the task text; multiple words are joined by spaces');
}

export function apply(ctx) {
  const program = headlessCommand();
  program.action(() => {
    const options = program.opts();
    const task = program.args.join(' ');
    if (task.trim() === '') {
      program.error('error: a task is required, for example: dsh --profile headless "run the tests"');
    }
    ctx.provide(HEADLESS_STARTUP_SERVICE, {
      task,
      resumeSessionId: String(options.resume || ''),
      sessionOut: String(options.sessionOut || ''),
    });
  });
  parseCmdline(ctx, program);
}
