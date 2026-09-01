// SPDX-License-Identifier: MPL-2.0
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { dirname, join } from 'node:path';

const PROTOCOL = 'telephone-line-dsh-subscription-oauth-v1';
const XAI_TOKEN_URL = 'https://auth.x.ai/oauth2/token';
const COMMUNITY_KEYS = {
  xai: ['grok'],
  'openai-codex': ['codex'],
};

function communityKeysFor(providerId) {
  if (providerId === 'openai-codex') {
    const override = process.env.TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY;
    if (typeof override === 'string' && override.trim() !== '') {
      const key = override.trim();
      if (!/^[A-Za-z0-9._:-]{1,64}$/.test(key)) {
        throw new Error('DSH Codex community credential key is malformed.');
      }
      return [key];
    }
  }
  return COMMUNITY_KEYS[providerId] || [];
}

export function resolveSubscriptionStorePath() {
  const override = process.env.TELEPHONE_LINE_DSH_SUBSCRIPTION_STORE;
  if (typeof override === 'string' && override.trim() !== '') return override.trim();
  const home = process.env.USERPROFILE || process.env.HOME;
  if (!home) throw new Error('DSH subscription store path is missing.');
  return join(home, '.dsh', 'subscription-oauth.json');
}

function userHome() {
  const home = process.env.USERPROFILE || process.env.HOME;
  return typeof home === 'string' && home.trim() !== '' ? home.trim() : '';
}

function appDataDir() {
  if (typeof process.env.APPDATA === 'string' && process.env.APPDATA.trim() !== '') {
    return process.env.APPDATA.trim();
  }
  const home = userHome();
  return home ? join(home, 'AppData', 'Roaming') : '';
}

function uniquePaths(paths) {
  const seen = new Set();
  const out = [];
  for (const path of paths) {
    if (typeof path !== 'string' || path.trim() === '') continue;
    const key = path.replace(/\//g, '\\').toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(path);
  }
  return out;
}

function splitStoreOverride(raw) {
  return uniquePaths(String(raw).split(';').map((part) => part.trim()).filter((part) => part.length > 0));
}

function defaultCommunityHomes() {
  const homes = [];
  const home = userHome();
  const appData = appDataDir();
  if (home) {
    homes.push({
      store: join(home, '.dsh', 'plugins', 'subscriptions', 'auth.json'),
      legacyStore: join(home, '.dsh', 'plugins', 'router', 'auth.json'),
      pluginPackage: join(home, '.dsh', 'profiles', 'web', 'node_modules', 'dsh-plugin-subscriptions', 'package.json'),
    });
  }
  if (appData) {
    for (const name of ['dsh-desktop', 'dsh-desktop-dev']) {
      const dshHome = join(appData, name, 'harness');
      homes.push({
        store: join(dshHome, 'plugins', 'subscriptions', 'auth.json'),
        pluginPackage: join(dshHome, 'profiles', 'web', 'node_modules', 'dsh-plugin-subscriptions', 'package.json'),
      });
    }
  }
  return homes;
}

function discoveredCommunityStorePath(home) {
  if (existsSync(home.store)) return home.store;
  if (home.legacyStore && existsSync(home.legacyStore)) return home.legacyStore;
  if (existsSync(home.pluginPackage)) return home.store;
  return null;
}

export function resolveCommunitySubscriptionStorePaths() {
  const override = process.env.TELEPHONE_LINE_DSH_COMMUNITY_STORE;
  if (typeof override === 'string' && override.trim().toLowerCase() === 'off') return [];
  if (typeof override === 'string' && override.trim() !== '') return splitStoreOverride(override);
  return uniquePaths(defaultCommunityHomes().map(discoveredCommunityStorePath).filter(Boolean));
}

export function resolveCommunitySubscriptionStorePath() {
  return resolveCommunitySubscriptionStorePaths()[0] || null;
}

function emptyDocument() {
  return { protocol: PROTOCOL, credentials: {} };
}

function writeAtomicFile(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  writeFileSync(tmp, text, { encoding: 'utf8', mode: 0o600 });
  try { chmodSync(tmp, 0o600); } catch { /* Windows may ignore POSIX modes. */ }
  try {
    renameSync(tmp, path);
  } catch {
    copyFileSync(tmp, path);
    rmSync(tmp, { force: true });
  }
  try { chmodSync(path, 0o600); } catch { /* Windows may ignore POSIX modes. */ }
}

function readOwnDocument(path) {
  if (!existsSync(path)) return emptyDocument();
  const parsed = JSON.parse(readFileSync(path, { encoding: 'utf8' }));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('DSH subscription store is malformed.');
  }
  const credentials = parsed.credentials && typeof parsed.credentials === 'object' && !Array.isArray(parsed.credentials)
    ? parsed.credentials
    : {};
  return { protocol: PROTOCOL, credentials };
}

