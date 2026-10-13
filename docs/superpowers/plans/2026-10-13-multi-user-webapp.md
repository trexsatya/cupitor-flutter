# Multi-user Cupitor — Webapp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The language webapp reads from and writes to the signed-in user's own GitHub data repo, can layer one other user's library on top read-only, and can set a new user up (data repo from template, PR on `cupitor-users`) — in a plain browser and inside the Cupitor app.

**Architecture:** Three small ES modules carry the new logic. `account-state.js` holds the account record (localStorage `cupitor:account`) and derives the two sources (self, other) and owner-scoped storage keys. `data-source.js` turns a source into raw URLs, exposes the single write target, and fetches/merges the layered files with read-only tagging. `account.js` does the GitHub work (login, idempotent setup steps, users list, token handling); `account-bridge.js` talks to the app; `account-panel.js` is the UI. `language.js` stops naming `trexsatya`/`trexsatya.github.io`/`gh-pages` anywhere and calls these modules instead. The first tasks are pure refactors: with no account record the modules resolve to the owner's repo, so the app behaves exactly as it does today after every commit.

**Tech Stack:** Vanilla ES modules + jQuery/jQuery UI (existing), jest 27 with jsdom (`npx jest public/language/<file>`), GitHub REST API via the existing `window.GitHubUtils` (direct `fetch` in a browser, `GitHubProxy` channel inside the app).

**Spec:** `/Users/satyendra.kumar/Documents/PersonalProjects/flutter/Cupitor/docs/superpowers/specs/2026-10-13-multi-user-design.md` — the spec is the contract; if plan and spec disagree, stop and say so.

---

## Conventions for the executor

- Repo: `/Users/satyendra.kumar/Documents/PersonalProjects/cupitor/frontend/vue3/cupitor-frontend`, branch `music-study-app` (commit to the current branch, do not create one).
- **Writes to this repo are blocked for Bash by the sandbox.** Create and edit files with the `Write`/`Edit` tools. Bash is fine for reading, `grep`, and `npx jest`. `git add`/`git commit` write to `.git`, so run them with the sandbox disabled (`dangerouslyDisableSandbox: true`).
- Run one test file: `cd /Users/satyendra.kumar/Documents/PersonalProjects/cupitor/frontend/vue3/cupitor-frontend && npx jest public/language/account-state.test.js`. Run everything in the language app: `npx jest public/language` (takes a minute or two).
- `public/language/language.js` is ~21.8k lines and **has unrelated uncommitted changes**. Before the first commit that touches it, run `git diff --stat public/language/language.js`; if it is already modified, stop and ask the user to commit or stash their work first, so each commit below contains only this plan's hunks. Only stage the files a task touched (`git add <paths>`, never `git add -A`).
- Line numbers in this plan are approximate (the file moves). Always locate code by the function name or the exact text quoted.
- Code is authoritative over comments. Where a comment in `language.js` mentions `gh-pages` or `trexsatya` as prose, leave it alone unless the task says otherwise; the tasks target code.
- Every commit message ends with the trailer line: `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Manual smoke check between tasks when a task touches `language.js`: `yarn serve` in the repo, open `http://localhost:8080/language.html?lang=swedish`, confirm subtitles load, a search works, and the console shows no new errors. (On localhost the vocabulary comes from `localhost:5000` — that is existing behaviour, ignore the vocabulary 404 there.)
- Deployment is **not** part of this plan. After the last task, the owner deploys with the `cupitor-deploy` skill (yarn build, copy into `trexsatya.github.io`).

---

## Bridge message contract (shared with the app plan — must stay identical in both)

The app registers a JS channel named `AccountBridge` on the dialog1 WebView. In a plain browser the channel does not exist and the webapp shows "not available in a browser" for in-app sign-in.

**JS → Dart** — `window.AccountBridge.postMessage(JSON.stringify(msg))`

```json
{ "op": "signIn" | "signOut" | "getStatus", "request_id": "<string, unique per call>" }
```

**Dart → JS** — one `CustomEvent` named `cupitorAccountAck` per message, dispatched on `window`; the same object is also stored on `window.__cupitorAccountAck` just before the dispatch (the app's global-then-dispatch pattern).

```json
{ "request_id": "<echoed, or null when the request could not be parsed>",
  "op": "<echoed op, or \"unknown\">",
  "ok": true | false,
  "error": "<only when ok is false>",
  "data": { "signed_in": true | false }   // present when ok is true for signIn and getStatus
}
```

| op | Effect in the app | `ok:true` data | `ok:false` error |
|---|---|---|---|
| `signIn` | Runs the GitHub device flow in a native dialog; on success stores the token where the app keeps `githubToken` | `{signed_in:true}` | `cancelled` (user closed the dialog), `denied` (user declined on GitHub), `expired` (code timed out), `network`, `busy` (a sign-in is already running), `internal` |
| `signOut` | Clears the stored token | `{signed_in:false}` | `internal` |
| `getStatus` | Nothing | `{signed_in: <bool>}` | — |
| anything else | — | — | `unknown_op`; unparsable JSON gives `bad_json` with `request_id: null` |

The token never crosses the bridge. After `signed_in:true` the webapp learns who it is with `GET /user` through `GitHubProxy`, which attaches the token.

---

## File structure

| File | Responsibility |
|---|---|
| `public/language/net.js` (modify) | `fetchWithRetry` gains `passthrough404` so a missing layer file is one request, not four retries. |
| `public/github-utils.js` (modify) | `GitHubUtils.request(method, path, body)`; no `Authorization` header when there is no token; a 401 raises `cupitorGithubUnauthorized` on `window`. |
| `public/language/account-state.js` (new) | Account record load/save, default `other`, `sources(state)`, `scopedKey(base)`. Pure; storage injected. |
| `public/language/data-source.js` (new) | `readUrl`, `writeTarget`, `readLayers`, merge helpers with `src`/`readOnly` tags, layer stats. Pure; fetch injected. |
| `public/language/account.js` (new) | Users list (fetch/cache/fallback), `fetchLogin`, setup steps, status, browser token storage, sign-in/out, boot reconcile. GitHub adapter injected. |
| `public/language/account-bridge.js` (new) | `AccountBridge` request/ack plumbing with timeouts. |
| `public/language/account-panel.js` (new) | View-model (`accountPanelVM`, tested) + jQuery UI dialog, guest banner, "Also load data from" picker, setup progress/retry, token form, `showSetupPrompt`. |
| `public/language.html` (modify) | Banner div, Account button in the settings footer, dialog container. |
| `public/language/language.js` (modify) | Uses the modules; no hardcoded owner/repo/branch; layered reads; read-only gating; guest write blocking; scoped storage keys. |
| `*.test.js` beside each new module | jest tests. |

---

### Task 1: `fetchWithRetry` passes a 404 through on request

**Files:**
- Modify: `public/language/net.js` (function `fetchWithRetry`)
- Test: `public/language/net.test.js`

- [ ] **Step 1: Write the failing test**

Append to the `describe("fetchWithRetry", ...)` block in `public/language/net.test.js` (find it with `grep -n 'describe("fetchWithRetry"' public/language/net.test.js`):

```js
  test("passthrough404 returns the 404 response after a single attempt", async () => {
    const fetchFn = jest.fn(async () => ({ ok: false, status: 404 }));
    const out = await fetchWithRetry("https://x/y", { passthrough404: true }, {
      fetch: fetchFn, sleep: async () => {},
    });
    expect(out.status).toBe(404);
    expect(fetchFn).toHaveBeenCalledTimes(1);
  });
  test("without passthrough404 a 404 is still retried and thrown", async () => {
    const fetchFn = jest.fn(async () => ({ ok: false, status: 404 }));
    await expect(fetchWithRetry("https://x/y", { tries: 2 }, { fetch: fetchFn, sleep: async () => {} }))
      .rejects.toThrow(/HTTP 404/);
    expect(fetchFn).toHaveBeenCalledTimes(2);
  });
```

- [ ] **Step 2: Run it to see it fail**

Run: `npx jest public/language/net.test.js -t passthrough404`
Expected: FAIL — `expect(fetchFn).toHaveBeenCalledTimes(1)` receives 4 (404 is retried).

- [ ] **Step 3: Implement**

In `public/language/net.js`, change the signature and the status check of `fetchWithRetry`:

```js
export async function fetchWithRetry(url, { tries = 4, timeoutMs = 12000, init = {}, passthrough404 = false } = {}, deps = {}) {
```

and inside the loop replace

```js
      const res = await withTimeout(fetchFn(reqUrl, baseInit), timeoutMs, reqUrl, setTimeoutFn)
      if (!res.ok) throw new Error('HTTP ' + res.status + ' for ' + reqUrl)
      return res
```

with

```js
      const res = await withTimeout(fetchFn(reqUrl, baseInit), timeoutMs, reqUrl, setTimeoutFn)
      // A missing file is an answer, not a transient failure: callers that
      // read optional layers ask for the 404 back instead of a retry storm.
      if (passthrough404 && res.status === 404) return res
      if (!res.ok) throw new Error('HTTP ' + res.status + ' for ' + reqUrl)
      return res
```

- [ ] **Step 4: Run the file's tests**

Run: `npx jest public/language/net.test.js`
Expected: PASS (30 tests).

- [ ] **Step 5: Commit**

```bash
git add public/language/net.js public/language/net.test.js
git commit -m "net: fetchWithRetry can hand a 404 back without retrying

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `GitHubUtils.request`, tokenless requests, 401 event

**Files:**
- Modify: `public/github-utils.js`
- Test: `public/github-utils.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/github-utils.test.js`:

```js
describe('request', () => {
  afterEach(() => { window.GitHubUtils.setGHToken('t'); delete window._suppressGHTokenPrompt })

  test('is the raw API call: parsed JSON back, GitHub API error on failure', async () => {
    fakeGitHub({ 'GET /user': reply(200, { login: 'alice' }) })
    expect(await window.GitHubUtils.request('GET', '/user')).toEqual({ login: 'alice' })
    await expect(window.GitHubUtils.request('GET', '/nope')).rejects.toThrow(/GitHub API error 404/)
  })

  test('sends no Authorization header when there is no token', async () => {
    window.GitHubUtils.clearGHToken()
    window._suppressGHTokenPrompt = true
    fakeGitHub({ 'GET /repos/o/r': reply(200, { id: 1 }) })
    await window.GitHubUtils.request('GET', '/repos/o/r')
    const headers = global.fetch.mock.calls[0][1].headers
    expect(headers.Authorization).toBeUndefined()
  })

  test('a 401 raises cupitorGithubUnauthorized on window before throwing', async () => {
    const seen = jest.fn()
    window.addEventListener('cupitorGithubUnauthorized', seen)
    fakeGitHub({ 'GET /user': reply(401, { message: 'Bad credentials' }) })
    await expect(window.GitHubUtils.request('GET', '/user')).rejects.toThrow(/GitHub API error 401/)
    expect(seen).toHaveBeenCalledTimes(1)
    window.removeEventListener('cupitorGithubUnauthorized', seen)
  })
})
```

- [ ] **Step 2: Run them to see them fail**

Run: `npx jest public/github-utils.test.js -t request`
Expected: FAIL — `window.GitHubUtils.request is not a function`.

- [ ] **Step 3: Implement**

In `public/github-utils.js`:

(a) Add a helper right after `function _b64decode(b64) { ... }`:

```js
  // Told once per failed call; the account module signs the user out on it.
  function _notifyUnauthorized() {
    try { global.dispatchEvent(new CustomEvent('cupitorGithubUnauthorized')); } catch (_) {}
  }
```

(b) In `_githubRequest`, replace the header construction and the error branch:

```js
    const effectiveToken = token || getGHToken();
    const headers = {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
    // Public repos answer without a token; a header of "Bearer null" turns
    // those reads into 401s.
    if (effectiveToken) headers.Authorization = `Bearer ${effectiveToken}`;
    if (body) headers['Content-Type'] = 'application/json';

    const res = await fetch(`${GITHUB_API}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    const parsed = await res.json();
    if (!res.ok) {
      if (res.status === 401) _notifyUnauthorized();
      throw new Error(`GitHub API error ${res.status}: ${parsed.message}`);
    }
    return parsed;
```

(c) In `_githubRequestViaProxy`, inside the handler, before `settle(() => reject(...))` for the error case:

```js
        if (statusCode === 0 || statusCode >= 400) {
          if (statusCode === 401) _notifyUnauthorized();
          settle(() => reject(new Error(`GitHub API error ${statusCode}: ${parsed.message || responseText}`)));
        } else {
```

(d) Add the public function after `getFile`:

```js
  /**
   * One GitHub REST call: `request('GET', '/user')`. Returns the parsed JSON
   * body; rejects with `GitHub API error <status>: <message>`. Goes through
   * GitHubProxy inside the app, direct fetch in a browser.
   */
  function request(method, path, body) {
    return _githubRequest(method, path, body || null, "");
  }
```

(e) Add `request` to the exported object:

```js
  global.GitHubUtils = { getGHToken, setGHToken, clearGHToken, request, getFile, putFile, putFileWithContent, updateFile, deleteFile, deleteFileWithLookup, commitMultipleFiles };
```

- [ ] **Step 4: Run the file's tests**

Run: `npx jest public/github-utils.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/github-utils.js public/github-utils.test.js
git commit -m "github-utils: request(), tokenless calls send no auth header, 401 raises an event

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `account-state.js` — the account record, sources, scoped keys

**Files:**
- Create: `public/language/account-state.js`
- Test: `public/language/account-state.test.js`

- [ ] **Step 1: Write the failing tests**

Create `public/language/account-state.test.js`:

```js
import {
  ACCOUNT_KEY, OWNER, loadAccount, saveAccount, clearAccount,
  normalizeUser, defaultOther, sources, scopedKey,
} from './account-state.js'

function memStorage(init = {}) {
  const m = new Map(Object.entries(init))
  return {
    getItem: k => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: k => m.delete(k),
  }
}

describe('loadAccount', () => {
  test('nothing stored → guest with trexsatya as the other source', () => {
    expect(loadAccount(memStorage())).toEqual({
      login: null, repo: null, branch: null,
      other: { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' },
    })
  })
  test('garbage stored → guest', () => {
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: '{nope' })).login).toBeNull()
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: '[]' })).login).toBeNull()
  })
  test('a signed-in record round-trips', () => {
    const s = memStorage()
    saveAccount({ login: 'alice', repo: 'cupitor-data', branch: 'main',
      other: { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' } }, s)
    expect(loadAccount(s)).toEqual({ login: 'alice', repo: 'cupitor-data', branch: 'main',
      other: { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' } })
  })
  test('other: null stored means "none"; a missing other means the default', () => {
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'cupitor-data', branch: 'main', other: null }) })).other).toBeNull()
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'cupitor-data', branch: 'main' }) })).other.login).toBe('trexsatya')
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages' }) })).other).toBeNull()
  })
  test('other equal to self is dropped; a repo without a branch is no repo', () => {
    expect(loadAccount(memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'cupitor-data', branch: 'main', other: { login: 'alice', repo: 'cupitor-data', branch: 'main' } }) })).other).toBeNull()
    const r = loadAccount(memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'cupitor-data' }) }))
    expect(r.repo).toBeNull(); expect(r.branch).toBeNull(); expect(r.login).toBe('alice')
  })
  test('clearAccount returns to guest', () => {
    const s = memStorage()
    saveAccount({ login: 'alice', repo: 'cupitor-data', branch: 'main', other: null }, s)
    clearAccount(s)
    expect(loadAccount(s).login).toBeNull()
  })
})

describe('normalizeUser / defaultOther', () => {
  test('fills name and branch, rejects entries without login or repo', () => {
    expect(normalizeUser({ login: 'bob', repo: 'cupitor-data' })).toEqual({ login: 'bob', name: 'bob', repo: 'cupitor-data', branch: 'main' })
    expect(normalizeUser({ login: 'bob' })).toBeNull()
    expect(normalizeUser(null)).toBeNull()
  })
  test('defaultOther is trexsatya for everyone but trexsatya', () => {
    expect(defaultOther(null).login).toBe('trexsatya')
    expect(defaultOther('alice').login).toBe('trexsatya')
    expect(defaultOther('trexsatya')).toBeNull()
  })
})

