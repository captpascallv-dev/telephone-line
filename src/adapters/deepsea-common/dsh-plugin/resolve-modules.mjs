// SPDX-License-Identifier: MPL-2.0
import { existsSync } from 'node:fs';
import { dirname, join, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';

function packageRoot(dir) {
  return existsSync(join(dir, 'package.json')) ? dir : null;
}

function uniquePaths(paths) {
  const seen = new Set();
  const out = [];
  for (const value of paths) {
    if (typeof value !== 'string' || value.trim() === '') continue;
    const full = resolve(value.trim());
    const key = full.replace(/\//g, '\\').toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(full);
  }
  return out;
}

function isInside(root, target) {
  const rootFull = resolve(root);
  const targetFull = resolve(target);
  if (targetFull.toLowerCase() === rootFull.toLowerCase()) return true;
  const prefix = rootFull.endsWith(sep) ? rootFull : rootFull + sep;
  return targetFull.toLowerCase().startsWith(prefix.toLowerCase());
}

function dshHomes() {
  const homes = [];
  if (typeof process.env.DSH_HOME === 'string' && process.env.DSH_HOME.trim() !== '') {
    homes.push(process.env.DSH_HOME.trim());
  }
  const user = process.env.USERPROFILE || process.env.HOME;
  if (typeof user === 'string' && user.trim() !== '') {
    homes.push(join(user.trim(), '.dsh'));
  }
  if (typeof process.env.APPDATA === 'string' && process.env.APPDATA.trim() !== '') {
    const appData = process.env.APPDATA.trim();
    homes.push(join(appData, 'dsh-desktop', 'harness'));
    homes.push(join(appData, 'dsh-desktop-dev', 'harness'));
  }
  return uniquePaths(homes);
}

function walkStarts(home) {
  return [
    join(home, 'profiles', 'web'),
    join(home, 'profiles', 'headless'),
    join(home, 'profiles', 'node_modules', '@deepseek-ai', 'dsh', 'lib'),
    join(home, 'profiles'),
    home,
  ];
}

function walkNodeModulesUnder(root, start, spec) {
  const base = resolve(root);
  let dir = resolve(start);
  if (!isInside(base, dir)) return null;
  for (let i = 0; i < 16; i += 1) {
    const candidate = join(dir, 'node_modules', spec);
    if (packageRoot(candidate) && isInside(base, candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    if (!isInside(base, parent)) break;
    dir = parent;
  }
  return null;
}

function piAiExactPaths(home) {
  return [
    join(home, 'profiles', 'node_modules', '@earendil-works', 'pi-ai'),
    join(home, 'profiles', 'web', 'node_modules', '@earendil-works', 'pi-ai'),
    join(home, 'profiles', 'headless', 'node_modules', '@earendil-works', 'pi-ai'),
    join(home, 'profiles', 'node_modules', '@deepseek-ai', 'dsh-llm-pi-ai', 'node_modules', '@earendil-works', 'pi-ai'),
  ];
}

export function resolveDshPackage(spec) {
  for (const home of dshHomes()) {
    for (const start of walkStarts(home)) {
      const found = walkNodeModulesUnder(home, start, spec);
      if (found) return found;
    }
  }
  throw new Error(`User-installed DSH package was not found: ${spec}`);
}

export function loadDsh(spec, rel = 'lib/index.js') {
  return import(pathToFileURL(join(resolveDshPackage(spec), rel)).href);
}

export function resolvePiAiRoot() {
  for (const home of dshHomes()) {
    for (const candidate of piAiExactPaths(home)) {
      if (packageRoot(candidate) && isInside(home, candidate)) return candidate;
    }
  }
  for (const home of dshHomes()) {
    for (const start of walkStarts(home)) {
      const found = walkNodeModulesUnder(home, start, '@earendil-works/pi-ai');
      if (found) return found;
    }
  }
  throw new Error('User-installed DSH model library (@earendil-works/pi-ai) was not found. Install DeepSeek Harness.');
}

export function loadPiAi(rel = 'dist/index.js') {
  return import(pathToFileURL(join(resolvePiAiRoot(), rel)).href);
}
