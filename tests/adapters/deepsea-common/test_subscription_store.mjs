// SPDX-License-Identifier: MPL-2.0
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve as resolvePath } from 'node:path';
import {
  DshSubscriptionCredentialStore,
  resolveCommunitySubscriptionStorePath,
  resolveCommunitySubscriptionStorePaths,
} from '../../../src/adapters/deepsea-common/dsh-plugin/subscription-store.mjs';
import { resolveDshPackage, resolvePiAiRoot } from '../../../src/adapters/deepsea-common/dsh-plugin/resolve-modules.mjs';

const XAI_TOKEN_URL = 'https://auth.x.ai/oauth2/token';
const root = process.argv[2];
if (typeof root !== 'string' || root.trim() === '') {
  process.stderr.write('Usage: node test_subscription_store.mjs <TestRoot>\n');
  process.exit(2);
}

let assertions = 0;

function assert(condition, message) {
  assertions += 1;
  if (!condition) throw new Error(message);
}

function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8' });
}

function readJson(path) {
  return JSON.parse(readFileSync(path, { encoding: 'utf8' }));
}

const ownPath = join(root, 'own', 'subscription-oauth.json');
const cliStore = join(root, 'cli-dsh', 'plugins', 'subscriptions', 'auth.json');
const desktopStore = join(root, 'desktop-harness', 'plugins', 'subscriptions', 'auth.json');
const dualCodexStore = join(root, 'dual-codex', 'plugins', 'subscriptions', 'auth.json');
const dualCodexOwnPath = join(root, 'dual-codex-own', 'subscription-oauth.json');
const xaiCommunity = {
  accessToken: 'test-access-xai-community',
  refreshToken: 'test-refresh-xai-community',
  expiresAt: 1_900_000_000_000,
  tokenEndpoint: XAI_TOKEN_URL,
};
const claudeSession = {
  accessToken: 'test-access-claude-keep',
  refreshToken: 'test-refresh-claude-keep',
  expiresAt: 1_900_000_000_100,
};
const xaiOwn = {
  type: 'oauth',
  access: 'test-access-xai-own',
  refresh: 'test-refresh-xai-own',
  expires: 1_900_000_000_200,
  tokenEndpoint: XAI_TOKEN_URL,
};
const codexOwn = {
  type: 'oauth',
  access: 'test-access-codex-own',
  refresh: 'test-refresh-codex-own',
  expires: 1_900_000_000_300,
  accountId: 'acct_test_codex_1',
};
const codexKeepSlot = {
  accessToken: 'test-access-codex-slot-keep',
  refreshToken: 'test-refresh-codex-slot-keep',
  expiresAt: 1_900_000_000_400,
  accountId: 'acct_test_codex_slot_keep',
};
const codexSelectedSlot = {
  accessToken: 'test-access-codex-slot-selected',
  refreshToken: 'test-refresh-codex-slot-selected',
  expiresAt: 1_900_000_000_500,
  accountId: 'acct_test_codex_slot_selected',
};

writeJson(cliStore, { grok: xaiCommunity, claude: claudeSession });
writeJson(desktopStore, { claude: claudeSession });

