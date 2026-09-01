// SPDX-License-Identifier: MPL-2.0
import { loadDsh, loadPiAi } from './resolve-modules.mjs';
import { DshSubscriptionCredentialStore } from './subscription-store.mjs';

const llm = await loadDsh('@deepseek-ai/dsh-llm');
const pi = await loadPiAi('dist/index.js');
const openaiCodex = await loadPiAi('dist/providers/openai-codex.js');
const xai = await loadPiAi('dist/providers/xai.js');
const { LlmAdapter, LlmError, CallId, attributionHeaders, ReasoningEffortId } = llm;

const ROUTE_REASONING = {
  'openai-codex': {
    efforts: [
      { id: ReasoningEffortId('minimal'), name: 'Minimal' },
      { id: ReasoningEffortId('low'), name: 'Low' },
      { id: ReasoningEffortId('medium'), name: 'Medium' },
      { id: ReasoningEffortId('high'), name: 'High' },
      { id: ReasoningEffortId('xhigh'), name: 'Extra High' },
    ],
    defaultEffort: ReasoningEffortId('high'),
  },
  xai: {
    efforts: [
      { id: ReasoningEffortId('low'), name: 'Low' },
      { id: ReasoningEffortId('high'), name: 'High' },
      { id: ReasoningEffortId('xhigh'), name: 'Extra High' },
    ],
    defaultEffort: ReasoningEffortId('xhigh'),
  },
};

function libraryModelFor(models, route, modelId) {
  const found = models.getModel(route, modelId);
  if (found) return { ...found, id: modelId };
  const siblings = models.getModels(route) || [];
  const template = siblings.find((entry) => (
    entry.reasoning === true && entry.api !== 'openai-completions'
  )) || siblings.find((entry) => entry.reasoning === true) || siblings[0];
  if (!template) throw new LlmError('unknown model', 'UNKNOWN_MODEL');
  return {
    ...template,
    id: modelId,
    name: modelId,
    reasoning: true,
  };
}

function assertEffortReachable(model, effort) {
  if (!effort) return;
  if (model.api === 'openai-completions' && model.compat?.supportsReasoningEffort === false) {
    throw new LlmError('provider stream failed', 'UNSUPPORTED_OPTION');
  }
}
const { createModels } = pi;

function emptyUsage() {
  return {
    input: 0,
    output: 0,
    cacheRead: 0,
    cacheWrite: 0,
    totalTokens: 0,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
  };
}

function flattenText(message) {
  return (message.content || [])
    .filter((block) => block.type === 'text')
    .map((block) => block.text)
    .join('');
}

function toolResultText(blocks) {
  return (blocks || [])
    .map((block) => (
      block.type === 'text'
        ? block.text
        : block.type === 'tool-result'
          ? toolResultText(block.content)
          : ''
    ))
    .join('');
}

function parseArguments(raw) {
  if (raw == null || raw === '') return {};
  try {
    const value = JSON.parse(raw);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
  } catch {
    return {};
  }
}

function modelInputModalities(model) {
  return Array.isArray(model?.input) && model.input.length > 0 ? [...model.input] : ['text'];
}

function toLibraryAssistant(message) {
  const source = message.source?.kind === 'model' ? message.source : undefined;
  const content = [];
  for (const block of message.content || []) {
    if (block.type === 'text') content.push({ type: 'text', text: block.text });
    else if (block.type === 'reasoning') content.push({ type: 'thinking', thinking: block.text });
    else if (block.type === 'tool-call') {
      content.push({
        type: 'toolCall',
        id: block.id,
        name: block.name,
        arguments: parseArguments(block.arguments),
      });
    }
  }
  return {
    role: 'assistant',
    content,
    api: 'dsh-foreign',
    provider: source?.provider ?? 'dsh-foreign',
    model: source?.model ?? 'dsh-foreign',
    usage: emptyUsage(),
    stopReason: content.some((piece) => piece.type === 'toolCall') ? 'toolUse' : 'stop',
    timestamp: 0,
  };
}

function toLibraryContext(options) {
  const toolNames = new Map();
  const messages = [];
  for (const message of options.messages || []) {
    if (message.role === 'system') {
      messages.push({ role: 'user', content: flattenText(message), timestamp: 0 });
      continue;
    }
    if (message.role === 'assistant') {
      const assistant = toLibraryAssistant(message);
      for (const block of assistant.content) {
        if (block.type === 'toolCall') toolNames.set(block.id, block.name);
      }
      messages.push(assistant);
      continue;
    }
    const text = flattenText(message);
    const results = (message.content || []).filter((block) => block.type === 'tool-result');
    if (text.length > 0 || results.length === 0) {
      messages.push({ role: 'user', content: text, timestamp: 0 });
    }
    for (const result of results) {
      messages.push({
        role: 'toolResult',
        toolCallId: result.toolCallId,
        toolName: toolNames.get(result.toolCallId) ?? 'unknown',
        content: [{ type: 'text', text: toolResultText(result.content) || '(no output)' }],
        isError: result.isError ?? false,
        timestamp: 0,
      });
    }
  }
  const tools = (options.tools || []).map((tool) => ({
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
  }));
  return {
    ...(options.system ? { systemPrompt: options.system } : {}),
    messages,
    ...(tools.length > 0 ? { tools } : {}),
  };
}

