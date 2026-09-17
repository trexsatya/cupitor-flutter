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

Whether or not stripping is on, a `<base href="<page url>">` is inserted as
the first child of `<head>` (created if missing) unless the page already has
one, so relative links and images resolve when the file is opened elsewhere.

### What stripping removes

Working on the clone, in this order:

1. Elements Cupitor injected, identified by convention: any element carrying
   `data-cupitor-injected`, whose `id` starts with `__cup`, or whose `class`
   attribute contains a class starting with `__cup`; and every `.cupitor-mask`.
   This covers the tagging stylesheet (`#__cupitor_st_styles`), the
   Wiktionary banner, the YouTube channel and player bars, and mask text.
2. `.cupitor-xform` spans — a word rewritten by a text transform — replaced
   by their original text (`data-cupitor-orig`).
3. `.clickable-word` spans — the word wrapping `utils.js` applies — replaced
   by their text, taking `data-cupitor-orig` over the visible text when a
   transform rewrote the word.
4. On every remaining element: each class starting with `cupitor-` (including
   `cupitor-filter-active` on `<body>`, `cupitor-fade`, `cupitor-tagged`,
   `cupitor-masked-out`, `cupitor-temp-highlight`) and each attribute starting
   with `data-cupitor-`. An emptied `class` attribute is removed.
5. `normalize()`, so the unwrapped words merge back into their text nodes.

The two `<style>` elements Dart injects without an id — the YouTube ad-overlay
CSS and the ad-block rules — carry `data-cupitor-injected` so the convention
covers them.

## Dart side

`_savePageHtml()` in `main.dart`: inject the asset, call
`__cupitorExportHtml(<toggle>)` through `runJavaScriptReturningResult`, decode
the result as a JSON string (Android returns one; anything that is not valid
JSON is taken verbatim — never quote-stripped, since the payload is HTML),
encode as UTF-8, and hand the bytes to `FilePicker.platform.saveFile`, the
same call the EPUB export uses. An empty result reports `Nothing to save`.

## Testing

`tools/page_export_test.js` — Node + jsdom, sharing the loader of
`tools/sentence_text_test.js`:

- strip: wrapped words are unwrapped and merged, a transformed word comes
  back as its original, masks and `__cup*` / `data-cupitor-injected` elements
  are gone, `cupitor-*` classes and `data-cupitor-*` attributes are gone, the
  page's own content, classes, ids and `<script>` elements survive, `<base>`
  is present and first in `<head>`, and the live document is untouched;
- no strip: every injection survives; `<base>` is still added;
- a page that already has a `<base>` keeps its own;
- a document without `<head>` gets one.

Manual: save a litteraturbanken page with the toggle on, paste the file into
`tools/real_page_harness.html`, and confirm word taps and sentence capture
work on it.
