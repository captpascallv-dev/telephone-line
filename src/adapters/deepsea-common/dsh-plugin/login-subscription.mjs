// SPDX-License-Identifier: MPL-2.0
import { loadPiAi } from './resolve-modules.mjs';
import { DshSubscriptionCredentialStore } from './subscription-store.mjs';

const route = String(process.argv[2] || '').trim();
if (route !== 'xai' && route !== 'openai-codex') {
  process.stderr.write('Usage: node login-subscription.mjs <xai|openai-codex>\n');
  process.exit(2);
}

const oauth = await loadPiAi('dist/auth/oauth/load.js');
const loaded = route === 'xai' ? await oauth.loadXaiOAuth() : await oauth.loadOpenAICodexOAuth();
const store = new DshSubscriptionCredentialStore();
const controller = new AbortController();
const interaction = {
  signal: controller.signal,
  async prompt(prompt) {
    if (prompt.type === 'select') {
      const device = prompt.options.find((option) => String(option.id).includes('device'));
      return (device || prompt.options[0]).id;
    }
    throw new Error('This login helper is device-code only.');
  },
  notify(event) {
    if (event.type === 'device_code') {
      process.stderr.write(`Open ${event.verificationUri} and enter ${event.userCode}\n`);
      return;
    }
    if (event.type === 'auth_url') {
      process.stderr.write(`${event.instructions || 'Open this URL'}: ${event.url}\n`);
      return;
    }
    if (event.type === 'info' || event.type === 'progress') {
      process.stderr.write(`${event.message}\n`);
    }
  },
};

const credential = await loaded.login(interaction);
await store.modify(route, async () => credential);
process.stderr.write(`Stored ${route} subscription in the DSH credential store.\n`);
if (store.communityPaths.length > 0) {
  process.stderr.write('Mirrored into the community DSH subscriptions store when present.\n');
}