function mapStopReason(message) {
  switch (message.stopReason) {
    case 'stop':
      return message.content.length === 0
        ? { kind: 'error', failure: { message: 'empty model response', code: 'EMPTY_RESPONSE' } }
        : { kind: 'stop' };
    case 'length':
      return { kind: 'max-tokens' };
    case 'toolUse':
      return { kind: 'tool-calls' };
    case 'aborted':
      return { kind: 'aborted', failure: { message: 'aborted', code: 'ABORTED' } };
    default:
      return { kind: 'error', failure: { message: 'provider stream error', code: 'PROVIDER_ERROR' } };
  }
}

async function* toStreamChunks(events) {
  const toolIds = new Map();
  let terminal = false;
  for await (const event of events) {
    switch (event.type) {
      case 'start':
        break;
      case 'text_start':
        yield { type: 'block-start', index: event.contentIndex, blockType: 'text' };
        break;
      case 'text_delta':
        yield { type: 'text-delta', index: event.contentIndex, text: event.delta };
        break;
      case 'text_end':
        yield { type: 'block-end', index: event.contentIndex, block: { type: 'text', text: event.content } };
        break;
      case 'thinking_start':
        yield { type: 'block-start', index: event.contentIndex, blockType: 'reasoning' };
        break;
      case 'thinking_delta':
        yield { type: 'reasoning-delta', index: event.contentIndex, text: event.delta };
        break;
      case 'thinking_end':
        yield { type: 'block-end', index: event.contentIndex, block: { type: 'reasoning', text: event.content } };
        break;
      case 'toolcall_start': {
        const partial = event.partial.content[event.contentIndex];
        const id = partial?.type === 'toolCall' ? partial.id : '';
        const name = partial?.type === 'toolCall' ? partial.name : '';
        toolIds.set(event.contentIndex, { id, name });
        yield { type: 'block-start', index: event.contentIndex, blockType: 'tool-call' };
        break;
      }
      case 'toolcall_delta': {
        const known = toolIds.get(event.contentIndex);
        yield {
          type: 'tool-call-delta',
          index: event.contentIndex,
          id: CallId(known?.id ?? ''),
          ...(known?.name ? { name: known.name } : {}),
          argumentsDelta: event.delta,
        };
        break;
      }
      case 'toolcall_end':
        yield {
          type: 'block-end',
          index: event.contentIndex,
          block: {
            type: 'tool-call',
            id: CallId(event.toolCall.id),
            name: event.toolCall.name,
            arguments: JSON.stringify(event.toolCall.arguments),
          },
        };
        break;
      case 'done':
      case 'error': {
        terminal = true;
        const message = event.type === 'done' ? event.message : event.error;
        if (message.usage) {
          yield {
            type: 'usage',
            usage: {
              inputTokens: message.usage.input,
              outputTokens: message.usage.output,
              ...(message.usage.cacheRead > 0 ? { cacheReadTokens: message.usage.cacheRead } : {}),
              ...(message.usage.cacheWrite > 0 ? { cacheWriteTokens: message.usage.cacheWrite } : {}),
            },
          };
        }
        yield { type: 'finish', reason: mapStopReason(message) };
        break;
      }
      default:
        break;
    }
  }
  if (!terminal) {
    throw new LlmError('provider stream closed without a terminal event', 'STREAM_CLOSED');
  }
}

export class SubscriptionLlmAdapter extends LlmAdapter {
  constructor(route, displayName) {
    super();
    this.route = route;
    this.displayName = displayName;
    this.store = new DshSubscriptionCredentialStore();
    this.models = createModels({ credentials: this.store });
    if (route === 'openai-codex') this.models.setProvider(openaiCodex.openaiCodexProvider());
    else if (route === 'xai') this.models.setProvider(xai.xaiProvider());
    else throw new LlmError('unsupported subscription provider route', 'UNKNOWN_PROVIDER');
    this.reasoning = ROUTE_REASONING[route];
    if (!this.reasoning) throw new LlmError('unsupported subscription provider route', 'UNKNOWN_PROVIDER');
  }

  providerInfo(provider) {
    return { id: provider, name: this.displayName };
  }

  async listModels(provider) {
    return this.models.getModels(this.route).map((model) => ({
      provider,
      id: model.id,
      name: model.name || model.id,
      inputModalities: modelInputModalities(model),
    }));
  }

  async resolveModel(provider, model) {
    const found = this.models.getModel(this.route, model);
    return {
      provider,
      id: model,
      name: found?.name || model,
      inputModalities: modelInputModalities(found),
      context: { contextWindow: found?.contextWindow || 128000 },
      defaultMaxTokens: found?.maxTokens || 8192,
      reasoning: this.reasoning,
    };
  }

  async *stream(options) {
    const model = libraryModelFor(this.models, this.route, options.model);
    assertEffortReachable(model, options.reasoningEffort);
    let auth;
    try {
      auth = await this.models.getAuth(this.route);
    } catch {
      throw new LlmError(`provider ${this.route} auth failed`, 'AUTH');
    }
    if (!auth) throw new LlmError(`provider ${this.route} is not configured`, 'MISSING_CREDENTIAL');
    const headers = attributionHeaders();
    try {
      const events = this.models.stream(model, toLibraryContext(options), {
        signal: options.signal,
        transformHeaders: (current) => ({ ...current, ...headers }),
        ...(options.reasoningEffort
          ? { reasoningEffort: String(options.reasoningEffort) }
          : {}),
      });
      yield* toStreamChunks(events);
    } catch (error) {
      if (error instanceof LlmError) throw error;
      throw new LlmError(`provider ${this.route} stream failed`, 'PROVIDER_ERROR');
    }
  }
}