function readCommunityDocument(path) {
  if (!path || !existsSync(path)) return {};
  const parsed = JSON.parse(readFileSync(path, { encoding: 'utf8' }));
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Community DSH subscriptions store is malformed.');
  }
  return parsed;
}

function isOAuthCredential(value) {
  return Boolean(
    value
    && value.type === 'oauth'
    && typeof value.access === 'string'
    && value.access.length > 0
    && typeof value.refresh === 'string'
    && value.refresh.length > 0
    && typeof value.expires === 'number'
    && Number.isFinite(value.expires),
  );
}

function fromCommunitySession(route, session) {
  if (!session || typeof session !== 'object') return undefined;
  if (typeof session.accessToken !== 'string' || session.accessToken.length === 0) return undefined;
  if (typeof session.refreshToken !== 'string' || session.refreshToken.length === 0) return undefined;
  if (typeof session.expiresAt !== 'number' || !Number.isFinite(session.expiresAt)) return undefined;
  if (route === 'openai-codex' && (typeof session.accountId !== 'string' || session.accountId.length === 0)) {
    return undefined;
  }
  const credential = {
    type: 'oauth',
    access: session.accessToken,
    refresh: session.refreshToken,
    expires: session.expiresAt,
  };
  if (typeof session.accountId === 'string' && session.accountId.length > 0) credential.accountId = session.accountId;
  if (typeof session.idToken === 'string' && session.idToken.length > 0) credential.idToken = session.idToken;
  if (typeof session.tokenEndpoint === 'string' && session.tokenEndpoint.length > 0) {
    credential.tokenEndpoint = session.tokenEndpoint;
  }
  if (typeof session.emailAddress === 'string' && session.emailAddress.length > 0) {
    credential.emailAddress = session.emailAddress;
  }
  if (typeof session.account === 'string' && session.account.length > 0) credential.account = session.account;
  if (typeof session.scopes === 'string' && session.scopes.length > 0) credential.scopes = session.scopes;
  if (typeof session.planType === 'string' && session.planType.length > 0) credential.planType = session.planType;
  return credential;
}

function toCommunitySession(route, credential) {
  if (!isOAuthCredential(credential)) return undefined;
  if (route === 'openai-codex') {
    const accountId = typeof credential.accountId === 'string' ? credential.accountId : '';
    if (accountId.length === 0) return undefined;
    const session = {
      accessToken: credential.access,
      refreshToken: credential.refresh,
      expiresAt: credential.expires,
      accountId,
    };
    if (typeof credential.idToken === 'string' && credential.idToken.length > 0) session.idToken = credential.idToken;
    if (typeof credential.emailAddress === 'string' && credential.emailAddress.length > 0) {
      session.emailAddress = credential.emailAddress;
    }
    if (typeof credential.planType === 'string' && credential.planType.length > 0) session.planType = credential.planType;
    return session;
  }
  return {
    accessToken: credential.access,
    refreshToken: credential.refresh,
    expiresAt: credential.expires,
    tokenEndpoint: typeof credential.tokenEndpoint === 'string' && credential.tokenEndpoint.length > 0
      ? credential.tokenEndpoint
      : XAI_TOKEN_URL,
    ...(typeof credential.scopes === 'string' && credential.scopes.length > 0 ? { scopes: credential.scopes } : {}),
    ...(typeof credential.account === 'string' && credential.account.length > 0 ? { account: credential.account } : {}),
  };
}

function writeOwnDocument(path, document) {
  writeAtomicFile(path, `${JSON.stringify(document, null, 2)}\n`);
}

function writeCommunityDocument(path, document) {
  writeAtomicFile(path, `${JSON.stringify(document, null, 2)}\n`);
}

