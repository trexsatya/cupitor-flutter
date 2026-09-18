# Save page HTML — design

A Tools-drawer entry that saves the main WebView's page, as rendered, to a
file the user picks. A toggle decides whether Cupitor's own additions to the
page are stripped first.

The file is meant to be opened locally or pasted into
`tools/real_page_harness.html`, which cannot fetch most prose sites itself
because they send no CORS headers. Saving from the app is how a real page
reaches the harness.

## Scope

In scope: the main WebView's current document. The Tools drawer is the main
WebView's; dialog1 has its own toolbar and is not covered.

Out of scope: fetching external scripts or stylesheets into the file; the
original network source (for a single-page app that is an empty shell — the
rendered DOM is what is worth keeping); PDF pages shown in the text view.

## Tools drawer

Two rows, after the existing ones:

| Row | Behaviour |
|---|---|
| `Save page HTML…` | Exports the page and opens the system save dialog with the name `<host>-<yyyyMMdd-HHmm>.html`. A snackbar reports the saved path, `Save cancelled`, or `Save failed: <error>`. |
| `Strip Cupitor's markup` (switch) | Persisted in SharedPreferences under `savePageStripCupitor`, default **off**. On: the saved file is the page as the site rendered it. Off: the page exactly as it stands, Cupitor's additions included. |

## Export

`assets/js/page_export.js` is loaded from the asset bundle and injected when
the row is tapped — not on every page load — and defines
`window.__cupitorExportHtml(strip)`. It returns the document's doctype plus
`outerHTML` of a deep clone of `document.documentElement`. The live page is
never modified.

Whether or not stripping is on, `<head>` (created if missing) gets, as its
first children:

- `<meta charset="utf-8">`, replacing any charset the page declared — the file
  is written as UTF-8 bytes, so a page that says `iso-8859-1` would otherwise
  open as mojibake;
- `<base href="<page url>">`, unless the page already has a `<base>` with an
  `href`, so relative links and images resolve when the file is opened
  elsewhere.

### What stripping removes

Working on the clone, in this order:

1. Elements Cupitor injected, identified by convention: any element carrying
   `data-cupitor-injected`, whose `id` starts with `__cup`, or whose `class`
   attribute contains a class starting with `__cup`; and every `.cupitor-mask`.
   This covers the tagging stylesheet (`#__cupitor_st_styles`), the
   Wiktionary banner, the YouTube channel and player bars, and mask text.
2. The roots the remote snippet builds, which follow a `cup-` naming of their
   own: `#cup-sub-css`, `.cup-sub-sidebar`, `.cup-sub-modal`,
   `.cup-pc.cup-nolookup`. Its picker-panel stylesheet has no id, so it is
   found by its rules: an id-less `<style>` holding a `.cup-pc` selector.
   Named exactly rather than by the `cup-` prefix, which a site may use for
   its own markup.
3. `.cupitor-xform` spans — a word rewritten by a text transform — replaced
   by their original text (`data-cupitor-orig`).
4. `.clickable-word` spans — the word wrapping `utils.js` applies — replaced
   by their text, taking `data-cupitor-orig` over the visible text when a
   transform rewrote the word.
5. `mark._fh` — a find-in-page hit — replaced by the word it highlighted.
6. On every remaining element, `<html>` included: each class starting with
   `cupitor-` or `cup-sub-` (`cupitor-filter-active` on `<body>`,
   `cupitor-fade`, `cupitor-tagged`, `cupitor-masked-out`,
   `cupitor-temp-highlight`, `cup-sub-split`), the class
   `cup-shrink-target`, each attribute starting with `data-cupitor-`, and
   `data-cup-ann`. An emptied `class` attribute is removed.
7. The inline properties Cupitor sets on elements the site owns: `zoom` on
   `<html>` (the page-zoom level) and `--cup-vid-h` on `<body>` (the snippet's
   video/subtitle split). The declaration is cut out of the attribute text,
   honouring semicolons inside quotes and `url()`, so the rest is left byte
   for byte as the site wrote it — going through `element.style` would
   reserialize the block and drop whatever the engine did not parse. An
   emptied attribute is removed.
8. `normalize()`, so the unwrapped words merge back into their text nodes.

The two `<style>` elements Dart injects without an id — the YouTube ad-overlay
CSS and the ad-block rules — carry `data-cupitor-injected` so the convention
covers them.

## Limits

What the file cannot carry, whether stripped or not:

- Live form state. The export clones the markup, so a typed `<input>`, an
  edited `<textarea>` and a changed `<select>` come back at their defaults.
- Anything outside `<html>`, canvas bitmaps, shadow roots and iframe content.
- A `<meta http-equiv="refresh">` the site set still fires when the file is
  opened.

What stripping does not restore: the snippet and the Filmot annotator also
change the site's own elements in ways that leave no marker — a blacklisted
Filmot card carries Bootstrap's `d-none`, an unresolved one an inline
`opacity`. Those states stay in the saved file. A site that sets its own
`zoom` on `<html>` loses it, there being no way to tell whose it is.

The snippet also adds a one-rule `<style>` forcing `user-select: text`, with
neither an id nor a marker and with rules too generic to recognise safely, so
that one survives stripping. Marking it `data-cupitor-injected` at the source
would bring it under the convention.

The `<base>` is a trade-off: images, stylesheets and relative links resolve
against the original site, but a link to a fragment (`#chapter2`) now points
at the live page rather than at the file itself.

## Dart side

`_savePageHtml()` in `main.dart`: inject the asset, call
`__cupitorExportHtml(<toggle>)` through `runJavaScriptReturningResult`, decode
the result as a JSON string (Android returns one; anything that is not valid
JSON is taken verbatim — never quote-stripped, since the payload is HTML),
encode as UTF-8, and hand the bytes to `saveBytesToPickedFile`. An empty
result, and the `null` a failed script evaluates to, report `Nothing to save`.

`lib/save_file.dart` holds the saving itself, shared with the two bundle
exports. The pickers disagree about who writes the file: Android and iOS take
the bytes and write it, the desktop ones only name a path and macOS throws if
bytes are passed, so the helper branches and writes the file itself on
desktop. On macOS that write needs the `files.user-selected.read-write`
entitlement, which both `macos/Runner/*.entitlements` carry.

## Testing

`tools/page_export_test.js` — Node + jsdom, sharing the loader of
`tools/sentence_text_test.js`:

- strip: wrapped words are unwrapped and merged, a transformed word comes
  back as its original, find highlights are unwrapped, masks, `__cup*`,
  `data-cupitor-injected` and snippet panels are gone, Cupitor's classes and
  attributes are gone from the site's elements and from `<html>`, page zoom
  and the split height are gone while the rest of the style attribute
  survives verbatim, and the page's own content, classes, ids, `<script>`
  elements and `cup-`ish lookalikes survive;
- the head declares UTF-8 whatever the page said, and carries a `<base>`;
- no strip: every injection survives; the head is still fixed;
- a page that already has a `<base href>` keeps its own, one with only
  `<base target>` still gets an href;
- doctypes, including an XHTML one, keep their identifiers;
- a document without `<head>` gets one;
- the live document is untouched.

`test/save_file_test.dart` covers the two picker contracts, a cancelled
dialog, a UTF-8 round trip and an unwritable path.

Manual: save a litteraturbanken page with the toggle on, paste the file into
`tools/real_page_harness.html`, and confirm word taps and sentence capture
work on it.
