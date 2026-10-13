# Multi-user Cupitor — design

## Goal

Anyone can use Cupitor on their own device with their own data, stored in
their own public GitHub repo. A user can also load one other user's library
read-only alongside their own. The owner (`trexsatya`) keeps the list of
users by merging pull requests.

The language webapp works on its own in a browser, so every account feature
lives in the webapp. The Flutter app only adds a native GitHub sign-in.

## Repos

| Repo | Purpose |
|---|---|
| `trexsatya/trexsatya.github.io` (branch `gh-pages`) | The owner's data repo and the webapp's hosting. |
| `trexsatya/cupitor-data-template` (branch `main`) | Template for new users' data repos: an empty `db/language/swedish/` and `db/language/spanish/` skeleton plus a `cupitor.json` marker file. |
| `trexsatya/cupitor-users` (branch `main`) | `users.json`, the list of users. Changed only by merged pull requests. |
| `<login>/cupitor-data` (branch `main`, public) | One per user, created from the template. |

Every data repo uses the same layout, `db/language/<lang>/…`, so code varies
only owner, repo and branch.

`users.json`:

```json
[
  { "login": "trexsatya", "name": "Satya", "repo": "trexsatya.github.io", "branch": "gh-pages" },
  { "login": "alice", "name": "Alice", "repo": "cupitor-data", "branch": "main" }
]
```

## Data: own vs. layered

Each user has a **self** source (their own repo, editable) and optionally one
**other** source (another listed user's repo, read-only).

| File under `db/language/<lang>/` | Read from other? |
|---|---|
| `srts/` (subtitle library and its index) | Yes |
| `recordings.json` (clip collections) | Yes |
| `vocabulary.txt`, `idioms`, `jokes`, `metaphors`, `poems`, `sayings` | Yes |
| `settings.json`, `word_history.json`, `srt_revision.json`, `words-missing.txt` | No — self only |

Layered data is merged by key (subtitle index entry, collection name,
vocabulary line). On a clash, self wins. Items from other are marked
read-only: edit and delete controls are hidden for them.

Writes always go to self.

## User states

| State | Self | Other | Writes |
|---|---|---|---|
| Guest (no token) | none | `trexsatya` | Blocked: "Set up your repo to save changes". |
| Signed in, no repo yet | none | chosen (default `trexsatya`) | Blocked; setup is offered. |
| Signed in, repo ready (listed or awaiting approval) | own repo | chosen or none (default `trexsatya`) | To own repo. |
| Signed in as `trexsatya` | `trexsatya.github.io` | chosen or none (default none) | To `trexsatya.github.io`. |

A user awaiting approval uses their repo fully; they are only missing from
the list other users see.

## Webapp components

### `data-source.js`

- `readUrl(who, path)` — raw URL for `self` or `other`.
- `writeTarget()` — `{owner, repo, branch}` of self; throws when there is no self.
- Layered reads for the "Yes" rows above, returning merged data with each
  item tagged by source.
- Replaces every hardcoded `'trexsatya'`, `'trexsatya.github.io'`,
  `'gh-pages'` and raw URL in `public/language/language.js` (the read base
  URL and the GitHub write call sites).

### `account.js`

- Account state in localStorage `cupitor:account`:
  `{ login, repo, branch, other }`.
- Login from `GET /user`.
- Setup steps, each checking before acting so a retry resumes:
  1. If `<login>/cupitor-data` does not exist, create it from
     `cupitor-data-template` (public). If it exists without `cupitor.json`,
     ask for a different repo name.
  2. If `login` is not in `users.json` and has no open PR on
     `cupitor-users`: fork `cupitor-users` (poll up to ~30 s until ready),
     sync the fork with upstream, commit the new entry on branch
     `add-<login>`, open a PR to `trexsatya/cupitor-users`.
  3. Report status: listed, awaiting approval, or not approved (PR closed
     without merge).
- Users list: fetch `users.json` from `cupitor-users`, cache in
  localStorage; with neither network nor cache, the list holds only
  `trexsatya`.

### Account panel

Sign-in status, setup button with per-step progress and Retry, the "Also
load data from" picker (none or one listed user), and the guest banner.

### Getting a token

- **In the app:** the panel asks the app to sign in or out over a bridge
  message. GitHub requests already go through the app's `GitHubProxy`
  channel, which attaches the token, so the webapp never holds it.
- **In a browser:** the panel asks for a classic token with `public_repo`
  scope, linking to GitHub's token page with that scope pre-filled. Kept in
  memory by default, with an opt-in "remember on this device"
  (localStorage).

Fine-grained tokens cannot open pull requests on repos the user does not
own, so the browser path asks for a classic token.

### Local storage keys

The IndexedDB cache of repo content and the pending-edit keys include the
source owner in their names, so two users' data on one device never mixes.

## Flutter app changes

- **GitHub device sign-in:** request a device code for the Cupitor OAuth app
  (client ID embedded; device flow enabled), show the code, open
  `github.com/login/device`, poll for the token honoring `slow_down`, handle
  denied and expired codes. Scope `public_repo`. The token is stored where
  the app stores its GitHub token today.
- **Bridge replies:** handle the webapp's sign-in and sign-out requests and
  answer with the result.
- The existing "paste token" dialog stays as a fallback.

The "Cupitor" GitHub OAuth app has device flow enabled, no client secret and
non-expiring user tokens. Client ID: `Ov23linnANScOoh6elAJ`.

## Errors

| Situation | Behaviour |
|---|---|
| Guest or no-repo user edits | Blocked with a prompt to set up; nothing is written. |
| Token revoked or expired (401) | Signed out; unsaved edits kept locally and sent after signing in again. |
| Setup fails partway | Panel shows the failed step; Retry resumes from it. |
| Other user's repo missing, renamed or private (404) | That layer is skipped with a notice; self keeps working. |
| `users.json` unreachable | Cached list; with no cache, only `trexsatya`. |
| PR closed without merge | Status "not approved"; the user keeps using their repo. |

## Testing

- **Webapp (jest, mocked fetch):** `data-source` URLs per source, write
  refusal without self, merge and read-only tagging; `account` setup steps
  from scratch, resumed after each failure point, and with each step already
  done; users-list caching and fallback.
- **Flutter (unit tests, fake HTTP client):** device sign-in for approved,
  denied, expired and `slow_down`; bridge sign-in and sign-out replies.
- **End to end, manual:** a second GitHub account, once in the app and once
  in a browser: guest → sign in → setup → PR on `cupitor-users` → merge →
  load each other's data → edit, confirming the write lands only in the
  editor's repo.

## Out of scope

Private data repos, more than one other user, moving existing data between
repos.
