// SPDX-License-Identifier: MPL-2.0
import { SubscriptionLlmAdapter } from './subscription-llm.mjs';

export const name = 'telephone-line-llm-subscription';
export const inject = ['llm'];

export function apply(ctx) {
  ctx.llm.registerAdapter(
    ['openai-codex'],
    new SubscriptionLlmAdapter('openai-codex', 'ChatGPT Plus/Pro Codex subscription'),
  );
  ctx.llm.registerAdapter(
    ['xai'],
    new SubscriptionLlmAdapter('xai', 'SuperGrok or X Premium'),
  );
}