const previousOwn = process.env.TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE;
const previousCommunity = process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE;
const previousCodexCommunityKey = process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY;
const previousProfile = process.env.USERPROFILE;
const previousHome = process.env.HOME;
const previousAppData = process.env.APPDATA;
const previousDshHome = process.env.DSH_HOME;
const previousCwd = process.cwd();
try {
  process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE = 'off';
  assert(resolveCommunitySubscriptionStorePaths().length === 0, 'off did not disable community stores.');
  assert(resolveCommunitySubscriptionStorePath() === null, 'off still resolved a community store.');

  process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE = `${cliStore};${desktopStore}`;
  const discovered = resolveCommunitySubscriptionStorePaths();
  assert(discovered.length === 2, 'Override did not keep both community stores.');
  assert(discovered[0] === cliStore && discovered[1] === desktopStore, 'Override store order drifted.');

  const store = new DshSubscriptionCredentialStore(ownPath, [cliStore, desktopStore]);
  const fromCommunity = await store.read('xai');
  assert(fromCommunity?.access === 'test-access-xai-community', 'Did not read the CLI community Grok session.');
  assert(fromCommunity?.tokenEndpoint === XAI_TOKEN_URL, 'Community Grok session dropped tokenEndpoint.');

  writeJson(dualCodexStore, { 'codex-slot-keep': codexKeepSlot, 'codex-slot-selected': codexSelectedSlot, claude: claudeSession });
  process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY = 'codex-slot-selected';
  const dualCodex = new DshSubscriptionCredentialStore(dualCodexOwnPath, [dualCodexStore]);
  const selectedCodex = await dualCodex.read('openai-codex');
  assert(selectedCodex?.access === 'test-access-codex-slot-selected', 'Explicit Codex community slot was not reused.');
  await dualCodex.modify('openai-codex', async () => codexOwn);
  const dualAfter = readJson(dualCodexStore);
  assert(dualAfter['codex-slot-selected'].accountId === 'acct_test_codex_1', 'Codex refresh did not persist into the selected slot.');
  assert(dualAfter['codex-slot-keep'].accountId === 'acct_test_codex_slot_keep', 'Codex refresh changed the sibling slot.');
  assert(Object.prototype.hasOwnProperty.call(dualAfter, 'codex') === false, 'Selected-slot refresh created a legacy Codex key.');
  delete process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY;

  const listed = await store.list();
  assert(listed.length === 1 && listed[0].providerId === 'xai', 'list() did not surface the community Grok route.');

  await store.modify('xai', async () => xaiOwn);
  await store.modify('openai-codex', async () => codexOwn);

  const ownDoc = readJson(ownPath);
  assert(ownDoc.protocol === 'telephone-line-dsh-subscription-oauth-v1', 'Own store protocol drifted.');
  assert(ownDoc.credentials.xai.access === 'test-access-xai-own', 'Own store did not keep the Grok credential.');
  assert(ownDoc.credentials['openai-codex'].accountId === 'acct_test_codex_1', 'Own store dropped Codex accountId.');

  const cliDoc = readJson(cliStore);
  assert(cliDoc.claude.accessToken === 'test-access-claude-keep', 'CLI community store dropped the unrelated Claude session.');
  assert(cliDoc.grok.accessToken === 'test-access-xai-own', 'CLI community store was not mirrored.');
  assert(cliDoc.grok.tokenEndpoint === XAI_TOKEN_URL, 'CLI community Grok session dropped tokenEndpoint.');
  assert(cliDoc.codex.accountId === 'acct_test_codex_1', 'CLI community Codex session dropped accountId.');

  const desktopDoc = readJson(desktopStore);
  assert(desktopDoc.claude.accessToken === 'test-access-claude-keep', 'Desktop community store dropped the unrelated Claude session.');
  assert(desktopDoc.grok.accessToken === 'test-access-xai-own', 'Desktop community store was not mirrored.');
  assert(desktopDoc.codex.accountId === 'acct_test_codex_1', 'Desktop community Codex session dropped accountId.');

  const ownWins = new DshSubscriptionCredentialStore(ownPath, [cliStore]);
  writeJson(cliStore, {
    grok: xaiCommunity,
    claude: claudeSession,
    codex: desktopDoc.codex,
  });
  const preferred = await ownWins.read('xai');
  assert(preferred?.access === 'test-access-xai-own', 'Own store did not win over the community Grok session.');

  const stringCtor = new DshSubscriptionCredentialStore(ownPath, desktopStore);
  assert(stringCtor.communityPaths.length === 1, 'String community path was not accepted.');
  const desktopOnly = await stringCtor.read('xai');
  assert(desktopOnly?.access === 'test-access-xai-own', 'Desktop-only constructor did not read the mirrored Grok session.');

  await store.delete('xai');
  const afterDelete = await store.read('xai');
  assert(afterDelete === undefined, 'delete() left a Grok credential in own or community stores.');
  assert(readJson(cliStore).claude.accessToken === 'test-access-claude-keep', 'delete() removed the unrelated Claude session.');
  assert(Object.prototype.hasOwnProperty.call(readJson(cliStore), 'grok') === false, 'delete() left grok in the CLI community store.');
  assert(Object.prototype.hasOwnProperty.call(readJson(desktopStore), 'grok') === false, 'delete() left grok in the Desktop community store.');
  assert(readJson(ownPath).credentials.xai === undefined, 'delete() left xai in the own store.');
  assert(readJson(cliStore).codex.accountId === 'acct_test_codex_1', 'delete() removed the Codex community session.');

  const trapRoot = join(root, 'cwd-trap');
  const trapPi = join(trapRoot, 'node_modules', '@earendil-works', 'pi-ai');
  const emptyHome = join(root, 'empty-home');
  const emptyAppData = join(emptyHome, 'AppData', 'Roaming');
  const isolatedDsh = join(root, 'real-dsh');
  const realPi = join(isolatedDsh, 'profiles', 'node_modules', '@earendil-works', 'pi-ai');
  mkdirSync(trapPi, { recursive: true });
  writeJson(join(trapPi, 'package.json'), { name: '@earendil-works/pi-ai', version: '0.0.0-trap' });
  mkdirSync(emptyAppData, { recursive: true });
  mkdirSync(realPi, { recursive: true });
  writeJson(join(realPi, 'package.json'), { name: '@earendil-works/pi-ai', version: '0.0.0-dsh' });

  process.env.USERPROFILE = emptyHome;
  process.env.HOME = emptyHome;
  process.env.APPDATA = emptyAppData;
  delete process.env.DSH_HOME;
  process.chdir(trapRoot);
  let cwdRejected = false;
  try { resolvePiAiRoot(); } catch { cwdRejected = true; }
  assert(cwdRejected, 'resolvePiAiRoot used a cwd copy of pi-ai.');
  let cwdPackageRejected = false;
  try { resolveDshPackage('@deepseek-ai/dsh'); } catch { cwdPackageRejected = true; }
  assert(cwdPackageRejected, 'resolveDshPackage used a cwd tree.');

  process.env.DSH_HOME = isolatedDsh;
  const found = resolvePiAiRoot();
  assert(
    found.replace(/\//g, '\\').toLowerCase() === resolvePath(realPi).replace(/\//g, '\\').toLowerCase(),
    'resolvePiAiRoot did not stay under DSH_HOME.',
  );

  process.stdout.write(`${JSON.stringify({ success: true, assertions })}\n`);
} catch (error) {
  process.stdout.write(`${JSON.stringify({ success: false, assertions, error: String(error && error.message ? error.message : error) })}\n`);
  process.exitCode = 1;
} finally {
  try { process.chdir(previousCwd); } catch { /* restore cwd */ }
  if (previousOwn === undefined) delete process.env.TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE;
  else process.env.TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE = previousOwn;
  if (previousCommunity === undefined) delete process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE;
  else process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE = previousCommunity;
  if (previousCodexCommunityKey === undefined) delete process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY;
  else process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY = previousCodexCommunityKey;
  if (previousProfile === undefined) delete process.env.USERPROFILE;
  else process.env.USERPROFILE = previousProfile;
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  if (previousAppData === undefined) delete process.env.APPDATA;
  else process.env.APPDATA = previousAppData;
  if (previousDshHome === undefined) delete process.env.DSH_HOME;
  else process.env.DSH_HOME = previousDshHome;
  try { rmSync(join(root, 'scratch-unused'), { recursive: true, force: true }); } catch { /* isolation only */ }
}