function normalizeCommunityPaths(communityPaths) {
  if (communityPaths == null) return [];
  if (typeof communityPaths === 'string') {
    return communityPaths.trim() === '' ? [] : [communityPaths.trim()];
  }
  if (!Array.isArray(communityPaths)) return [];
  return uniquePaths(communityPaths);
}

/**
 * DSH-owned CredentialStore. Tokens live under the user DSH home, not PI's
 * auth.json and not telephone-line job state. When a community
 * dsh-plugin-subscriptions store exists (CLI DSH home or DSH Desktop harness
 * home), the same login is reused and refreshed in place.
 */
export class DshSubscriptionCredentialStore {
  constructor(path = resolveSubscriptionStorePath(), communityPaths = resolveCommunitySubscriptionStorePaths()) {
    this.path = path;
    this.communityPaths = normalizeCommunityPaths(communityPaths);
    this.communityPath = this.communityPaths[0] || null;
    this.locks = new Map();
  }

  async withLock(providerId, work) {
    const previous = this.locks.get(providerId) || Promise.resolve();
    let release;
    const gate = new Promise((resolve) => {
      release = resolve;
    });
    this.locks.set(providerId, previous.then(() => gate));
    await previous;
    try {
      return await work();
    } finally {
      release();
    }
  }

  readOwn(providerId) {
    const current = readOwnDocument(this.path).credentials[providerId];
    return isOAuthCredential(current) ? { ...current } : undefined;
  }

  readCommunity(providerId) {
    const communityKeys = communityKeysFor(providerId);
    if (communityKeys.length === 0) return undefined;
    for (const path of this.communityPaths) {
      const document = readCommunityDocument(path);
      for (const communityKey of communityKeys) {
        const mapped = fromCommunitySession(providerId, document[communityKey]);
        if (mapped) return { ...mapped };
      }
    }
    return undefined;
  }

  persistCommunity(providerId, credential) {
    const communityKeys = communityKeysFor(providerId);
    if (communityKeys.length === 0) return false;
    let wrote = false;
    for (const path of this.communityPaths) {
      if (credential === undefined && !existsSync(path)) continue;
      const document = readCommunityDocument(path);
      const communityKey = communityKeys.find((key) => Object.prototype.hasOwnProperty.call(document, key))
        || communityKeys[0];
      if (credential === undefined) {
        if (!Object.prototype.hasOwnProperty.call(document, communityKey)) continue;
        delete document[communityKey];
        writeCommunityDocument(path, document);
        wrote = true;
        continue;
      }
      const session = toCommunitySession(providerId, credential);
      if (!session) continue;
      document[communityKey] = session;
      writeCommunityDocument(path, document);
      wrote = true;
    }
    return wrote;
  }

  async read(providerId) {
    return this.readOwn(providerId) || this.readCommunity(providerId);
  }

  async list() {
    const ids = new Set();
    for (const id of Object.keys(readOwnDocument(this.path).credentials)) {
      if (this.readOwn(id)) ids.add(id);
    }
    for (const path of this.communityPaths) {
      if (!existsSync(path)) continue;
      const community = readCommunityDocument(path);
      for (const [key, session] of Object.entries(community)) {
        for (const route of Object.keys(COMMUNITY_KEYS)) {
          if (communityKeysFor(route).includes(key) && fromCommunitySession(route, session)) ids.add(route);
        }
      }
    }
    return [...ids].sort().map((id) => ({ providerId: id, type: 'oauth' }));
  }

  async modify(providerId, fn) {
    return this.withLock(providerId, async () => {
      const current = this.readOwn(providerId) || this.readCommunity(providerId);
      const next = await fn(current ? { ...current } : undefined);
      const document = readOwnDocument(this.path);
      if (next !== undefined) {
        document.credentials[providerId] = next;
        writeOwnDocument(this.path, document);
        this.persistCommunity(providerId, next);
        return next;
      }
      return current;
    });
  }

  async delete(providerId) {
    return this.withLock(providerId, async () => {
      const document = readOwnDocument(this.path);
      delete document.credentials[providerId];
      writeOwnDocument(this.path, document);
      this.persistCommunity(providerId, undefined);
    });
  }
}