describe('sources', () => {
  test('guest: no self, other is the owner', () => {
    expect(sources(loadAccount(memStorage()))).toEqual({
      self: null, other: { owner: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages' } })
  })
  test('signed in with a repo: self is the repo', () => {
    expect(sources({ login: 'alice', repo: 'cupitor-data', branch: 'main', other: null })).toEqual({
      self: { owner: 'alice', repo: 'cupitor-data', branch: 'main' }, other: null })
  })
  test('signed in without a repo: no self', () => {
    expect(sources({ login: 'alice', repo: null, branch: null, other: OWNER }).self).toBeNull()
  })
})

describe('scopedKey', () => {
  test('owner and guest keep the plain key; other logins get a suffix', () => {
    expect(scopedKey('cupitor:recordings', loadAccount(memStorage()))).toBe('cupitor:recordings')
    expect(scopedKey('cupitor:recordings', { login: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages', other: null })).toBe('cupitor:recordings')
    expect(scopedKey('cupitor:recordings', { login: 'alice', repo: null, branch: null, other: null })).toBe('cupitor:recordings@alice')
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account-state.test.js`
Expected: FAIL — cannot find module `./account-state.js`.

- [ ] **Step 3: Create the module**

Create `public/language/account-state.js`:

```js
// The account record and what follows from it: which repo is "self" (writes
// go there), which repo is "other" (read-only layer), and how localStorage /
// IndexedDB names are scoped so two people's data on one device never mix.
// Pure: storage is injected (defaults to localStorage) so jest can drive it.
//
// Record shape in localStorage `cupitor:account`:
//   { login, repo, branch, other }
//   login  — GitHub login, null for a guest
//   repo / branch — the user's data repo; both null until setup created it
//   other  — a users.json entry { login, name, repo, branch } to layer on
//            read-only, or null for none. Absent → the default for the login.

export const ACCOUNT_KEY = 'cupitor:account'
export const USERS_CACHE_KEY = 'cupitor:users'

export const OWNER = Object.freeze({ login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' })
export const USERS_REPO = 'cupitor-users'
export const TEMPLATE_REPO = 'cupitor-data-template'
export const DATA_REPO = 'cupitor-data'

function store(storage) {
  if (storage) return storage
  return typeof localStorage !== 'undefined' ? localStorage : null
}

// A users.json entry made safe: login and repo are required, name defaults
// to the login, branch to main. Anything else is null.
export function normalizeUser(u) {
  if (!u || typeof u !== 'object') return null
  const { login, repo } = u
  if (typeof login !== 'string' || !login || typeof repo !== 'string' || !repo) return null
  return {
    login,
    name: typeof u.name === 'string' && u.name ? u.name : login,
    repo,
    branch: typeof u.branch === 'string' && u.branch ? u.branch : 'main',
  }
}

// Guests and every user but the owner start out reading the owner's library.
export function defaultOther(login) {
  return login === OWNER.login ? null : { ...OWNER }
}

export function loadAccount(storage) {
  const s = store(storage)
  let raw = null
  try { raw = s ? s.getItem(ACCOUNT_KEY) : null } catch (_) {}
  let v = null
  try { v = raw ? JSON.parse(raw) : null } catch (_) {}
  if (!v || typeof v !== 'object' || Array.isArray(v)) v = {}
  const login = typeof v.login === 'string' && v.login ? v.login : null
  const repo = login && typeof v.repo === 'string' && v.repo ? v.repo : null
  const branch = repo && typeof v.branch === 'string' && v.branch ? v.branch : null
  let other = ('other' in v) ? normalizeUser(v.other) : defaultOther(login)
  if (other && other.login === login) other = null
  return { login, repo: branch ? repo : null, branch, other }
}

export function saveAccount(state, storage) {
  const s = store(storage)
  if (!s) return
  const { login, repo, branch, other } = state
  s.setItem(ACCOUNT_KEY, JSON.stringify({ login, repo, branch, other: other ? normalizeUser(other) : null }))
}

export function clearAccount(storage) {
  const s = store(storage)
  if (!s) return
  s.removeItem(ACCOUNT_KEY)
}

// { self, other } as { owner, repo, branch } or null.
export function sources(state) {
  const self = state.login && state.repo && state.branch
    ? { owner: state.login, repo: state.repo, branch: state.branch }
    : null
  const o = state.other && (!self || state.other.login !== self.owner)
    ? { owner: state.other.login, repo: state.other.repo, branch: state.other.branch }
    : null
  return { self, other: o }
}

// Whose local data a storage key belongs to. A guest shares the device's
// plain keys with the owner (that is where the pre-account data lives); any
// other login gets its own suffix.
export function storageOwner(state) {
  return state.login || OWNER.login
}

export function scopedKey(base, state = loadAccount()) {
  const owner = storageOwner(state)
  return owner === OWNER.login ? base : `${base}@${owner}`
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account-state.test.js`
Expected: PASS (13 tests).

- [ ] **Step 5: Commit**

```bash
git add public/language/account-state.js public/language/account-state.test.js
git commit -m "language: account record, sources and owner-scoped storage keys

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: `data-source.js` — URLs and the write target

**Files:**
- Create: `public/language/data-source.js`
- Test: `public/language/data-source.test.js`

- [ ] **Step 1: Write the failing tests**

Create `public/language/data-source.test.js`:

```js
import {
  configure, readUrl, writeTarget, hasSelf, hasOther, source, langFromLocation, NoSelfRepoError,
} from './data-source.js'

const guest = { login: null, repo: null, branch: null, other: { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' } }
const alice = { login: 'alice', repo: 'cupitor-data', branch: 'main', other: { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' } }
const aliceNoRepo = { login: 'alice', repo: null, branch: null, other: guest.other }
const owner = { login: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages', other: null }

describe('readUrl', () => {
  test('guest: primary and other point at the owner repo; self is absent', () => {
    configure(guest)
    expect(readUrl('primary', 'srts/index.json', 'swedish'))
      .toBe('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/gh-pages/db/language/swedish/srts/index.json')
    expect(readUrl('other', '', 'spanish'))
      .toBe('https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/gh-pages/db/language/spanish')
    expect(() => readUrl('self', 'x', 'swedish')).toThrow(/no self source/)
    expect(hasSelf()).toBe(false); expect(hasOther()).toBe(true)
  })
  test('signed in with a repo: self and primary are the own repo', () => {
    configure(alice)
    expect(readUrl('self', 'vocabulary.txt', 'swedish'))
      .toBe('https://raw.githubusercontent.com/alice/cupitor-data/main/db/language/swedish/vocabulary.txt')
    expect(readUrl('primary', 'vocabulary.txt', 'swedish')).toBe(readUrl('self', 'vocabulary.txt', 'swedish'))
    expect(source('other')).toEqual({ owner: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages' })
  })
  test('owner with no other: other is absent', () => {
    configure(owner)
    expect(hasOther()).toBe(false)
    expect(() => readUrl('other', 'x', 'swedish')).toThrow(/no other source/)
  })
  test('unknown source name throws', () => {
    configure(guest)
    expect(() => readUrl('them', 'x', 'swedish')).toThrow(/unknown source/)
  })
})

describe('writeTarget', () => {
  test('is the self repo', () => {
    configure(alice)
    expect(writeTarget()).toEqual({ owner: 'alice', repo: 'cupitor-data', branch: 'main' })
    configure(owner)
    expect(writeTarget()).toEqual({ owner: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages' })
  })
  test('throws NoSelfRepoError for a guest and for a user without a repo', () => {
    configure(guest)
    expect(() => writeTarget()).toThrow(NoSelfRepoError)
    expect(() => writeTarget()).toThrow('Set up your repo to save changes')
    configure(aliceNoRepo)
    expect(() => writeTarget()).toThrow(NoSelfRepoError)
  })
})

describe('langFromLocation', () => {
  test('reads ?lang=, defaults to swedish', () => {
    expect(langFromLocation({ href: 'https://x/language.html?lang=spanish' })).toBe('spanish')
    expect(langFromLocation({ href: 'https://x/language.html' })).toBe('swedish')
    expect(langFromLocation(null)).toBe('swedish')
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/data-source.test.js`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Create the module**

Create `public/language/data-source.js`:

```js
// Where the language app reads from and writes to. Every raw URL and every
// GitHub write target in language.js comes from here; nothing else names an
// owner, repo or branch.
//
//   self    — the signed-in user's own repo (editable). Absent for a guest
//             and for a signed-in user whose repo is not set up yet.
//   other   — one other listed user's repo, read-only. Absent when "none".
//   primary — self when present, else other. What the single-source code
//             paths (practice log, resource base URL) use.
//
// Pure: the account state is read once from localStorage and can be set
// with configure() in tests; fetch is injected by the layered readers.

import { loadAccount, sources } from './account-state.js'
import { fetchWithRetry } from './net.js'

let _state = null
export function configure(state) { _state = state; resetLayerStats() }
function state() { return _state || (_state = loadAccount()) }
export function currentSources() { return sources(state()) }

export function langFromLocation(loc = (typeof window !== 'undefined' ? window.location : null)) {
  try {
    const v = new URL(loc.href).searchParams.get('lang')
    return v || 'swedish'
  } catch (_) { return 'swedish' }
}

export function rawBase(src, lang) {
  return `https://raw.githubusercontent.com/${src.owner}/${src.repo}/${src.branch}/db/language/${lang}`
}

export class NoSelfRepoError extends Error {
  constructor() { super('Set up your repo to save changes'); this.name = 'NoSelfRepoError' }
}

export function source(who) {
  const s = currentSources()
  if (who === 'self') return s.self
  if (who === 'other') return s.other
  if (who === 'primary') return s.self || s.other
  throw new Error(`data-source: unknown source "${who}"`)
}
export function hasSelf() { return !!currentSources().self }
export function hasOther() { return !!currentSources().other }

// Raw URL under db/language/<lang>/ for the given source. `path` may be ''
// for the directory itself.
export function readUrl(who, path, lang = langFromLocation()) {
  const src = source(who)
  if (!src) throw new Error(`data-source: no ${who} source`)
  const base = rawBase(src, lang)
  return path ? `${base}/${path}` : base
}

// { owner, repo, branch } of self. Writes never go anywhere else.
export function writeTarget() {
  const s = currentSources().self
  if (!s) throw new NoSelfRepoError()
  return { owner: s.owner, repo: s.repo, branch: s.branch }
}

// ---- layered reads (filled in by Task 7) ----
let _layerStats = { other: { hits: 0, misses: 0, errors: 0 } }
export function resetLayerStats() { _layerStats = { other: { hits: 0, misses: 0, errors: 0 } } }
export function layerStats() { return JSON.parse(JSON.stringify(_layerStats)) }
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/data-source.test.js`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add public/language/data-source.js public/language/data-source.test.js
git commit -m "language: data-source resolves read URLs and the single write target

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `language.js` stops naming the owner's repo (no behaviour change)

**Files:**
- Modify: `public/language/language.js`

With no account record, `source('primary')` and `writeTarget()` resolve to `trexsatya/trexsatya.github.io@gh-pages`, so every change here is output-identical. Verify by grep at the end: no `'trexsatya'`, `'trexsatya.github.io'` or `'gh-pages'` string literal may remain in code.

- [ ] **Step 1: Import the module**

Find the import block ending with `} from './net.js';` near the top of `public/language/language.js` and add after it:

```js
import {
  readUrl as _dsReadUrl,
  writeTarget as _dsWriteTarget,
  hasSelf as _dsHasSelf,
} from './data-source.js';
```

(`_dsHasSelf` is first used in Task 10; importing it now keeps the block stable.)

- [ ] **Step 2: Resource base URL**

Replace the function `getResourceUrl`:

```js
function getResourceUrl() {
  const value = getLangFromUrl();
  return `https://raw.githubusercontent.com/trexsatya/trexsatya.github.io/gh-pages/db/language/${value.fullName}`
}
```

with

```js
// Raw base for the primary source (own repo when set up, else the layered
// other). Single-source readers use it; layered readers go through
// data-source directly.
function getResourceUrl() {
  return _dsReadUrl('primary', '', getLangFromUrl().fullName)
}
```

- [ ] **Step 3: The `commitWithMerge` wrapper**

Replace

```js
function commitWithMerge(opts) {
  return _coreCommitWithMerge(opts, { githubUtils: window.GitHubUtils })
}
```

with

```js
// Every single-file write goes to self. Throws NoSelfRepoError (the "set up
// your repo" message) when there is no self; callers surface e.message.
function commitWithMerge(opts) {
  const t = _dsWriteTarget()
  return _coreCommitWithMerge({ branch: t.branch, ...opts },
    { githubUtils: window.GitHubUtils, owner: t.owner, repo: t.repo })
}

// A GitHub-API (uncached) read of a file in self.
function _selfGetFile(filePath) {
  const t = _dsWriteTarget()
  return window.GitHubUtils.getFile(t.owner, t.repo, filePath, '', t.branch)
}
```

- [ ] **Step 4: `commitMultipleFiles` call sites (4)**

Run `grep -n "repo: 'trexsatya.github.io'," public/language/language.js`. Each hit sits inside a `window.GitHubUtils.commitMultipleFiles({ ... })` call (in `flushPendingSrtEdits`, `migrateSrtPathsToNFC`, `deleteChannel`, `pushCapturedSubtitlesBatched`). In each, replace the three lines

```js
    owner: 'trexsatya',
    repo: 'trexsatya.github.io',
    branch: 'gh-pages',
```

(indentation varies) with

```js
    ..._dsWriteTarget(),
```

- [ ] **Step 5: `getFile` call sites (4)**

Run `grep -n "getFile('trexsatya', 'trexsatya.github.io'\|getFile($" public/language/language.js`.

In `fetchSrtIndexEntry` replace
```js
    const file = await window.GitHubUtils.getFile(
      'trexsatya', 'trexsatya.github.io', filePath, '', 'gh-pages'
    )
```
with `    const file = await _selfGetFile(filePath)`.

In `migrateSrtPathsToNFC` replace
```js
  const file = await window.GitHubUtils.getFile('trexsatya', 'trexsatya.github.io', indexPath, '', 'gh-pages')
```
with `  const file = await _selfGetFile(indexPath)`.

In `pushCapturedSubtitlesBatched` replace
```js
    const file = await window.GitHubUtils.getFile(
      'trexsatya', 'trexsatya.github.io', indexPath, '', 'gh-pages'
    )
```
with `    const file = await _selfGetFile(indexPath)`.

In `_fetchRemoteRecordings` replace
```js
      const f = await window.GitHubUtils.getFile('trexsatya', 'trexsatya.github.io', path, '', 'gh-pages')
```
with `      const f = await _selfGetFile(path)` and, a few lines below, replace
```js
      const r = await fetch(`https://api.github.com/repos/trexsatya/trexsatya.github.io/contents/${path}?ref=gh-pages`,
```
with
```js
      const s = _dsWriteTarget()
      const r = await fetch(`https://api.github.com/repos/${s.owner}/${s.repo}/contents/${path}?ref=${encodeURIComponent(s.branch)}`,
```

- [ ] **Step 6: `deleteFileWithLookup` call sites (3)**

Run `grep -n "const owner = 'trexsatya', repo = 'trexsatya.github.io'" public/language/language.js` (in `deleteSelectedMedia`, `_deleteDuplicateSrtEntry`, `_onUnavailableVideosDelete`'s helper). In each, replace that line with

```js
  const { owner, repo, branch } = _dsWriteTarget()
```

and in the `deleteFileWithLookup({ ... })` call that follows, replace `branch: 'gh-pages'` with `branch`.

- [ ] **Step 7: Verify nothing is left**

Run: `grep -n "'trexsatya'\|'trexsatya.github.io'\|'gh-pages'\|\"gh-pages\"\|raw.githubusercontent.com/trexsatya" public/language/language.js`
Expected: no output. (`grep -n "gh-pages" public/language/language.js` may still list comments and the confirm() text in `deleteChannel` — change that user-facing string to `from your repo` while here.)

- [ ] **Step 8: Tests and smoke check**

Run: `npx jest public/language`
Expected: all suites pass (language.js has no suite of its own; this guards the imports it shares).

Smoke: `yarn serve`, open `http://localhost:8080/language.html?lang=swedish` — subtitles load, search works.

- [ ] **Step 9: Commit**

```bash
git add public/language/language.js
git commit -m "language: read and write through data-source instead of a hardcoded repo

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `language.js` storage keys scoped by owner (no behaviour change for the owner)

**Files:**
- Modify: `public/language/language.js`

`scopedKey(base)` returns `base` unchanged for the owner and for a guest, so nothing moves on existing devices.

- [ ] **Step 1: Import**

Add to the data-source import block from Task 5:

```js
import { scopedKey as _scopedKey } from './account-state.js';
```

- [ ] **Step 2: Wrap each key**

Make these exact replacements (find each with grep; they are `const` declarations or small functions):

| Find | Replace with |
|---|---|
| `const PENDING_VOCAB_KEY = 'cupitor:pendingVocab'` | `const PENDING_VOCAB_KEY = _scopedKey('cupitor:pendingVocab')` |
| `const SRT_EDITS_KEY = 'cupitor:pendingSrtEdits'` | `const SRT_EDITS_KEY = _scopedKey('cupitor:pendingSrtEdits')` |
| `const CAPTURED_SUBTITLES_KEY = 'cupitor:capturedSubtitles'` | `const CAPTURED_SUBTITLES_KEY = _scopedKey('cupitor:capturedSubtitles')` |
| `const REC_KEY            = 'cupitor:recording'` | `const REC_KEY            = _scopedKey('cupitor:recording')` |
| `const REC_STATE_KEY      = 'cupitor:recording:state'` | `const REC_STATE_KEY      = _scopedKey('cupitor:recording:state')` |
| `const REC_COLLECTION_KEY = 'cupitor:recordings'` | `const REC_COLLECTION_KEY = _scopedKey('cupitor:recordings')` |
| `const REC_CURRENT_KEY    = 'cupitor:recording:current'` | `const REC_CURRENT_KEY    = _scopedKey('cupitor:recording:current')` |
| `const REC_CURRENT_EXT_KEY = 'cupitor:recording:currentExtId'` | `const REC_CURRENT_EXT_KEY = _scopedKey('cupitor:recording:currentExtId')` |
| `const REC_DIRTY_KEY = 'cupitor:recordings:dirty'` | `const REC_DIRTY_KEY = _scopedKey('cupitor:recordings:dirty')` |
| `const REC_LAST_PLAYED_KEY = 'cupitor:recLastPlayed'` | `const REC_LAST_PLAYED_KEY = _scopedKey('cupitor:recLastPlayed')` |
| `function _recordingsBaseKey() { return 'cupitor:recordings:base:' + recordingsFilePath() }` | `function _recordingsBaseKey() { return _scopedKey('cupitor:recordings:base:' + recordingsFilePath()) }` |

In `_practiceLogLocalKey` replace `` return `cupitor:practiceLog:${lang}` `` with `` return _scopedKey(`cupitor:practiceLog:${lang}`) ``.

In `_cacheDbName` replace `` return `${CUPITOR_CACHE_DB_PREFIX}-${lang}` `` with `` return _scopedKey(`${CUPITOR_CACHE_DB_PREFIX}-${lang}`) ``.

Leave device-level keys alone: `searches`, `xxx`, `searchNavHistory`, `cupitor:appSettings:*`, `cupitor:practiceLog:openedOnce`, `cupitor:openView`, `cupitor:playUnavailable`, `notifDebug`.

- [ ] **Step 3: Check and smoke**

Run: `grep -n "'cupitor:" public/language/language.js` — every pending-edit, recordings, practice-log and cache key is wrapped; only the device-level keys above are bare.
Run: `npx jest public/language` → PASS. Smoke in the browser: recordings and pending edits from before are still there (keys unchanged for the owner/guest).

- [ ] **Step 4: Commit**

```bash
git add public/language/language.js
git commit -m "language: per-owner names for pending edits, recordings, practice log and the subtitle cache

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `data-source.js` — layered reads and merge helpers

**Files:**
- Modify: `public/language/data-source.js`
- Test: `public/language/data-source.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/language/data-source.test.js`:

```js
import {
  readLayers, layerStats, mergeIndexLayers, parseCategorisation, mergeCategorisationLayers,
  mergeVocabularyLayers, withoutReadOnlyLines, mergeRecordingLayers,
} from './data-source.js'

const res = (status, text) => ({ ok: status < 400, status, text: async () => text })

describe('readLayers', () => {
  test('self then other, 404 is an empty layer (null text), stats count other', async () => {
    configure(alice)
    const calls = []
    const fetchFn = async (url) => {
      calls.push(url)
      return url.includes('/alice/') ? res(200, 'mine') : res(404, '')
    }
    const out = await readLayers('vocabulary.txt', { lang: 'swedish', fetchFn })
    expect(out).toEqual([
      { src: 'self', owner: 'alice', text: 'mine' },
      { src: 'other', owner: 'trexsatya', text: null },
    ])
    expect(calls[0]).toContain('/alice/cupitor-data/main/db/language/swedish/vocabulary.txt')
    expect(calls[1]).toContain('/trexsatya/trexsatya.github.io/gh-pages/db/language/swedish/vocabulary.txt')
    expect(layerStats().other).toEqual({ hits: 0, misses: 1, errors: 0 })
  })
  test('an other-layer failure is skipped with a notice; a self failure throws', async () => {
    configure(alice)
    const notices = []
    const failing = async (url) => (url.includes('/alice/') ? res(200, 'x') : res(500, ''))
    const out = await readLayers('srts/index.json', { lang: 'swedish', fetchFn: failing, retry: { tries: 1 }, onNotice: n => notices.push(n) })
    expect(out).toEqual([{ src: 'self', owner: 'alice', text: 'x' }])
    expect(notices).toHaveLength(1)
    expect(layerStats().other.errors).toBe(1)
    const selfFails = async () => res(500, '')
    await expect(readLayers('srts/index.json', { lang: 'swedish', fetchFn: selfFails, retry: { tries: 1 } })).rejects.toThrow(/HTTP 500/)
  })
  test('guest: only the other layer', async () => {
    configure(guest)
    const out = await readLayers('recordings.json', { lang: 'swedish', fetchFn: async () => res(200, '{}') })
    expect(out).toEqual([{ src: 'other', owner: 'trexsatya', text: '{}' }])
    expect(layerStats().other.hits).toBe(1)
  })
})

describe('mergeIndexLayers', () => {
  test('self wins by link; other entries are tagged read-only', () => {
    const merged = mergeIndexLayers([
      { src: 'self', owner: 'alice', text: JSON.stringify([{ link: 'a', name: 'A mine', source: 'yt' }]) },
      { src: 'other', owner: 'trexsatya', text: JSON.stringify([{ link: 'a', name: 'A theirs' }, { link: 'b', name: 'B' }]) },
    ])
    expect(merged).toEqual([
      { link: 'a', name: 'A mine', source: 'yt', src: 'self', owner: 'alice', readOnly: false },
      { link: 'b', name: 'B', src: 'other', owner: 'trexsatya', readOnly: true },
    ])
  })
  test('null text is an empty list; invalid self JSON throws; invalid other JSON is skipped', () => {
    expect(mergeIndexLayers([{ src: 'self', owner: 'a', text: null }])).toEqual([])
    expect(() => mergeIndexLayers([{ src: 'self', owner: 'a', text: '{' }])).toThrow(/index.json/)
    expect(mergeIndexLayers([{ src: 'self', owner: 'a', text: '[]' }, { src: 'other', owner: 'b', text: '{' }])).toEqual([])
  })
})

describe('categorisation', () => {
  test('parseCategorisation maps the file name to its category', () => {
    expect(parseCategorisation('Kids || x || y || file1\nfile2')).toEqual({ file1: 'Kids', file2: '        ' })
    expect(parseCategorisation(null)).toEqual({})
  })
  test('mergeCategorisationLayers: self wins', () => {
    expect(mergeCategorisationLayers([
      { src: 'self', text: 'A || x || y || f1' },
      { src: 'other', text: 'B || x || y || f1\nC || x || y || f2' },
    ])).toEqual({ f1: 'A', f2: 'C' })
  })
})

describe('vocabulary layers', () => {
  const selfText = '#Verbs\n(eat)|äta|\n#Nouns\n(cat)|katt|'
  const otherText = '#Verbs\n(eat)|äta|\n(run)|springa|\n#Adjectives\n(big)|stor|'
  test('other-only lines are appended and listed as read-only; shared lines are self', () => {
    const { vocab, readOnly } = mergeVocabularyLayers(selfText, otherText)
    expect(vocab.Verbs).toEqual(['(eat)|äta|', '(run)|springa|'])
    expect(vocab.Nouns).toEqual(['(cat)|katt|'])
    expect(vocab.Adjectives).toEqual(['(big)|stor|'])
    expect([...readOnly]).toEqual(['(run)|springa|', '(big)|stor|'])
  })
  test('no other text → self as is', () => {
    const { vocab, readOnly } = mergeVocabularyLayers(selfText, null)
    expect(vocab.Verbs).toEqual(['(eat)|äta|']); expect(readOnly.size).toBe(0)
  })
  test('withoutReadOnlyLines drops them and empty categories that came only from other', () => {
    const { vocab, readOnly } = mergeVocabularyLayers(selfText, otherText)
    expect(withoutReadOnlyLines(vocab, readOnly)).toEqual({ Verbs: ['(eat)|äta|'], Nouns: ['(cat)|katt|'] })
  })
})

describe('mergeRecordingLayers', () => {
  test('self wins by name; other collections are tagged read-only', () => {
    const out = mergeRecordingLayers(
      { Default: { items: { a: 1 } } },
      { Default: { items: { b: 2 } }, Theirs: { items: {} } })
    expect(out.Default).toEqual({ items: { a: 1 } })
    expect(out.Theirs).toEqual({ items: {}, readOnly: true, src: 'other' })
  })
  test('tolerates null sides', () => {
    expect(mergeRecordingLayers(null, null)).toEqual({})
    expect(mergeRecordingLayers(null, { X: { items: {} } }).X.readOnly).toBe(true)
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/data-source.test.js`
Expected: FAIL — `readLayers` and the merge helpers are not exported.

- [ ] **Step 3: Implement**

In `public/language/data-source.js`, add after the `import { fetchWithRetry } ...` line:

```js
import { parseVocabularyFile } from './vocab-merge.js'
```

Replace the `// ---- layered reads (filled in by Task 7) ----` section (keep `_layerStats`, `resetLayerStats`, `layerStats`) and append:

```js
// Fetch one file from every present source, self first. Each layer is
// { src, owner, text } with text null when the file is not there (404).
// The other layer may fail without stopping the app: it is dropped and
// `onNotice(message)` is called. A self failure that is not a 404 throws.
export async function readLayers(path, { lang = langFromLocation(), fetchFn, onNotice = () => {}, retry = {} } = {}) {
  const s = currentSources()
  const out = []
  for (const [src, cfg] of [['self', s.self], ['other', s.other]]) {
    if (!cfg) continue
    const url = `${rawBase(cfg, lang)}/${path}`
    try {
      const res = await fetchWithRetry(url, { ...retry, passthrough404: true }, fetchFn ? { fetch: fetchFn } : {})
      const text = res.status === 404 ? null : await res.text()
      if (src === 'other') { if (text == null) _layerStats.other.misses++; else _layerStats.other.hits++ }
      out.push({ src, owner: cfg.owner, text })
    } catch (e) {
      if (src === 'self') throw e
      _layerStats.other.errors++
      onNotice(`Could not load ${path} from ${cfg.owner}/${cfg.repo}: ${e && e.message}`)
    }
  }
  return out
}

function parseList(text, src, label) {
  if (text == null || !String(text).trim()) return []
  try {
    const v = JSON.parse(text)
    if (!Array.isArray(v)) throw new Error('not a list')
    return v
  } catch (e) {
    if (src === 'self') throw new Error(`${label} is not a valid list: ${e.message}`)
    return null // other: skip the layer
  }
}

// srts/index.json layers → one list. Key: link. Self wins; every entry
// carries src, owner and readOnly.
export function mergeIndexLayers(layers) {
  const out = []
  const seen = new Set()
  for (const layer of layers) {
    const arr = parseList(layer.text, layer.src, 'index.json')
    if (!arr) continue
    for (const it of arr) {
      if (!it || seen.has(it.link)) continue
      seen.add(it.link)
      out.push({ ...it, src: layer.src, owner: layer.owner, readOnly: layer.src === 'other' })
    }
  }
  return out
}

// srts/categorisation.txt: lines "category || a || b || fileName" (4 parts)
// or a bare file name (no category). Returns { fileName: category }.
export function parseCategorisation(text) {
  const out = {}
  if (text == null) return out
  String(text).split('\n').forEach(line => {
    if (!line) return
    const l = line.split(' || ')
    out[l[l.length - 1]] = l.length === 4 ? l[0] : '        '
  })
  return out
}

export function mergeCategorisationLayers(layers) {
  const out = {}
  for (const layer of layers) {
    const map = parseCategorisation(layer.text)
    for (const k of Object.keys(map)) if (!(k in out)) out[k] = map[k]
  }
  return out
}

// vocabulary.txt: self categories first; a line from other is appended to
// its category when self does not have that line. `readOnly` is the set of
// those appended lines (by text) — they never go into a commit.
export function mergeVocabularyLayers(selfText, otherText) {
  const vocab = parseVocabularyFile(selfText || '')
  const readOnly = new Set()
  if (!otherText) return { vocab, readOnly }
  const other = parseVocabularyFile(otherText)
  const selfLines = new Set(Object.values(vocab).flat().filter(l => l && l.trim()))
  for (const cat of Object.keys(other)) {
    if (cat === '__empty__') continue
    for (const line of other[cat]) {
      if (!line || !line.trim() || selfLines.has(line)) continue
      if (!vocab[cat]) vocab[cat] = []
      vocab[cat].push(line)
      readOnly.add(line)
    }
  }
  return { vocab, readOnly }
}

// The editable part of a merged vocabulary: read-only lines removed; a
// category that was entirely the other user's is dropped, and so is an
// empty pre-header bucket.
export function withoutReadOnlyLines(vocab, readOnly) {
  const out = {}
  for (const cat of Object.keys(vocab || {})) {
    const lines = vocab[cat] || []
    const kept = lines.filter(l => !readOnly.has(l))
    const fromOtherOnly = kept.length === 0 && lines.length > 0
    if (fromOtherOnly) continue
    if (cat === '__empty__' && !kept.some(l => l && l.trim())) continue
    out[cat] = kept
  }
  return out
}

// recordings.json: a collection name is the key; self wins. Other's
// collections are tagged so the UI hides edit controls and the persister
// skips them.
export function mergeRecordingLayers(selfColl, otherColl) {
  const out = {}
  for (const name of Object.keys(otherColl || {})) {
    const c = otherColl[name]
    if (c && typeof c === 'object') out[name] = { ...c, readOnly: true, src: 'other' }
  }
  for (const name of Object.keys(selfColl || {})) {
    const c = selfColl[name]
    if (c && typeof c === 'object') out[name] = c
  }
  return out
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/data-source.test.js`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add public/language/data-source.js public/language/data-source.test.js
git commit -m "language: layered reads with read-only tagging for index, categorisation, vocabulary and recordings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: `language.js` — layered subtitle index, categorisation, per-entry SRT URLs, read-only lines

**Files:**
- Modify: `public/language/language.js`

- [ ] **Step 1: Import the helpers**

Extend the data-source import block:

```js
import {
  readUrl as _dsReadUrl,
  writeTarget as _dsWriteTarget,
  hasSelf as _dsHasSelf,
  hasOther as _dsHasOther,
  readLayers as _dsReadLayers,
  mergeIndexLayers as _dsMergeIndexLayers,
  mergeCategorisationLayers as _dsMergeCategorisationLayers,
  mergeVocabularyLayers as _dsMergeVocabularyLayers,
  withoutReadOnlyLines as _dsWithoutReadOnlyLines,
  mergeRecordingLayers as _dsMergeRecordingLayers,
} from './data-source.js';
```

Add near it (module scope) a notice sink the account panel reads later:

```js
// Notices from the read-only layer ("could not load X from alice/cupitor-data").
window._otherLayerNotices = []
function _dsNotice(msg) { window._otherLayerNotices.push(msg); console.warn('[layer]', msg) }
```

- [ ] **Step 2: The index**

In `loadAllSubtitles` replace

```js
    let srtsRes = await _fetchWithRetry(`${getResourceUrl()}/srts/index.json`)
    let srts = await srtsRes.json()
```

with

```js
    // Own index first, the other user's under it; a missing file on either
    // side is an empty layer, so a freshly created data repo boots clean.
    const indexLayers = await _dsReadLayers('srts/index.json', { lang: getLangFromUrl().fullName, onNotice: _dsNotice })
    let srts = _dsMergeIndexLayers(indexLayers)
```

- [ ] **Step 3: Categorisation**

Replace the body of `fetchCategorisation`:

```js
async function fetchCategorisation() {
  const layers = await _dsReadLayers('srts/categorisation.txt', { lang: getLangFromUrl().fullName, onNotice: _dsNotice })
  return _dsMergeCategorisationLayers(layers)
}
```

- [ ] **Step 4: SRT files come from the entry's own source**

In `getSubtitlesForLink`, replace the two `_fetchSrtFile(...)` URLs:

```js
  const base = _dsReadUrl(srt.src || 'primary', 'srts', getLangFromUrl().fullName)
  const sv = await _fetchSrtFile(`${base}/${encodeURIComponent(svName)}`)
  ...
    en = await _fetchSrtFile(`${base}/${encodeURIComponent(enName)}`)
```

and tag the in-memory entry:

```js
  window.allSubtitles[link] = {sv, en, source, fileName: name, readOnly: !!srt.readOnly}
```

In the cache pass inside `loadAllSubtitles`, the code already builds `const indexLinks = new Set(srts.map(s => s.link))`; add next to it

```js
      const indexByLink = new Map(srts.map(s => [s.link, s]))
```

and inside the loop `for (const [link, entry] of cached)`, after `fetchedFrom: 'cache',` add the tag from the merged index:

```js
            readOnly: !!(indexByLink.get(link) || {}).readOnly,
```

- [ ] **Step 5: Hide ✎ on read-only lines**

Find the two lines in the subtitle renderer that build `<span class="edit-line-btn" title="Edit translation">✎</span>` (variables `lineMain` and `lineSec`). Introduce just above them:

```js
    const editBtn = subtitleFile.readOnly ? '' : '<span class="edit-line-btn" title="Edit translation">✎</span>'
```

and replace the literal `<span class="edit-line-btn" title="Edit translation">✎</span>` in both template strings with `${editBtn}`.

- [ ] **Step 6: Read-only entries are left out of delete tools**

In `_onUnavailableVideosDelete`, right after the list of picked links is collected (the code that reads `.unavail-pick:checked`), filter out read-only entries:

```js
  const readOnlyLinks = new Set((window.srts || []).filter(s => s && s.readOnly).map(s => s.link))
  const skipped = picked.filter(l => readOnlyLinks.has(l)).length
  picked = picked.filter(l => !readOnlyLinks.has(l))
  if (skipped) alert(`${skipped} video${skipped === 1 ? ' is' : 's are'} from the other user's library and cannot be deleted here.`)
  if (!picked.length) return
```

(Adapt the variable name to what the function uses for the chosen links; if it is `const`, change it to `let`.)

In `listChannels`, count only self entries in the deletable total: add `readOnly: true` to a channel when any of its videos is read-only:

```js
    if (!counts.has(ch)) counts.set(ch, { videos: 0, source: s.source || '', readOnly: false })
    counts.get(ch).videos += 1
    if (s.readOnly) counts.get(ch).readOnly = true
```
and map it through: `.map(([channel, meta]) => ({ channel, videos: meta.videos, source: meta.source, readOnly: meta.readOnly }))`.

In the channel manager HTML (function that builds `.ch-row`), render the Delete button only when `!c.readOnly`:

```js
          ${c.readOnly ? '<span class="ch-count" title="From the other user\'s library">read-only</span>' : '<button type="button" class="btn ch-delete rec-rec-danger" title="Delete channel"><span class="rec-rec-ico">🗑</span><span class="rec-rec-lbl">Delete</span></button>'}
```

- [ ] **Step 7: Tests and smoke**

Run: `npx jest public/language` → PASS.
Smoke (browser, guest): subtitles still load (now via `readLayers` from the other = owner layer); every line shows no ✎ (guest sees everything read-only) — expected, since a guest cannot write. The Settings → channel manager shows "read-only" instead of Delete.

- [ ] **Step 8: Commit**

```bash
git add public/language/language.js
git commit -m "language: subtitle index and categorisation are layered; lines from the other user are read-only

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: `language.js` — layered vocabulary

**Files:**
- Modify: `public/language/language.js`

- [ ] **Step 1: Load**

In `fetchVocabulary`, replace the non-localhost branch

```js
      res = await _fetchWithRetry(`${getResourceUrl()}/vocabulary.txt`)
      res = await res.text()
```

with

```js
      const layers = await _dsReadLayers('vocabulary.txt', { lang: getLangFromUrl().fullName, onNotice: _dsNotice })
      const selfLayer = layers.find(l => l.src === 'self')
      const otherLayer = layers.find(l => l.src === 'other')
      window._vocabularyOtherText = otherLayer ? otherLayer.text : null
      // A guest edits nothing, so the other layer is the whole vocabulary.
      res = selfLayer ? (selfLayer.text || '') : (otherLayer ? otherLayer.text : '')
      if (selfLayer) {
        window._vocabularyBaselineText = selfLayer.text || ''
        const merged = _dsMergeVocabularyLayers(selfLayer.text, window._vocabularyOtherText)
        window.vocabulary = merged.vocab
        window._vocabularyReadOnly = merged.readOnly
        res = null  // already applied
      }
```

and change the block that follows to only apply `res` when it is a string:

```js
    if (typeof res === 'string' && res) {
      window.vocabulary = parseVocabularyFile(res)
      window._vocabularyBaselineText = res
      window._vocabularyReadOnly = new Set()
    }
```

(For a guest the merged map has no self lines; `_vocabularyBaselineText` is the other text, which is harmless because a guest cannot commit.)

- [ ] **Step 2: Commit only self lines**

In `commitVocabularyToGithub`, replace `const localVocab = window.vocabulary` with

```js
  const readOnly = window._vocabularyReadOnly || new Set()
  const localVocab = _dsWithoutReadOnlyLines(window.vocabulary, readOnly)
```

and after the commit, where the pushed text is adopted, replace

```js
    window.vocabulary = parseVocabularyFile(finalText)
    window._vocabularyBaselineText = finalText
```

with

```js
    const merged = _dsMergeVocabularyLayers(finalText, window._vocabularyOtherText)
    window.vocabulary = merged.vocab
    window._vocabularyReadOnly = merged.readOnly
    window._vocabularyBaselineText = finalText
```

- [ ] **Step 3: Tests and smoke**

Run: `npx jest public/language` → PASS. Smoke as guest: the vocabulary dropdown is populated.

- [ ] **Step 4: Commit**

```bash
git add public/language/language.js
git commit -m "language: vocabulary is layered; lines from the other user never enter a commit

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: `language.js` — recordings: self remote merge, other read-only, UI gating

**Files:**
- Modify: `public/language/language.js`

- [ ] **Step 1: The self layer only merges into the editable collection**

In `loadRecordingsFromGithub`, replace `` const r = await fetch(`${getResourceUrl()}/recordings.json`, { cache: 'no-cache' }) `` with

```js
    if (!_dsHasSelf()) return null
    const r = await fetch(_dsReadUrl('self', 'recordings.json', getLangFromUrl().fullName), { cache: 'no-cache' })
```

At the top of `_mergeRemoteRecordingsIntoLocal` add:

```js
  if (!_dsHasSelf()) { await _loadOtherRecordings(); return }
```

and at its end (just before `_refreshRecordingSyncBtn()`), add `await _loadOtherRecordings()`.

Add this function right before `_mergeRemoteRecordingsIntoLocal`:

```js
// The other user's playlists, shown read-only beside our own. Never
// persisted: _persistableRecordings skips readOnly entries, and the next
// boot reloads them from their repo.
async function _loadOtherRecordings() {
  if (!_dsHasOther()) return
  try {
    const layers = await _dsReadLayers('recordings.json', { lang: getLangFromUrl().fullName, onNotice: _dsNotice })
    const other = layers.find(l => l.src === 'other')
    if (!other || !other.text || !other.text.trim()) return
    let coll = null
    try { coll = JSON.parse(other.text) } catch (e) { _dsNotice(`recordings.json from the other user is not valid JSON`); return }
    if (!coll || typeof coll !== 'object') return
    window._recordings = _dsMergeRecordingLayers(window._recordings || {}, coll)
    _updateRecordingUI()
  } catch (e) { console.warn('[recordings] other layer failed', e) }
}
```

- [ ] **Step 2: Never persist or push them**

In `_persistableRecordings` replace `if (all[n] && !all[n].external) out[n] = all[n]` with
`if (all[n] && !all[n].external && !all[n].readOnly) out[n] = all[n]`.

In `_adoptRecordings`, keep them across a merge like externals: replace the loop body `if (window._recordings[n] && window._recordings[n].external) externals[n] = window._recordings[n]` with
`if (window._recordings[n] && (window._recordings[n].external || window._recordings[n].readOnly)) externals[n] = window._recordings[n]`.

In `_saveRecording`, right after `const name = window._recording.currentName`, add:

```js
    if (window._recordings[name] && window._recordings[name].readOnly) return
```

- [ ] **Step 3: Hide edit and delete controls**

In the review dialog renderer (the function containing `const isVirtualCurrent = _isVirtual(currentName)`), add after that line:

```js
  const currentRec = window._recordings && window._recordings[currentName]
  const isReadOnlyCurrent = !!(currentRec && currentRec.readOnly)
```

In the header buttons template right below, add ` disabled` (like the virtual case) to `#recRecAddManual`, `#recRecTranslate`, `#recRecRename`, `#recRecDelete`, `#recRecSync` when `isReadOnlyCurrent`. Example for Rename:

```js
    <button type="button" id="recRecRename"    class="btn rec-rec-btn" title="Rename this playlist" aria-label="Rename this playlist"${isReadOnlyCurrent ? ' disabled' : ''}><span class="rec-rec-ico">✎</span><span class="rec-rec-lbl">Rename</span></button>
```

For `#recRecAddManual` and `#recRecTranslate` the existing `${isVirtualCurrent ? ' disabled' : ''}` becomes `${(isVirtualCurrent || isReadOnlyCurrent) ? ' disabled' : ''}`.

In the playlist `<option>` list, mark read-only ones: replace `const marker = _isVirtual(n) ? '🔗 ' : ''` with

```js
    const marker = _isVirtual(n) ? '🔗 ' : ((window._recordings[n] && window._recordings[n].readOnly) ? '🔒 ' : '')
```

Per-item manual edit button: find `` (isVirtualCurrent ? '' : `<button type="button" class="rec-manual-edit" `` and change the condition to `((isVirtualCurrent || isReadOnlyCurrent) ? '' : ...`.

Practice overlay: find the two buttons `class="practice-edit"` and `class="practice-delete"` in the practice template. The template is built once; gate at render time instead: in the function that opens the practice overlay for a playlist (the one that fills `.practice-info-head` / uses `_recordOfPlaylist()`), after the overlay element exists, add:

```js
  const _prRec = _recordOfPlaylist()
  $overlay.find('.practice-edit, .practice-delete').toggle(!(_prRec && _prRec.readOnly))
```

(use the overlay's jQuery variable name in that function.)

Guard the handlers too (a disabled attribute is not a contract): at the top of the `#recRecRename`, `#recRecDelete`, `#recRecAddManual`, `#recRecTranslate` and `#recRecSync` click handlers in the review dialog add:

```js
    const _cur = window._recordings && window._recordings[window._recording.currentName]
    if (_cur && _cur.readOnly) { alert('This playlist belongs to the other user and is read-only.'); return }
```

- [ ] **Step 4: Tests and smoke**

Run: `npx jest public/language` → PASS. Smoke as guest: the review dialog lists the owner's playlists with 🔒, Rename/Delete/Sync disabled; playing works.

- [ ] **Step 5: Commit**

```bash
git add public/language/language.js
git commit -m "language: the other user's playlists load read-only; own playlists sync only when a repo exists

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: `language.js` — guest write blocking

**Files:**
- Modify: `public/language/language.js`

`writeTarget()` already throws for a guest, so no write can land. This task gives a clear prompt instead of a thrown-error alert, and stops the legacy PAT `prompt()`.

- [ ] **Step 1: The guard**

Add after `_selfGetFile` (Task 5):

```js
// Writes need a self repo. Shows the account panel's set-up prompt (Task 19
// installs window.cupitorShowSetupPrompt) and returns false otherwise.
function _requireSelf() {
  if (_dsHasSelf()) return true
  const show = window.cupitorShowSetupPrompt
  if (typeof show === 'function') show('Set up your repo to save changes.')
  else alert('Set up your repo to save changes.')
  return false
}
```

- [ ] **Step 2: Guard each entry point**

Add `if (!_requireSelf()) return` as the first statement of each of these functions (find with `grep -n "^async function <name>"`):

- `commitVocabularyToGithub`
- `_commitPracticeLogToGithub`
- `flushPendingSrtEdits` — return `{ committed: false, reason: 'no-repo' }` instead of bare `return`
- `saveStarredLines`
- `uploadSrtToGithub`
- `deleteSelectedMedia`
- `_deleteDuplicateSrtEntry`
- `_onUnavailableVideosDelete`
- `upsertSrtIndexEntry`
- `migrateSrtPathsToNFC`
- `deleteChannel`
- `pushCapturedSubtitlesBatched` — return `{ committed: false, reason: 'no-repo' }`
- `syncRecordingsToGithub`

- [ ] **Step 3: No PAT prompt**

Near the top of `language.js` (after the imports) add:

```js
// The account panel owns sign-in; the legacy in-page PAT prompt never fires.
window._suppressGHTokenPrompt = true
```

- [ ] **Step 4: Tests and smoke**

Run: `npx jest public/language` → PASS. Smoke as guest: Settings → "Sync edits" with queued edits shows the set-up alert; nothing is sent (check the Network tab for no `api.github.com` PUT/POST).

- [ ] **Step 5: Commit**

```bash
git add public/language/language.js
git commit -m "language: writes without an own repo stop at a set-up prompt

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: `account.js` — users list

**Files:**
- Create: `public/language/account.js`
- Test: `public/language/account.test.js`

- [ ] **Step 1: Write the failing tests**

Create `public/language/account.test.js`:

```js
import { USERS_CACHE_KEY } from './account-state.js'
import { parseUsers, cachedUsers, fetchUsers, ownerEntry, USERS_RAW_URL } from './account.js'

export function memStorage(init = {}) {
  const m = new Map(Object.entries(init))
  return {
    getItem: k => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: k => m.delete(k),
    dump: () => Object.fromEntries(m),
  }
}
const textRes = (status, text) => ({ ok: status < 400, status, text: async () => text })

describe('users list', () => {
  const list = [{ login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' }, { login: 'alice', repo: 'cupitor-data' }]

  test('parseUsers normalises and drops junk; the owner is always present', () => {
    expect(parseUsers(JSON.stringify([{ login: 'alice', repo: 'cupitor-data' }, { nope: 1 }]))).toEqual([
      ownerEntry(), { login: 'alice', name: 'alice', repo: 'cupitor-data', branch: 'main' },
    ])
    expect(() => parseUsers('{}')).toThrow(/users.json/)
  })

  test('fetchUsers fetches the raw file, caches it, returns it', async () => {
    const storage = memStorage()
    const fetchFn = jest.fn(async () => textRes(200, JSON.stringify(list)))
    const users = await fetchUsers({ fetchFn, storage })
    expect(fetchFn.mock.calls[0][0]).toBe(USERS_RAW_URL)
    expect(users.map(u => u.login)).toEqual(['trexsatya', 'alice'])
    expect(JSON.parse(storage.getItem(USERS_CACHE_KEY)).map(u => u.login)).toEqual(['trexsatya', 'alice'])
  })

  test('network failure → cached list; no cache → only the owner', async () => {
    const storage = memStorage({ [USERS_CACHE_KEY]: JSON.stringify(list) })
    const failing = async () => { throw new Error('offline') }
    expect((await fetchUsers({ fetchFn: failing, storage })).map(u => u.login)).toEqual(['trexsatya', 'alice'])
    expect(await fetchUsers({ fetchFn: failing, storage: memStorage() })).toEqual([ownerEntry()])
    expect(await fetchUsers({ fetchFn: async () => textRes(500, ''), storage: memStorage() })).toEqual([ownerEntry()])
  })

  test('cachedUsers tolerates a broken cache', () => {
    expect(cachedUsers(memStorage({ [USERS_CACHE_KEY]: '{' }))).toBeNull()
    expect(cachedUsers(memStorage())).toBeNull()
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Create the module**

Create `public/language/account.js`:

```js
// Account operations against GitHub: who am I, the users list, the setup
// steps that give a user a data repo and a seat in users.json, and the
// browser-side token. Every GitHub call goes through an injected adapter
// `gh` = { request, getFile, putFile } (window.GitHubUtils in production),
// so jest drives it with fakes.

import {
  OWNER, USERS_REPO, TEMPLATE_REPO, DATA_REPO, USERS_CACHE_KEY,
  loadAccount, saveAccount, normalizeUser, defaultOther,
} from './account-state.js'

export const USERS_RAW_URL = `https://raw.githubusercontent.com/${OWNER.login}/${USERS_REPO}/main/users.json`

function store(storage) {
  if (storage) return storage
  return typeof localStorage !== 'undefined' ? localStorage : null
}

export function ownerEntry() { return { ...OWNER } }

// ---- users list ----

// users.json text → normalised entries, the owner first. Not a list → throws.
export function parseUsers(text) {
  let v
  try { v = JSON.parse(text) } catch (e) { throw new Error('users.json is not valid JSON') }
  if (!Array.isArray(v)) throw new Error('users.json is not a list')
  const users = v.map(normalizeUser).filter(Boolean).filter(u => u.login !== OWNER.login)
  return [ownerEntry(), ...users]
}

export function cachedUsers(storage) {
  const s = store(storage)
  try {
    const raw = s && s.getItem(USERS_CACHE_KEY)
    if (!raw) return null
    const v = JSON.parse(raw)
    return Array.isArray(v) ? parseUsers(JSON.stringify(v)) : null
  } catch (_) { return null }
}

// Fresh list when the network answers, else the cached one, else the owner.
export async function fetchUsers({ fetchFn = (typeof fetch !== 'undefined' ? fetch : null), storage } = {}) {
  const s = store(storage)
  try {
    const r = await fetchFn(USERS_RAW_URL, { cache: 'no-store' })
    if (!r.ok) throw new Error('HTTP ' + r.status)
    const users = parseUsers(await r.text())
    try { if (s) s.setItem(USERS_CACHE_KEY, JSON.stringify(users)) } catch (_) {}
    return users
  } catch (_) {
    return cachedUsers(s) || [ownerEntry()]
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: users list from cupitor-users with cache and owner fallback

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 13: `account.js` — login and repo detection

**Files:**
- Modify: `public/language/account.js`
- Test: `public/language/account.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/language/account.test.js`:

```js
import { fetchLogin, adoptLogin } from './account.js'
import { ACCOUNT_KEY, loadAccount } from './account-state.js'

// A fake GitHub: routes map "METHOD /path" to a JSON reply, a function, or
// an Error(`GitHub API error <status>: ...`) to throw. Calls are recorded.
export function fakeGh(routes) {
  const calls = []
  const b64 = s => Buffer.from(s, 'utf8').toString('base64')
  const hit = async (method, path, body) => {
    const key = `${method} ${path.split('?')[0]}`
    calls.push(key)
    let r = routes[key]
    if (typeof r === 'function') r = await r(body, path)
    if (r === undefined) throw new Error(`GitHub API error 404: Not Found (${key})`)
    if (r instanceof Error) throw r
    return r
  }
  return {
    calls,
    request: hit,
    getFile: async (owner, repo, filePath, _t, branch) => {
      const r = await hit('GET', `/repos/${owner}/${repo}/contents/${filePath}?ref=${branch}`)
      return { content: r.text, sha: r.sha }
    },
    putFile: (owner, repo, filePath, content, message, sha, _t, branch) =>
      hit('PUT', `/repos/${owner}/${repo}/contents/${filePath}`, { content, message, sha, branch }),
  }
}
export const err = (status, msg = 'x') => new Error(`GitHub API error ${status}: ${msg}`)

describe('fetchLogin', () => {
  test('GET /user → { login, name }', async () => {
    const gh = fakeGh({ 'GET /user': { login: 'alice', name: 'Alice' } })
    expect(await fetchLogin(gh)).toEqual({ login: 'alice', name: 'Alice' })
  })
  test('401 (no or bad token) → null; other failures throw', async () => {
    expect(await fetchLogin(fakeGh({ 'GET /user': err(401, 'Bad credentials') }))).toBeNull()
    await expect(fetchLogin(fakeGh({ 'GET /user': err(500) }))).rejects.toThrow(/500/)
  })
})

describe('adoptLogin', () => {
  test('the owner gets the owner repo and no other', async () => {
    const storage = memStorage()
    const state = await adoptLogin({ login: 'trexsatya', name: 'Satya' }, { gh: fakeGh({}), storage })
    expect(state).toEqual({ login: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages', other: null })
    expect(loadAccount(storage).login).toBe('trexsatya')
  })
  test('a user whose data repo exists is ready; one without is signed in with no repo', async () => {
    const ready = fakeGh({ 'GET /repos/alice/cupitor-data/contents/cupitor.json': { sha: 's' } })
    expect(await adoptLogin({ login: 'alice' }, { gh: ready, storage: memStorage() }))
      .toEqual({ login: 'alice', repo: 'cupitor-data', branch: 'main', other: ownerEntry() })
    expect(await adoptLogin({ login: 'bob' }, { gh: fakeGh({}), storage: memStorage() }))
      .toEqual({ login: 'bob', repo: null, branch: null, other: ownerEntry() })
  })
  test('the same login signing in again keeps its chosen other and repo name', async () => {
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'my-data', branch: 'main', other: null }) })
    const gh = fakeGh({ 'GET /repos/alice/my-data/contents/cupitor.json': { sha: 's' } })
    expect(await adoptLogin({ login: 'alice' }, { gh, storage })).toEqual({ login: 'alice', repo: 'my-data', branch: 'main', other: null })
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js -t "fetchLogin|adoptLogin"`
Expected: FAIL — not exported.

- [ ] **Step 3: Implement**

Append to `public/language/account.js`:

```js
// ---- GitHub adapter helpers ----

export function defaultGh() {
  const u = typeof window !== 'undefined' ? window.GitHubUtils : null
  if (!u) throw new Error('account: GitHubUtils is not loaded')
  return { request: u.request, getFile: u.getFile, putFile: u.putFile }
}
function statusOf(err) {
  const m = /GitHub API error (\d+)/.exec(String(err && err.message))
  return m ? Number(m[1]) : 0
}
const isNotFound = e => statusOf(e) === 404

export class SetupError extends Error {
  constructor(step, code, message) { super(message); this.name = 'SetupError'; this.step = step; this.code = code }
}

async function repoHasMarker(gh, login, repo) {
  try { await gh.request('GET', `/repos/${login}/${repo}/contents/cupitor.json`); return true }
  catch (e) { if (isNotFound(e)) return false; throw e }
}

// ---- who am I ----

// { login, name } for the token in use, null when there is none (401).
export async function fetchLogin(gh = defaultGh()) {
  try {
    const u = await gh.request('GET', '/user')
    return u && u.login ? { login: u.login, name: u.name || u.login } : null
  } catch (e) {
    if (statusOf(e) === 401 || statusOf(e) === 403) return null
    throw e
  }
}

// Record a login: the owner is always ready; anyone else is ready when their
// data repo (the name used before, else cupitor-data) carries cupitor.json.
export async function adoptLogin(me, { gh = defaultGh(), storage } = {}) {
  const prev = loadAccount(storage)
  let repo = null, branch = null
  if (me.login === OWNER.login) {
    repo = OWNER.repo; branch = OWNER.branch
  } else {
    const name = (prev.login === me.login && prev.repo) || DATA_REPO
    if (await repoHasMarker(gh, me.login, name)) { repo = name; branch = 'main' }
  }
  const other = prev.login === me.login ? prev.other : defaultOther(me.login)
  saveAccount({ login: me.login, repo, branch, other }, storage)
  return loadAccount(storage)
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: login lookup and data-repo detection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 14: `account.js` — setup step 1, the data repo

**Files:**
- Modify: `public/language/account.js`
- Test: `public/language/account.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/language/account.test.js`:

```js
import { ensureDataRepo, SetupError } from './account.js'

const noSleep = async () => {}
function clock(start = 0) { let t = start; return { now: () => t, tick: ms => { t += ms } } }

describe('ensureDataRepo', () => {
  test('from scratch: generates from the template and waits for cupitor.json', async () => {
    let created = false, polls = 0
    const gh = fakeGh({
      'GET /repos/alice/cupitor-data': () => (created ? { name: 'cupitor-data' } : err(404)),
      'POST /repos/trexsatya/cupitor-data-template/generate': (body) => {
        expect(body).toEqual({ owner: 'alice', name: 'cupitor-data', private: false, description: 'Cupitor language data' })
        created = true; return { name: 'cupitor-data' }
      },
      'GET /repos/alice/cupitor-data/contents/cupitor.json': () => (++polls >= 2 ? { sha: 's' } : err(404)),
    })
    const steps = []
    const out = await ensureDataRepo({ login: 'alice', gh, sleep: noSleep, now: clock().now, report: (s, st) => steps.push(`${s}:${st}`) })
    expect(out).toEqual({ repo: 'cupitor-data', branch: 'main', created: true })
    expect(gh.calls).toContain('POST /repos/trexsatya/cupitor-data-template/generate')
    expect(steps).toEqual(['repo:checking', 'repo:creating', 'repo:done'])
  })
  test('already done: no generate call', async () => {
    const gh = fakeGh({
      'GET /repos/alice/cupitor-data': { name: 'cupitor-data' },
      'GET /repos/alice/cupitor-data/contents/cupitor.json': { sha: 's' },
    })
    expect(await ensureDataRepo({ login: 'alice', gh, sleep: noSleep, now: clock().now })).toEqual({ repo: 'cupitor-data', branch: 'main', created: false })
    expect(gh.calls).not.toContain('POST /repos/trexsatya/cupitor-data-template/generate')
  })
  test('a repo of that name that is not a Cupitor data repo → repo_taken', async () => {
    const gh = fakeGh({ 'GET /repos/alice/cupitor-data': { name: 'cupitor-data' } })
    const p = ensureDataRepo({ login: 'alice', gh, sleep: noSleep, now: clock().now })
    await expect(p).rejects.toThrow(SetupError)
    await expect(p).rejects.toMatchObject({ step: 'repo', code: 'repo_taken' })
  })
  test('a different repo name is honoured', async () => {
    const gh = fakeGh({
      'GET /repos/alice/my-cupitor': { name: 'my-cupitor' },
      'GET /repos/alice/my-cupitor/contents/cupitor.json': { sha: 's' },
    })
    expect((await ensureDataRepo({ login: 'alice', repoName: 'my-cupitor', gh, sleep: noSleep, now: clock().now })).repo).toBe('my-cupitor')
  })
  test('generation that never shows cupitor.json within 30 s → timeout', async () => {
    const c = clock()
    const gh = fakeGh({
      'GET /repos/alice/cupitor-data': err(404),
      'POST /repos/trexsatya/cupitor-data-template/generate': { name: 'cupitor-data' },
    })
    const p = ensureDataRepo({ login: 'alice', gh, sleep: async () => c.tick(10000), now: c.now })
    await expect(p).rejects.toMatchObject({ step: 'repo', code: 'timeout' })
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js -t ensureDataRepo`
Expected: FAIL — not exported.

- [ ] **Step 3: Implement**

Append to `public/language/account.js`:

```js
// ---- setup step 1: the data repo ----

const SETUP_WAIT_MS = 30000
const SETUP_POLL_MS = 2000
const defaultSleep = ms => new Promise(r => setTimeout(r, ms))

async function repoExists(gh, login, repo) {
  try { await gh.request('GET', `/repos/${login}/${repo}`); return true }
  catch (e) { if (isNotFound(e)) return false; throw e }
}

// Idempotent: checks before acting, so a retry resumes where it failed.
export async function ensureDataRepo({ login, repoName = DATA_REPO, gh = defaultGh(), sleep = defaultSleep, now = Date.now, report = () => {} }) {
  report('repo', 'checking')
  if (await repoExists(gh, login, repoName)) {
    if (await repoHasMarker(gh, login, repoName)) { report('repo', 'done'); return { repo: repoName, branch: 'main', created: false } }
    throw new SetupError('repo', 'repo_taken', `${login}/${repoName} exists but is not a Cupitor data repo. Choose another name.`)
  }
  report('repo', 'creating')
  await gh.request('POST', `/repos/${OWNER.login}/${TEMPLATE_REPO}/generate`,
    { owner: login, name: repoName, private: false, description: 'Cupitor language data' })
  // GitHub fills a generated repo in asynchronously; the marker file says it is there.
  const deadline = now() + SETUP_WAIT_MS
  while (!(await repoHasMarker(gh, login, repoName))) {
    if (now() > deadline) throw new SetupError('repo', 'timeout', 'GitHub is still creating the repo. Retry in a moment.')
    await sleep(SETUP_POLL_MS)
  }
  report('repo', 'done')
  return { repo: repoName, branch: 'main', created: true }
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: setup creates the data repo from the template, resumable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 15: `account.js` — setup step 2, the listing PR

**Files:**
- Modify: `public/language/account.js`
- Test: `public/language/account.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/language/account.test.js`:

```js
import { listingStatus, ensureListing } from './account.js'

const usersFile = (arr) => ({ text: JSON.stringify(arr), sha: 'U1' })
const upstreamUsers = usersFile([{ login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' }])
const prsPath = 'GET /repos/trexsatya/cupitor-users/pulls'

describe('listingStatus', () => {
  const base = { 'GET /repos/trexsatya/cupitor-users/contents/users.json': upstreamUsers }
  test('in users.json → listed', async () => {
    const gh = fakeGh({ 'GET /repos/trexsatya/cupitor-users/contents/users.json': usersFile([{ login: 'alice', repo: 'cupitor-data' }]) })
    expect(await listingStatus({ login: 'alice', gh })).toBe('listed')
  })
  test('open PR → awaiting; merged → listed; closed unmerged → not_approved; none → none', async () => {
    expect(await listingStatus({ login: 'alice', gh: fakeGh({ ...base, [prsPath]: [{ state: 'open', merged_at: null }] }) })).toBe('awaiting')
    expect(await listingStatus({ login: 'alice', gh: fakeGh({ ...base, [prsPath]: [{ state: 'closed', merged_at: '2026-01-01' }] }) })).toBe('listed')
    expect(await listingStatus({ login: 'alice', gh: fakeGh({ ...base, [prsPath]: [{ state: 'closed', merged_at: null }] }) })).toBe('not_approved')
    expect(await listingStatus({ login: 'alice', gh: fakeGh({ ...base, [prsPath]: [] }) })).toBe('none')
  })
  test('asks for exactly the add-<login> head', async () => {
    const gh = fakeGh({ ...base, [prsPath]: (_b, path) => { expect(path).toBe('/repos/trexsatya/cupitor-users/pulls?state=all&head=alice%3Aadd-alice'); return [] } })
    await listingStatus({ login: 'alice', gh })
  })
})

describe('ensureListing', () => {
  // A GitHub where nothing has happened yet; each write flips the state the
  // next read sees, so the same fake can be replayed from any failure point.
  function world({ forked = false, branch = false, committed = false, pr = false, failAt = null } = {}) {
    const st = { forked, branch, committed, pr }
    const fail = (name) => { if (failAt === name) throw err(500, `boom at ${name}`) }
    const forkUsers = () => usersFile(st.committed
      ? [{ login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' }, { login: 'alice', name: 'Alice', repo: 'cupitor-data', branch: 'main' }]
      : [{ login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' }])
    const gh = fakeGh({
      'GET /repos/trexsatya/cupitor-users/contents/users.json': upstreamUsers,
      [prsPath]: () => (st.pr ? [{ state: 'open', merged_at: null }] : []),
      'GET /repos/alice/cupitor-users': () => (st.forked ? { fork: true } : err(404)),
      'POST /repos/trexsatya/cupitor-users/forks': () => { fail('fork'); st.forked = true; return {} },
      'POST /repos/alice/cupitor-users/merge-upstream': () => { fail('sync'); return { message: 'ok' } },
      'GET /repos/alice/cupitor-users/git/ref/heads/main': { object: { sha: 'MAIN' } },
      'POST /repos/alice/cupitor-users/git/refs': (body) => {
        fail('branch')
        expect(body).toEqual({ ref: 'refs/heads/add-alice', sha: 'MAIN' })
        if (st.branch) throw err(422, 'Reference already exists')
        st.branch = true; return {}
      },
      'GET /repos/alice/cupitor-users/contents/users.json': () => forkUsers(),
      'PUT /repos/alice/cupitor-users/contents/users.json': (body) => {
        fail('commit')
        expect(body.branch).toBe('add-alice'); expect(body.sha).toBe('U1')
        expect(JSON.parse(body.content).find(u => u.login === 'alice')).toEqual({ login: 'alice', name: 'Alice', repo: 'cupitor-data', branch: 'main' })
        st.committed = true; return {}
      },
      'POST /repos/trexsatya/cupitor-users/pulls': (body) => {
        fail('pr')
        expect(body).toMatchObject({ head: 'alice:add-alice', base: 'main', title: 'Add alice' })
        if (st.pr) throw err(422, 'A pull request already exists')
        st.pr = true; return { number: 7 }
      },
    })
    return { gh, st }
  }
  const args = (gh) => ({ login: 'alice', name: 'Alice', repo: 'cupitor-data', branch: 'main', gh, sleep: noSleep, now: clock().now })

  test('from scratch: fork, sync, branch, commit, PR → awaiting', async () => {
    const { gh, st } = world()
    expect(await ensureListing(args(gh))).toBe('awaiting')
    expect(st).toEqual({ forked: true, branch: true, committed: true, pr: true })
    expect(gh.calls.filter(c => c.startsWith('POST'))).toEqual([
      'POST /repos/trexsatya/cupitor-users/forks',
      'POST /repos/alice/cupitor-users/merge-upstream',
      'POST /repos/alice/cupitor-users/git/refs',
      'POST /repos/trexsatya/cupitor-users/pulls',
    ])
  })
  test.each(['fork', 'sync', 'branch', 'commit', 'pr'])('fails at %s, then a retry finishes', async (at) => {
    const { gh, st } = world({ failAt: at })
    await expect(ensureListing(args(gh))).rejects.toMatchObject({ step: 'listing' })
    const again = world({ ...st })
    expect(await ensureListing(args(again.gh))).toBe('awaiting')
    expect(again.st.pr).toBe(true)
  })
  test('each step already done is skipped', async () => {
    const { gh } = world({ forked: true, branch: true, committed: true })
    expect(await ensureListing(args(gh))).toBe('awaiting')
    expect(gh.calls).not.toContain('POST /repos/trexsatya/cupitor-users/forks')
    expect(gh.calls).not.toContain('PUT /repos/alice/cupitor-users/contents/users.json')
    expect(gh.calls).toContain('POST /repos/trexsatya/cupitor-users/pulls')
  })
  test('already listed or awaiting: nothing is written', async () => {
    const { gh } = world({ pr: true })
    expect(await ensureListing(args(gh))).toBe('awaiting')
    expect(gh.calls.some(c => c.startsWith('POST') || c.startsWith('PUT'))).toBe(false)
  })
  test('a fork that never appears within 30 s → timeout', async () => {
    const c = clock()
    const gh = fakeGh({
      'GET /repos/trexsatya/cupitor-users/contents/users.json': upstreamUsers,
      [prsPath]: [],
      'GET /repos/alice/cupitor-users': err(404),
      'POST /repos/trexsatya/cupitor-users/forks': {},
    })
    await expect(ensureListing({ ...args(gh), sleep: async () => c.tick(10000), now: c.now })).rejects.toMatchObject({ step: 'listing', code: 'timeout' })
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js -t "listingStatus|ensureListing"`
Expected: FAIL — not exported.

- [ ] **Step 3: Implement**

Append to `public/language/account.js`:

```js
// ---- setup step 2: a seat in users.json ----

const addBranch = login => `add-${login}`

async function readUsersJson(gh, owner, branch) {
  const f = await gh.getFile(owner, USERS_REPO, 'users.json', '', branch)
  return { users: parseUsers(f.content), sha: f.sha }
}

// 'listed' | 'awaiting' | 'not_approved' | 'none'
export async function listingStatus({ login, gh = defaultGh() }) {
  const { users } = await readUsersJson(gh, OWNER.login, 'main')
  if (users.some(u => u.login === login)) return 'listed'
  const head = encodeURIComponent(`${login}:${addBranch(login)}`)
  const prs = await gh.request('GET', `/repos/${OWNER.login}/${USERS_REPO}/pulls?state=all&head=${head}`)
  if (!Array.isArray(prs) || !prs.length) return 'none'
  if (prs.some(p => p.state === 'open')) return 'awaiting'
  if (prs.some(p => p.merged_at)) return 'listed'
  return 'not_approved'
}

function wrapStep(step, e) {
  if (e instanceof SetupError) return e
  return new SetupError(step, 'failed', e && e.message ? e.message : String(e))
}

// Idempotent: every sub-step checks before acting.
export async function ensureListing({ login, name, repo, branch, gh = defaultGh(), sleep = defaultSleep, now = Date.now, report = () => {} }) {
  report('listing', 'checking')
  try {
    const current = await listingStatus({ login, gh })
    if (current !== 'none') { report('listing', 'done'); return current }
    report('listing', 'forking')
    if (!(await repoExists(gh, login, USERS_REPO))) {
      await gh.request('POST', `/repos/${OWNER.login}/${USERS_REPO}/forks`, { default_branch_only: true })
      const deadline = now() + SETUP_WAIT_MS
      while (!(await repoExists(gh, login, USERS_REPO))) {
        if (now() > deadline) throw new SetupError('listing', 'timeout', 'GitHub is still creating your fork. Retry in a moment.')
        await sleep(SETUP_POLL_MS)
      }
    }
    report('listing', 'syncing')
    await gh.request('POST', `/repos/${login}/${USERS_REPO}/merge-upstream`, { branch: 'main' })

    report('listing', 'branching')
    const head = await gh.request('GET', `/repos/${login}/${USERS_REPO}/git/ref/heads/main`)
    try {
      await gh.request('POST', `/repos/${login}/${USERS_REPO}/git/refs`, { ref: `refs/heads/${addBranch(login)}`, sha: head.object.sha })
    } catch (e) { if (statusOf(e) !== 422) throw e } // 422: the branch is already there

    report('listing', 'committing')
    const { users, sha } = await readUsersJson(gh, login, addBranch(login))
    if (!users.some(u => u.login === login)) {
      users.push({ login, name: name || login, repo, branch })
      await gh.putFile(login, USERS_REPO, 'users.json', JSON.stringify(users, null, 2) + '\n', `Add ${login}`, sha, '', addBranch(login))
    }

    report('listing', 'opening-pr')
    try {
      await gh.request('POST', `/repos/${OWNER.login}/${USERS_REPO}/pulls`, {
        title: `Add ${login}`, head: `${login}:${addBranch(login)}`, base: 'main',
        body: `Adds ${login} (${login}/${repo}, branch ${branch}) to users.json.`,
      })
    } catch (e) { if (statusOf(e) !== 422) throw e } // 422: a PR for this head exists
    report('listing', 'done')
    return 'awaiting'
  } catch (e) {
    throw wrapStep('listing', e)
  }
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: setup forks cupitor-users, commits the entry and opens the PR, resumable

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 16: `account.js` — `runSetup` orchestration

**Files:**
- Modify: `public/language/account.js`
- Test: `public/language/account.test.js`

- [ ] **Step 1: Write the failing tests**

Append to `public/language/account.test.js`:

```js
import { runSetup } from './account.js'

describe('runSetup', () => {
  test('repo then listing; the account record gets the repo as soon as it exists', async () => {
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: null, branch: null }) })
    const gh = fakeGh({
      'GET /repos/alice/cupitor-data': { name: 'cupitor-data' },
      'GET /repos/alice/cupitor-data/contents/cupitor.json': { sha: 's' },
      'GET /repos/trexsatya/cupitor-users/contents/users.json': usersFile([{ login: 'alice', repo: 'cupitor-data' }]),
    })
    const out = await runSetup({ login: 'alice', name: 'Alice', gh, storage, sleep: noSleep, now: clock().now })
    expect(out.status).toBe('listed')
    expect(loadAccount(storage)).toMatchObject({ login: 'alice', repo: 'cupitor-data', branch: 'main' })
  })
  test('a listing failure leaves the repo recorded (the user can already write)', async () => {
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice' }) })
    const gh = fakeGh({
      'GET /repos/alice/cupitor-data': { name: 'cupitor-data' },
      'GET /repos/alice/cupitor-data/contents/cupitor.json': { sha: 's' },
      'GET /repos/trexsatya/cupitor-users/contents/users.json': err(500),
    })
    await expect(runSetup({ login: 'alice', gh, storage, sleep: noSleep, now: clock().now })).rejects.toMatchObject({ step: 'listing' })
    expect(loadAccount(storage).repo).toBe('cupitor-data')
  })
  test('the owner needs no setup', async () => {
    const storage = memStorage()
    const gh = fakeGh({})
    expect((await runSetup({ login: 'trexsatya', gh, storage })).status).toBe('listed')
    expect(gh.calls).toEqual([])
    expect(loadAccount(storage)).toMatchObject({ login: 'trexsatya', repo: 'trexsatya.github.io', branch: 'gh-pages' })
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js -t runSetup`
Expected: FAIL — not exported.

- [ ] **Step 3: Implement**

Append to `public/language/account.js`:

```js
// ---- the whole setup ----

// Resolves { status, state }. Throws SetupError(step, code) — Retry calls
// runSetup again with the same arguments and resumes.
export async function runSetup({ login, name, repoName, gh = defaultGh(), storage, sleep = defaultSleep, now = Date.now, report = () => {} }) {
  if (login === OWNER.login) {
    const state = { ...loadAccount(storage), login, repo: OWNER.repo, branch: OWNER.branch }
    saveAccount(state, storage)
    return { status: 'listed', state: loadAccount(storage) }
  }
  const prev = loadAccount(storage)
  const r = await ensureDataRepo({ login, repoName: repoName || (prev.login === login && prev.repo) || DATA_REPO, gh, sleep, now, report })
  const state = { ...prev, login, repo: r.repo, branch: r.branch }
  if (prev.login !== login) state.other = defaultOther(login)
  saveAccount(state, storage)
  const status = await ensureListing({ login, name, repo: r.repo, branch: r.branch, gh, sleep, now, report })
  return { status, state: loadAccount(storage) }
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: runSetup chains the repo and listing steps and records the repo early

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 17: `account.js` — browser token, sign-in, sign-out, 401, boot reconcile

**Files:**
- Modify: `public/language/account.js`
- Test: `public/language/account.test.js`

A token pasted in a browser lives in `sessionStorage` (this tab, survives the reload that applies the account) unless "remember on this device" moves it to `localStorage`.

- [ ] **Step 1: Write the failing tests**

Append to `public/language/account.test.js`:

```js
import {
  TOKEN_SESSION_KEY, TOKEN_REMEMBER_KEY, storedToken, rememberToken, forgetToken, applyStoredToken,
  signInWithToken, signOut, reconcileLogin, installUnauthorizedHandler,
} from './account.js'

function fakeGhUtils() {
  let token = null
  return { setGHToken: t => { token = t }, clearGHToken: () => { token = null }, get token() { return token } }
}
const storages = () => ({ session: memStorage(), local: memStorage() })

describe('browser token', () => {
  test('session by default, local when remembered, forget clears both', () => {
    const s = storages()
    rememberToken('ghp_1', false, s)
    expect(s.session.getItem(TOKEN_SESSION_KEY)).toBe('ghp_1'); expect(s.local.getItem(TOKEN_REMEMBER_KEY)).toBeNull()
    rememberToken('ghp_2', true, s)
    expect(s.local.getItem(TOKEN_REMEMBER_KEY)).toBe('ghp_2'); expect(s.session.getItem(TOKEN_SESSION_KEY)).toBeNull()
    expect(storedToken(s)).toBe('ghp_2')
    forgetToken(s)
    expect(storedToken(s)).toBeNull()
  })
  test('applyStoredToken hands the token to GitHubUtils', () => {
    const s = storages(); const u = fakeGhUtils()
    expect(applyStoredToken(u, s)).toBe(false)
    rememberToken('ghp_3', false, s)
    expect(applyStoredToken(u, s)).toBe(true); expect(u.token).toBe('ghp_3')
  })
})

describe('signInWithToken / signOut', () => {
  test('a good token signs in and is kept; a bad one is dropped', async () => {
    const s = storages(); const u = fakeGhUtils(); const storage = memStorage()
    const gh = fakeGh({ 'GET /user': { login: 'alice', name: 'Alice' } })
    const state = await signInWithToken('ghp_ok', { remember: true, gh, ghUtils: u, storages: s, storage })
    expect(state.login).toBe('alice'); expect(storedToken(s)).toBe('ghp_ok'); expect(u.token).toBe('ghp_ok')
    const bad = fakeGh({ 'GET /user': err(401) })
    await expect(signInWithToken('ghp_bad', { gh: bad, ghUtils: u, storages: s, storage })).rejects.toThrow(/did not accept/)
    expect(u.token).toBeNull()
  })
  test('signOut forgets the token and returns to guest, keeping pending-edit keys', () => {
    const s = storages(); const u = fakeGhUtils()
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice', repo: 'cupitor-data', branch: 'main' }), 'cupitor:pendingSrtEdits@alice': '{"x":1}' })
    rememberToken('t', true, s); u.setGHToken('t')
    signOut({ ghUtils: u, storages: s, storage })
    expect(loadAccount(storage)).toEqual({ login: null, repo: null, branch: null, other: ownerEntry() })
    expect(storedToken(s)).toBeNull(); expect(u.token).toBeNull()
    expect(storage.getItem('cupitor:pendingSrtEdits@alice')).toBe('{"x":1}')
  })
  test('installUnauthorizedHandler signs out once on the event', () => {
    const s = storages(); const u = fakeGhUtils(); const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice' }) })
    const after = jest.fn()
    installUnauthorizedHandler({ ghUtils: u, storages: s, storage, onSignedOut: after, target: window })
    window.dispatchEvent(new CustomEvent('cupitorGithubUnauthorized'))
    window.dispatchEvent(new CustomEvent('cupitorGithubUnauthorized'))
    expect(after).toHaveBeenCalledTimes(1)
    expect(loadAccount(storage).login).toBeNull()
  })
})

describe('reconcileLogin (boot)', () => {
  test('no token source and no record → ok; a record without a token source → signed out, reload', async () => {
    const s = storages(); const u = fakeGhUtils()
    expect(await reconcileLogin({ gh: fakeGh({}), ghUtils: u, storages: s, storage: memStorage(), bridgeAvailable: false })).toBe('ok')
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice' }) })
    expect(await reconcileLogin({ gh: fakeGh({}), ghUtils: u, storages: s, storage, bridgeAvailable: false })).toBe('reload')
    expect(loadAccount(storage).login).toBeNull()
  })
  test('in the app: GET /user decides; a changed login is adopted and reloads; the same login is ok', async () => {
    const s = storages(); const u = fakeGhUtils()
    const gh = fakeGh({ 'GET /user': { login: 'alice' }, 'GET /repos/alice/cupitor-data/contents/cupitor.json': { sha: 's' } })
    const storage = memStorage()
    expect(await reconcileLogin({ gh, ghUtils: u, storages: s, storage, bridgeAvailable: true })).toBe('reload')
    expect(loadAccount(storage)).toMatchObject({ login: 'alice', repo: 'cupitor-data' })
    expect(await reconcileLogin({ gh, ghUtils: u, storages: s, storage, bridgeAvailable: true })).toBe('ok')
  })
  test('in the app with no token and a stale record → signed out, reload', async () => {
    const s = storages(); const u = fakeGhUtils()
    const storage = memStorage({ [ACCOUNT_KEY]: JSON.stringify({ login: 'alice' }) })
    expect(await reconcileLogin({ gh: fakeGh({ 'GET /user': err(401) }), ghUtils: u, storages: s, storage, bridgeAvailable: true })).toBe('reload')
    expect(loadAccount(storage).login).toBeNull()
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account.test.js -t "browser token|signIn|reconcile"`
Expected: FAIL — not exported.

- [ ] **Step 3: Implement**

Append to `public/language/account.js`:

```js
// ---- the browser's token ----

export const TOKEN_SESSION_KEY = 'cupitor:ghToken:session'
export const TOKEN_REMEMBER_KEY = 'cupitor:ghToken'

function defaultStorages() {
  return {
    session: typeof sessionStorage !== 'undefined' ? sessionStorage : null,
    local: typeof localStorage !== 'undefined' ? localStorage : null,
  }
}
const get = (s, k) => { try { return s ? s.getItem(k) : null } catch (_) { return null } }
const set = (s, k, v) => { try { if (s) s.setItem(k, v) } catch (_) {} }
const del = (s, k) => { try { if (s) s.removeItem(k) } catch (_) {} }

export function storedToken(storages = defaultStorages()) {
  return get(storages.local, TOKEN_REMEMBER_KEY) || get(storages.session, TOKEN_SESSION_KEY) || null
}
export function rememberToken(token, remember, storages = defaultStorages()) {
  if (remember) { set(storages.local, TOKEN_REMEMBER_KEY, token); del(storages.session, TOKEN_SESSION_KEY) }
  else { set(storages.session, TOKEN_SESSION_KEY, token); del(storages.local, TOKEN_REMEMBER_KEY) }
}
export function forgetToken(storages = defaultStorages()) {
  del(storages.local, TOKEN_REMEMBER_KEY); del(storages.session, TOKEN_SESSION_KEY)
}
function defaultGhUtils() { return typeof window !== 'undefined' ? window.GitHubUtils : null }
export function applyStoredToken(ghUtils = defaultGhUtils(), storages = defaultStorages()) {
  const t = storedToken(storages)
  if (t && ghUtils) ghUtils.setGHToken(t)
  return !!t
}

// ---- sign in / out ----

export async function signInWithToken(token, { remember = false, gh = defaultGh(), ghUtils = defaultGhUtils(), storages = defaultStorages(), storage } = {}) {
  const t = String(token || '').trim()
  if (!t) throw new Error('No token given')
  ghUtils.setGHToken(t)
  const me = await fetchLogin(gh)
  if (!me) { ghUtils.clearGHToken(); throw new Error('GitHub did not accept this token') }
  rememberToken(t, remember, storages)
  return adoptLogin(me, { gh, storage })
}

// Back to guest. Pending-edit keys are per owner and stay where they are, so
// the same person signing in again finds their unsent edits.
export function signOut({ ghUtils = defaultGhUtils(), storages = defaultStorages(), storage } = {}) {
  if (ghUtils) ghUtils.clearGHToken()
  forgetToken(storages)
  saveAccount({ login: null, repo: null, branch: null, other: defaultOther(null) }, storage)
}

// A 401 anywhere means the token is gone: sign out once and tell the caller
// (which reloads so the page boots as a guest).
export function installUnauthorizedHandler({ ghUtils, storages, storage, onSignedOut = () => {}, target = (typeof window !== 'undefined' ? window : null) } = {}) {
  if (!target) return
  let done = false
  target.addEventListener('cupitorGithubUnauthorized', () => {
    if (done) return
    done = true
    signOut({ ghUtils, storages, storage })
    onSignedOut()
  })
}

// At boot: make the stored record agree with the token actually in use.
// Returns 'reload' when the record changed (the page must boot again with
// the new sources and keys), else 'ok'.
export async function reconcileLogin({ gh = defaultGh(), ghUtils = defaultGhUtils(), storages = defaultStorages(), storage, bridgeAvailable } = {}) {
  const state = loadAccount(storage)
  const canAsk = bridgeAvailable || applyStoredToken(ghUtils, storages)
  if (!canAsk) {
    if (!state.login) return 'ok'
    signOut({ ghUtils, storages, storage })
    return 'reload'
  }
  const me = await fetchLogin(gh)
  if (!me) {
    if (!state.login) return 'ok'
    signOut({ ghUtils, storages, storage })
    return 'reload'
  }
  if (me.login === state.login) return 'ok'
  await adoptLogin(me, { gh, storage })
  return 'reload'
}
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/account.js public/language/account.test.js
git commit -m "language: browser token storage, sign-in/out, 401 sign-out and boot reconcile

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 18: `account-bridge.js` — talking to the app

**Files:**
- Create: `public/language/account-bridge.js`
- Test: `public/language/account-bridge.test.js`

- [ ] **Step 1: Write the failing tests**

Create `public/language/account-bridge.test.js`:

```js
import { appBridgeAvailable, installAckListener, bridgeCall, requestAppSignIn, requestAppSignOut, ACK_EVENT } from './account-bridge.js'

function fakeWindow() {
  const listeners = {}
  const w = {
    AccountBridge: { postMessage: jest.fn() },
    addEventListener: (n, fn) => { (listeners[n] = listeners[n] || []).push(fn) },
    dispatchEvent: (ev) => { (listeners[ev.type] || []).forEach(fn => fn(ev)) },
  }
  w.ack = (detail) => w.dispatchEvent({ type: ACK_EVENT, detail })
  return w
}
const sent = (w, i = 0) => JSON.parse(w.AccountBridge.postMessage.mock.calls[i][0])

describe('account bridge', () => {
  test('available only when the channel exists', () => {
    expect(appBridgeAvailable({})).toBe(false)
    expect(appBridgeAvailable({ AccountBridge: {} })).toBe(false)
    expect(appBridgeAvailable(fakeWindow())).toBe(true)
  })
  test('no bridge → rejects with "not available"', async () => {
    await expect(bridgeCall('signIn', { w: {} })).rejects.toThrow(/not available/)
  })
  test('signIn posts {op, request_id} and resolves with the ack data', async () => {
    const w = fakeWindow(); installAckListener(w)
    const p = requestAppSignIn({ w })
    const msg = sent(w)
    expect(msg.op).toBe('signIn'); expect(msg.request_id).toMatch(/^acct-/)
    w.ack({ request_id: 'someone-else', op: 'signIn', ok: true })   // ignored
    w.ack({ request_id: msg.request_id, op: 'signIn', ok: true, data: { signed_in: true } })
    expect(await p).toEqual({ signed_in: true })
  })
  test('an ok:false ack rejects with the error code', async () => {
    const w = fakeWindow(); installAckListener(w)
    const p = requestAppSignOut({ w })
    w.ack({ request_id: sent(w).request_id, op: 'signOut', ok: false, error: 'internal' })
    await expect(p).rejects.toThrow('internal')
  })
  test('times out', async () => {
    jest.useFakeTimers()
    const w = fakeWindow(); installAckListener(w)
    const p = bridgeCall('getStatus', { w, timeoutMs: 1000 })
    jest.advanceTimersByTime(1001)
    await expect(p).rejects.toThrow(/timeout/)
    jest.useRealTimers()
  })
  test('a throwing postMessage rejects', async () => {
    const w = fakeWindow(); w.AccountBridge.postMessage = () => { throw new Error('gone') }
    await expect(bridgeCall('signIn', { w })).rejects.toThrow('gone')
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account-bridge.test.js`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Create the module**

Create `public/language/account-bridge.js`:

```js
// The webapp side of the AccountBridge contract (see the plan / the app's
// docs/webapp-integration-spec.md):
//   JS → Dart   AccountBridge.postMessage(JSON.stringify({ op, request_id }))
//               op: 'signIn' | 'signOut' | 'getStatus'
//   Dart → JS   CustomEvent 'cupitorAccountAck'
//               detail { request_id, op, ok, error?, data?: { signed_in } }
// The token never crosses; after signed_in the page asks GET /user through
// GitHubProxy. In a plain browser the channel is absent.

export const ACK_EVENT = 'cupitorAccountAck'

const _pending = new Map()
let _seq = 0

export function appBridgeAvailable(w = (typeof window !== 'undefined' ? window : null)) {
  return !!(w && w.AccountBridge && typeof w.AccountBridge.postMessage === 'function')
}

// Call once at boot. Acks for request_ids we do not know are ignored.
export function installAckListener(w = window) {
  w.addEventListener(ACK_EVENT, (e) => {
    const a = (e && e.detail) || {}
    const p = _pending.get(a.request_id)
    if (!p) return
    _pending.delete(a.request_id)
    clearTimeout(p.timer)
    if (a.ok) p.resolve(a.data || {})
    else p.reject(new Error(a.error || 'failed'))
  })
}

// Device sign-in can take as long as GitHub's code is valid (15 min).
export function bridgeCall(op, { w = (typeof window !== 'undefined' ? window : null), timeoutMs = 16 * 60 * 1000 } = {}) {
  if (!appBridgeAvailable(w)) return Promise.reject(new Error('not available'))
  return new Promise((resolve, reject) => {
    const request_id = 'acct-' + (++_seq) + '-' + Date.now().toString(36)
    const timer = setTimeout(() => { _pending.delete(request_id); reject(new Error(`timeout waiting for ${op}`)) }, timeoutMs)
    _pending.set(request_id, { resolve, reject, timer })
    try {
      w.AccountBridge.postMessage(JSON.stringify({ op, request_id }))
    } catch (e) {
      clearTimeout(timer); _pending.delete(request_id); reject(e)
    }
  })
}

export const requestAppSignIn = (opts) => bridgeCall('signIn', opts)
export const requestAppSignOut = (opts) => bridgeCall('signOut', opts)
export const requestAppStatus = (opts) => bridgeCall('getStatus', { timeoutMs: 5000, ...opts })
```

- [ ] **Step 4: Run the tests**

Run: `npx jest public/language/account-bridge.test.js`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add public/language/account-bridge.js public/language/account-bridge.test.js
git commit -m "language: AccountBridge request/ack plumbing for in-app sign-in

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 19: Account panel — view-model, dialog, banner, markup

**Files:**
- Create: `public/language/account-panel.js`
- Test: `public/language/account-panel.test.js`
- Modify: `public/language.html`
- Modify: `public/language.css`

- [ ] **Step 1: Write the failing VM tests**

Create `public/language/account-panel.test.js`:

```js
import { accountPanelVM } from './account-panel.js'

const owner = { login: 'trexsatya', name: 'Satya', repo: 'trexsatya.github.io', branch: 'gh-pages' }
const alice = { login: 'alice', name: 'Alice', repo: 'cupitor-data', branch: 'main' }
const users = [owner, alice, { login: 'bob', name: 'Bob', repo: 'cupitor-data', branch: 'main' }]

describe('accountPanelVM', () => {
  test('guest in a browser: banner, token form, no app sign-in', () => {
    const vm = accountPanelVM({ state: { login: null, repo: null, branch: null, other: owner }, users, inApp: false })
    expect(vm.status).toBe('guest')
    expect(vm.banner).toMatch(/Set up your repo to save changes/)
    expect(vm.showTokenForm).toBe(true); expect(vm.showAppSignIn).toBe(false); expect(vm.showSetup).toBe(false)
    expect(vm.otherOptions).toEqual([
      { value: '', label: 'none', selected: false },
      { value: 'trexsatya', label: 'Satya (trexsatya)', selected: true },
      { value: 'alice', label: 'Alice (alice)', selected: false },
      { value: 'bob', label: 'Bob (bob)', selected: false },
    ])
  })
  test('guest in the app: app sign-in, no token form, browser-only note hidden', () => {
    const vm = accountPanelVM({ state: { login: null, repo: null, branch: null, other: owner }, users, inApp: true })
    expect(vm.showAppSignIn).toBe(true); expect(vm.showTokenForm).toBe(false)
  })
  test('signed in without a repo: setup offered, writes blocked banner', () => {
    const vm = accountPanelVM({ state: { login: 'alice', repo: null, branch: null, other: owner }, users, inApp: false })
    expect(vm.status).toBe('no-repo'); expect(vm.showSetup).toBe(true)
    expect(vm.banner).toMatch(/Set up your repo/)
    expect(vm.otherOptions.map(o => o.value)).toEqual(['', 'trexsatya', 'bob'])   // self is not offered
  })
  test('ready: no banner; listing status is shown', () => {
    const vm = accountPanelVM({ state: alice, users, inApp: false, listing: 'awaiting' })
    expect(vm.status).toBe('ready'); expect(vm.banner).toBeNull()
    expect(vm.lines.join(' ')).toMatch(/awaiting approval/)
    expect(accountPanelVM({ state: alice, users, inApp: false, listing: 'not_approved' }).lines.join(' ')).toMatch(/not approved/)
    expect(accountPanelVM({ state: alice, users, inApp: false, listing: 'listed' }).lines.join(' ')).toMatch(/listed/)
  })
  test('setup progress and a failed step with retry', () => {
    const vm = accountPanelVM({ state: { login: 'alice', repo: null, branch: null, other: owner }, users, inApp: false,
      setup: { steps: { repo: 'done', listing: 'forking' }, error: null } })
    expect(vm.setupSteps).toEqual([{ key: 'repo', label: 'Create your data repo', status: 'done' }, { key: 'listing', label: 'Ask to be listed', status: 'forking' }])
    const failed = accountPanelVM({ state: { login: 'alice', repo: 'cupitor-data', branch: 'main', other: owner }, users, inApp: false,
      setup: { steps: { repo: 'done', listing: 'failed' }, error: { step: 'listing', code: 'failed', message: 'boom' } } })
    expect(failed.setupError).toEqual({ step: 'listing', code: 'failed', message: 'boom' })
    expect(failed.showRetry).toBe(true)
    const taken = accountPanelVM({ state: { login: 'alice', repo: null, branch: null, other: owner }, users, inApp: false,
      setup: { steps: { repo: 'failed' }, error: { step: 'repo', code: 'repo_taken', message: 'taken' } } })
    expect(taken.askRepoName).toBe(true)
  })
  test('other-layer notice is passed through', () => {
    const vm = accountPanelVM({ state: alice, users, inApp: false, otherNotice: 'No data found in trexsatya/trexsatya.github.io' })
    expect(vm.otherNotice).toMatch(/No data found/)
  })
})
```

- [ ] **Step 2: Run to see them fail**

Run: `npx jest public/language/account-panel.test.js`
Expected: FAIL — cannot find module.

- [ ] **Step 3: Create the module**

Create `public/language/account-panel.js`:

```js
// The account panel: a jQuery UI dialog opened from the settings footer, plus
// the guest banner. accountPanelVM is pure (tested); render() paints it.

import { OWNER, loadAccount, saveAccount, normalizeUser } from './account-state.js'
import { layerStats } from './data-source.js'
import {
  fetchUsers, cachedUsers, ownerEntry, runSetup, listingStatus, SetupError,
  signInWithToken, signOut, reconcileLogin, installUnauthorizedHandler, fetchLogin,
} from './account.js'
import { appBridgeAvailable, installAckListener, requestAppSignIn, requestAppSignOut } from './account-bridge.js'

const SETUP_LABELS = { repo: 'Create your data repo', listing: 'Ask to be listed' }
const TOKEN_URL = 'https://github.com/settings/tokens/new?scopes=public_repo&description=Cupitor'

export function accountPanelVM({ state, users, inApp, listing = null, setup = null, otherNotice = null }) {
  const login = state.login
  const status = !login ? 'guest' : (!state.repo ? 'no-repo' : (login === OWNER.login ? 'owner' : 'ready'))
  const lines = []
  if (status === 'guest') lines.push(`Viewing ${state.other ? state.other.name : 'nobody'}'s library as a guest.`)
  if (status === 'no-repo') lines.push(`Signed in as ${login}. Your data repo is not set up yet.`)
  if (status === 'ready') lines.push(`Signed in as ${login}. Writes go to ${login}/${state.repo} (${state.branch}).`)
  if (status === 'owner') lines.push(`Signed in as ${login} (owner). Writes go to ${OWNER.repo} (${OWNER.branch}).`)
  if (status === 'ready' && listing === 'awaiting') lines.push('Listing: awaiting approval — others cannot pick your library yet.')
  if (status === 'ready' && listing === 'not_approved') lines.push('Listing: not approved — you can keep using your repo.')
  if (status === 'ready' && listing === 'listed') lines.push('Listing: listed — others can load your library.')
  const banner = status === 'guest' || status === 'no-repo' ? 'Set up your repo to save changes.' : null
  const list = (users && users.length ? users : [ownerEntry()]).filter(u => u.login !== login)
  const chosen = state.other ? state.other.login : ''
  const otherOptions = [{ value: '', label: 'none', selected: chosen === '' }]
    .concat(list.map(u => ({ value: u.login, label: `${u.name} (${u.login})`, selected: u.login === chosen })))
  const steps = setup && setup.steps ? setup.steps : {}
  const setupSteps = Object.keys(SETUP_LABELS).filter(k => k in steps).map(k => ({ key: k, label: SETUP_LABELS[k], status: steps[k] }))
  const setupError = setup && setup.error ? setup.error : null
  return {
    status, lines, banner, otherOptions, setupSteps, setupError,
    showSetup: status === 'no-repo' || (status === 'ready' && listing === 'none'),
    showRetry: !!setupError,
    askRepoName: !!(setupError && setupError.code === 'repo_taken'),
    showTokenForm: !inApp && status === 'guest',
    showAppSignIn: inApp && status === 'guest',
    showSignOut: status !== 'guest',
    otherNotice,
    tokenUrl: TOKEN_URL,
  }
}

// ---- live state ----
const ui = { users: null, listing: null, setup: null, otherNotice: null, busy: false, message: null }

function inApp() { return appBridgeAvailable() }
function reload() { window.location.reload() }

function otherLayerNotice(state) {
  if (!state.other) return null
  const st = layerStats().other
  if (st.hits === 0 && (st.misses + st.errors) > 0) return `No data found in ${state.other.login}/${state.other.repo} — that layer is empty.`
  const notices = window._otherLayerNotices || []
  return notices.length ? notices[notices.length - 1] : null
}

function render() {
  const state = loadAccount()
  const vm = accountPanelVM({ state, users: ui.users || cachedUsers() || [ownerEntry()], inApp: inApp(), listing: ui.listing, setup: ui.setup, otherNotice: ui.otherNotice || otherLayerNotice(state) })
  const $b = $('#accountBanner')
  if (vm.banner) $b.html(`${_.escape(vm.banner)} <button type="button" class="lang-tool-btn" id="accountBannerBtn">Account</button>`).show()
  else $b.hide().empty()

  const $d = $('#accountDialog')
  if (!$d.length) return
  let html = `<div class="acct-lines">${vm.lines.map(l => `<p>${_.escape(l)}</p>`).join('')}</div>`
  if (ui.message) html += `<p class="acct-msg">${_.escape(ui.message)}</p>`
  if (vm.otherNotice) html += `<p class="acct-notice">${_.escape(vm.otherNotice)}</p>`
  if (vm.showAppSignIn) html += `<p><button type="button" class="lang-tool-btn" id="acctAppSignIn"${ui.busy ? ' disabled' : ''}>Sign in with GitHub</button></p>`
  if (vm.showTokenForm) {
    html += `<div class="acct-token">
      <p>In a browser, paste a classic token with the <code>public_repo</code> scope. <a href="${vm.tokenUrl}" target="_blank" rel="noopener">Create one on GitHub</a>.</p>
      <input type="password" id="acctToken" placeholder="ghp_…" autocomplete="off" style="width:100%;">
      <label><input type="checkbox" id="acctRemember"> Remember on this device</label>
      <p><button type="button" class="lang-tool-btn" id="acctTokenSignIn"${ui.busy ? ' disabled' : ''}>Sign in</button></p>
    </div>`
  }
  if (vm.showSetup || vm.setupSteps.length) {
    html += `<div class="acct-setup"><p><b>Set up your repo</b></p>`
    html += vm.setupSteps.map(s => `<div class="acct-step acct-step-${_.escape(s.status)}">${_.escape(s.label)}: ${_.escape(s.status)}</div>`).join('')
    if (vm.setupError) html += `<p class="acct-err">${_.escape(vm.setupError.message)}</p>`
    if (vm.askRepoName) html += `<p><input type="text" id="acctRepoName" placeholder="another repo name" value="cupitor-data-2"></p>`
    if (vm.showSetup && !vm.setupSteps.length) html += `<p><button type="button" class="lang-tool-btn" id="acctSetup"${ui.busy ? ' disabled' : ''}>Set up</button></p>`
    if (vm.showRetry) html += `<p><button type="button" class="lang-tool-btn" id="acctSetup"${ui.busy ? ' disabled' : ''}>Retry</button></p>`
    html += `</div>`
  }
  html += `<div class="acct-other"><label>Also load data from
    <select id="acctOther">${vm.otherOptions.map(o => `<option value="${_.escape(o.value)}"${o.selected ? ' selected' : ''}>${_.escape(o.label)}</option>`).join('')}</select></label></div>`
  if (vm.showSignOut) html += `<p><button type="button" class="lang-tool-btn" id="acctSignOut"${ui.busy ? ' disabled' : ''}>Sign out</button></p>`
  $d.html(html)
}

function setBusy(b, message = null) { ui.busy = b; ui.message = message; render() }

async function doSetup() {
  const state = loadAccount()
  if (!state.login) return
  const repoName = $('#acctRepoName').val() || undefined
  ui.setup = { steps: {}, error: null }
  setBusy(true, 'Setting up…')
  try {
    const me = await fetchLogin()
    const { status } = await runSetup({
      login: state.login, name: me ? me.name : state.login, repoName,
      report: (step, st) => { ui.setup.steps[step] = st; render() },
    })
    ui.listing = status
    setBusy(false, 'Done.')
    reload()   // sources and keys are read at boot
  } catch (e) {
    const err = e instanceof SetupError ? { step: e.step, code: e.code, message: e.message } : { step: 'repo', code: 'failed', message: e && e.message }
    ui.setup.steps[err.step] = 'failed'
    ui.setup.error = err
    setBusy(false, null)
  }
}

async function doAppSignIn() {
  setBusy(true, 'Finish signing in inside the app…')
  try {
    await requestAppSignIn()
    const r = await reconcileLogin({ bridgeAvailable: true })
    if (r === 'reload') reload(); else setBusy(false, 'Signed in.')
  } catch (e) {
    const code = e && e.message
    const text = code === 'not available' ? 'Not available in a browser.'
      : code === 'cancelled' ? 'Sign-in cancelled.'
      : code === 'denied' ? 'GitHub sign-in was declined.'
      : code === 'expired' ? 'The code expired. Try again.'
      : `Sign-in failed: ${code}`
    setBusy(false, text)
  }
}

async function doTokenSignIn() {
  const token = String($('#acctToken').val() || '').trim()
  const remember = $('#acctRemember').is(':checked')
  if (!token) { setBusy(false, 'Paste a token first.'); return }
  setBusy(true, 'Checking the token…')
  try {
    await signInWithToken(token, { remember })
    reload()
  } catch (e) { setBusy(false, e && e.message) }
}

async function doSignOut() {
  setBusy(true, 'Signing out…')
  try { if (inApp()) await requestAppSignOut() } catch (e) { console.warn('app signOut failed', e) }
  signOut()
  reload()
}

function onOtherChange() {
  const login = String($('#acctOther').val() || '')
  const state = loadAccount()
  const users = ui.users || cachedUsers() || [ownerEntry()]
  const pick = login ? normalizeUser(users.find(u => u.login === login)) : null
  saveAccount({ ...state, other: pick })
  reload()
}

export function openAccountDialog(message = null) {
  ui.message = message
  let $d = $('#accountDialog')
  if (!$d.length) $d = $('<div id="accountDialog" title="Account"></div>').appendTo('body')
  render()
  $d.dialog({ title: 'Account', width: Math.min(520, $(window).width() - 24), modal: true, draggable: false, resizable: false,
    position: { my: 'center top', at: 'center top+30', of: window } })
  // Fresh users list and listing status in the background.
  fetchUsers().then(u => { ui.users = u; render() })
  const state = loadAccount()
  if (state.login && state.repo && state.login !== OWNER.login) {
    listingStatus({ login: state.login }).then(s => { ui.listing = s; render() }).catch(() => {})
  }
}

// Used by language.js when a write needs a self repo.
export function showSetupPrompt(message) { openAccountDialog(message) }

export function initAccountPanel() {
  if (typeof window === 'undefined') return
  installAckListener(window)
  window.cupitorShowSetupPrompt = showSetupPrompt
  $(document)
    .on('click', '#accountBtn, #accountBannerBtn', () => openAccountDialog())
    .on('click', '#acctSetup', doSetup)
    .on('click', '#acctAppSignIn', doAppSignIn)
    .on('click', '#acctTokenSignIn', doTokenSignIn)
    .on('click', '#acctSignOut', doSignOut)
    .on('change', '#acctOther', onOtherChange)
  render()
  // Boot: agree with the token in use, then watch for a 401.
  reconcileLogin({ bridgeAvailable: inApp() })
    .then(r => { if (r === 'reload') reload() })
    .catch(e => console.warn('[account] reconcile failed', e))
    .finally(() => installUnauthorizedHandler({ onSignedOut: () => { alert('GitHub no longer accepts the token — signed out. Your unsaved edits are kept on this device.'); reload() } }))
  // Re-render once the subtitle layers have reported, so the other-layer notice is accurate.
  const ready = window._subtitlesReadyPromise
  if (ready && typeof ready.then === 'function') ready.then(render)
}
```

- [ ] **Step 4: Run the VM tests**

Run: `npx jest public/language/account-panel.test.js`
Expected: PASS (6 tests). (`$` and `_` are only touched inside functions that the tests do not call.)

- [ ] **Step 5: Markup and CSS**

In `public/language.html`:

(a) Directly before the line `<div id="settingsPanel" class="lang-panel" style="display: none;">` add:

```html
                <div id="accountBanner" class="account-banner" style="display:none;"></div>
```

(b) In `<div id="settingsFooter" class="settings-footer">`, after the `viewLogsBtn` button add:

```html
                    <button type="button" id="accountBtn" class="lang-tool-btn" title="GitHub account, your data repo, and whose library to load">Account</button>
```

(c) After the closing `</div>` of `srtEditsReviewDialog` add:

```html
                <div id="accountDialog" title="Account" style="display: none;"></div>
```

In `public/language.css`, append:

```css
.account-banner { background: #fff6d6; border: 1px solid #e8d27a; border-radius: 6px; padding: 6px 10px; margin: 6px 0; font-size: 13px; display: flex; gap: 10px; align-items: center; }
#accountDialog p { margin: 6px 0; }
#accountDialog .acct-err { color: #a00; }
#accountDialog .acct-notice { color: #865; }
#accountDialog .acct-step-done { color: #2a7; }
#accountDialog .acct-step-failed { color: #a00; }
```

- [ ] **Step 6: Commit**

```bash
git add public/language/account-panel.js public/language/account-panel.test.js public/language.html public/language.css
git commit -m "language: account panel with sign-in, setup progress, other-user picker and guest banner

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 20: Boot wiring in `language.js`

**Files:**
- Modify: `public/language/language.js`

- [ ] **Step 1: Import and init**

Add to the import block:

```js
import { initAccountPanel as _initAccountPanel } from './account-panel.js';
```

Find the `$(function () {` block that calls `_loadRecording()` (near the end of the file) and add as its first statement:

```js
  _initAccountPanel()
```

- [ ] **Step 2: Confirm the ready promise the panel waits on**

Run: `grep -n "window._subtitlesReadyPromise = " public/language/language.js` — one hit. The panel (Task 19) re-renders on it; nothing to change.

- [ ] **Step 3: Smoke the whole flow in a browser**

`yarn serve`, open `http://localhost:8080/language.html?lang=swedish`:

1. Guest: banner "Set up your repo to save changes. [Account]"; the Account dialog shows the guest line, the token form, and the picker with Satya selected.
2. Paste a classic `public_repo` token of a **second** GitHub account (not the owner), Sign in → page reloads → banner still shown (no repo yet), dialog shows "Signed in as <login>… not set up yet" and a Set up button.
3. Set up → steps progress → reload → dialog says writes go to `<login>/cupitor-data`, listing "awaiting approval". On GitHub: a repo `<login>/cupitor-data` from the template, a fork of `cupitor-users`, branch `add-<login>`, and an open PR on `trexsatya/cupitor-users`.
4. Subtitles still load (owner's layer, read-only: no ✎ on lines; the owner's playlists show 🔒). Add a manual card to a new own playlist, Sync → a commit lands in `<login>/cupitor-data` only.
5. Pick "none" in the picker → reload → only own (empty) data; pick Satya again.
6. Sign out → guest again; sign in again with the same token → own playlists and pending edits are back.

- [ ] **Step 4: Full test run**

Run: `npx jest public/language && npx jest public/github-utils.test.js`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add public/language/language.js
git commit -m "language: boot the account panel and reconcile the login

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 21: Config and docs tidy-up

**Files:**
- Modify: `public/config.js`
- Modify: `public/language/language.js` (comments only)

- [ ] **Step 1: `config.js`**

`API_URL` in `public/config.js` still names the owner's repo. Check whether the language app uses it: `grep -rn "API_URL" public/language public/language.html`. If there are no hits, leave `config.js` alone (it belongs to the Vue app). If there are hits, replace each with `_dsReadUrl('primary', '', getLangFromUrl().fullName)` as in Task 5.

- [ ] **Step 2: Comments that describe the old world**

Run `grep -n "gh-pages\|trexsatya" public/language/language.js`. Reword comments so they describe the current state (e.g. "the SRT on gh-pages" → "the SRT in the user's repo"). Do not touch commit messages or user-facing strings beyond what Task 5 changed.

- [ ] **Step 3: Commit**

```bash
git add public/language/language.js public/config.js
git commit -m "language: comments describe per-user repos

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

(Omit `public/config.js` from the `git add` if it was not changed.)

---

## Done when

- `npx jest public/language` and `npx jest public/github-utils.test.js` pass.
- `grep -n "'trexsatya'\|'trexsatya.github.io'\|'gh-pages'" public/language/language.js` prints nothing.
- The browser walk-through in Task 20 step 3 succeeds with a second GitHub account.
- In-app sign-in needs the app plan (`2026-10-13-multi-user-app-signin.md`); until it ships, the panel inside the app shows "Finish signing in inside the app…" and then "Sign-in failed: timeout waiting for signIn" after 16 minutes — expected.
- Final manual step for the owner: deploy with the `cupitor-deploy` skill.
