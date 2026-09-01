// SPDX-License-Identifier: MPL-2.0
import { randomUUID } from 'node:crypto';
import { writeFileSync } from 'node:fs';
import { loadDsh } from './resolve-modules.mjs';

const schemastery = await loadDsh('@deepseek-ai/schemastery', 'lib/index.mjs');
const z = schemastery.default || schemastery;
const agentMod = await loadDsh('@deepseek-ai/dsh-agent');
const llm = await loadDsh('@deepseek-ai/dsh-llm');
const sessionMod = await loadDsh('@deepseek-ai/dsh-session');
const { installModelSelection } = agentMod;
const { createUserMessage } = llm;
const { SessionId } = sessionMod;

export const name = 'telephone-line-headless-runner';
export const inject = ['agentDefaultModel', 'agents', 'sessions', 'sessionPersistence'];
export const Config = z.object({
  task: z.string().required(),
  resumeSessionId: z.string().default(''),
  sessionOut: z.string().default(''),
  reasoningEffort: z.string().default(''),
});

export const internals = {
  stdout: process.stdout,
  stderr: process.stderr,
};

function summarize(events, firstSeq) {
  let started = false;
  let text = '';
  let reason;
  let toolCalls = 0;
  for (const event of events) {
    if (event.seq < firstSeq) continue;
    if (event.type === 'turn/start') {
      started = true;
      continue;
    }
    if (!started) continue;
    if (event.type === 'assistant/message') {
      const joined = event.data.message.content
        .filter((block) => block.type === 'text')
        .map((block) => block.text)
        .join('');
      if (joined !== '') text = joined;
      toolCalls += (event.data.message.content || []).filter((block) => block.type === 'tool-call').length;
    }
    if (event.type === 'turn/end') reason = event.data.reason;
  }
  return { text, reason, toolCalls };
}

function fail(io, error) {
  io.stderr.write(`dsh: ${error instanceof Error ? error.message : String(error)}\n`);
  io.exit(1);
}

function writeSessionOut(path, sessionId, selection) {
  if (!path) return;
  writeFileSync(path, `${JSON.stringify({
    protocol_version: 'telephone-line-dsh-session-v1',
    native_session_id: sessionId,
    provider: selection.provider,
    model: selection.model,
    loop_owner: 'dsh',
  })}\n`, { encoding: 'utf8' });
}

async function run(ctx, config, io) {
  await ctx.get('loader')?.await();
  const agents = ctx.get('agents');
  const defaultModel = ctx.get('agentDefaultModel');
  const sessions = ctx.get('sessions');
  if (agents === undefined || defaultModel === undefined || sessions === undefined) return;
  const baseSelection = defaultModel.currentSelection();
  const effort = String(config.reasoningEffort || '').trim();
  const selection = {
    ...baseSelection,
    ...(effort === '' ? {} : { reasoningEffort: effort }),
  };
  const resumeId = String(config.resumeSessionId || '').trim();
  const sessionId = resumeId ? SessionId(resumeId) : SessionId(`session-${randomUUID()}`);
  const agentOptions = {
    provider: selection.provider,
    model: selection.model,
    ...(effort === '' ? {} : { reasoningEffort: effort }),
  };
  const setup = (agentCtx) => {
    installModelSelection(agentCtx, {
      current: selection,
      assembled: undefined,
    });
  };
  const handle = resumeId
    ? await agents.resume({
      resumeSessionId: sessionId,
      agentOptions,
      setup,
    })
    : await agents.create({
      sessionId,
      meta: { cwd: process.cwd() },
      agentOptions,
      setup,
    });
  const { agent } = handle;
  const native = String(agent.session.id);
  writeSessionOut(config.sessionOut, native, selection);
  io.stderr.write(`telephone-line-dsh-session:${native}\n`);
  io.stderr.write('telephone-line-dsh-loop-owner:dsh\n');
  io.stderr.write(`telephone-line-dsh-provider:${selection.provider}\n`);
  io.stderr.write(`telephone-line-dsh-model:${selection.model}\n`);
  if (effort !== '') {
    io.stderr.write(`telephone-line-dsh-reasoning-effort:${effort}\n`);
  }
  io.stderr.write('telephone-line-dsh-child-harness:false\n');
  await agent.whenIdle();
  const firstSeq = agent.session.seq;
  agent.followup(createUserMessage({
    content: [{ type: 'text', text: config.task }],
    source: { kind: 'user' },
  }));
  await agent.whenIdle();
  await sessions.flush(agent.session);
  const outcome = summarize(agent.session.events, firstSeq);
  io.stdout.write(`${outcome.text}\n`);
  if (outcome.reason?.kind === 'error') {
    io.stderr.write('dsh: ERROR: turn error\n');
  }
  io.exit(outcome.reason?.kind === 'completed' ? 0 : 1);
}

export function apply(ctx, config) {
  const exit = ctx.get('appExit');
  if (exit === undefined) throw new Error('headless-runner: the launcher must provide ctx.appExit before the tree mounts');
  const io = {
    stdout: internals.stdout,
    stderr: internals.stderr,
    exit,
  };
  run(ctx, config, io).catch((error) => fail(io, error));
}
