# Ad blocking components

Cupitor uses Brave Software's adblock-rust 0.13.6 (MPL-2.0).
The native integration is maintained by Cupitor; it is not affiliated with Brave.

The compressed offline bundle contains maintained filter lists and resources:

- Brave adblock-rust resources and adblock-resources: MPL-2.0.
- uBlock Origin/uAssets: GPL-3.0, except files with their own notices.
- EasyList and EasyPrivacy: retain their embedded source/license notices;
  see https://easylist.to/pages/licence.html.
- Brave adblock-lists: retain the licenses and notices of each source list.

The complete source URLs, pinned input commits and SHA-256 digests are recorded
in manifest.json. Filter text and resource metadata are retained in the bundle.
Run scripts/update-brave-bundle.py with upstream checkouts to reproduce it.
