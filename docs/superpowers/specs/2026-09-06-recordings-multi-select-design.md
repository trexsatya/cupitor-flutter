# Multi-select delete for voice recordings

## Why

`VoiceRecordingsScreen` (`lib/memory_manager.dart`) offers exactly two deletion
sizes: one clip, or every clip. Clearing out a handful of recordings means
tapping delete and confirming once per clip, and the only alternative is
nuking the lot. Multi-select fills the gap.

The screen has a constraint worth restating, because it drives the design: it
cannot tell which manual card owns a clip — that mapping lives in dialog1's JS
storage, out of reach. Rows are named by opaque file id. **Playing a clip is
the only way to know what it is**, so selecting clips to delete without being
able to hear them would be guesswork.

## Decisions

| Question | Decision |
|---|---|
| Entering selection | Long-press a row |
| Playback while selecting | Stays available — checkbox leads, play moves to trailing |
| Existing "Delete all" | Removed; select-all replaces it |
| Deselecting the last item | Exits selection mode |

## Design

### State

One field replaces the current per-row delete flow:

```dart
Set<String> _selectedPaths = {};
bool get _selecting => _selectedPaths.isNotEmpty;
```

Keyed by file path, not `File` identity, because `_reload()` rebuilds every
row object. Selection mode is *derived* from the set rather than tracked
separately — deselecting the last item exits, so there is no second piece of
state that can disagree with the first.

`_reload()` clears the set. Anything selected but deleted (or gone from disk)
should not linger as a phantom.

### App bar

One `AppBar` with two shapes.

- **Normal:** title "Voice recordings", actions: Reload. The
  `delete_sweep_outlined` button and `_deleteAll()` are removed.
- **Selecting:** leading ✕, title "N selected", actions: select-all / select-none
  toggle, then delete.

The toggle reads the current state: when every row is selected it clears the
set, otherwise it selects all rows. Clearing the set empties it, which by the
rule above ends selection mode — so "select none" and "close" land in the same
place, which is the honest consequence of deriving the mode from the set.

System back exits selection mode instead of leaving the screen, via `PopScope`
with `canPop: !_selecting`.

### Row

Long-press enters selection mode and selects that row. Thereafter a tap on the
row body toggles it.

| Slot | Normal | Selecting |
|---|---|---|
| leading | play / stop | `Checkbox` |
| title | file name | unchanged |
| subtitle | size · timestamp (+ progress while playing) | unchanged |
| trailing | delete | play / stop |

Out of selection mode the row is exactly what it is today. The per-row delete
is dropped only while selecting, where it is redundant.

Playback is untouched by selection: the progress bar and position/duration
readout render the same in both states, so a user can play a clip to identify
it without losing the selection they have built up.

### Deleting

`_deleteSelected()` replaces `_deleteAll()`:

1. Confirm — count and total bytes, keeping the existing warning that manual
   cards referencing a clip will lose their audio.
2. If the clip currently playing is in the set, stop the player first
   (`_deleteOne` already does this; the bulk path needs it too).
3. Delete each file, tallying removed vs failed. A failure on one file must not
   abandon the rest.
4. Snackbar with the tally, reusing the existing wording.
5. Clear the selection, then `_reload()`.

The parent screen already reloads on return (`memory_manager.dart`, the
`VoiceRecordingsScreen` push site), so the storage total stays accurate with no
change.

### Testing

The selection set and the delete tally are the parts worth pinning, and both
are currently welded to a `State` class. Lift them into pure helpers —
following the split already used for `speech_session.dart` — and unit test:

- toggling into and out of the set; the last removal ending selection mode
- select-all / select-none against the current row list
- selection dropping ids that no longer exist after a reload
- the delete tally: all succeed, all fail, and a partial failure
- the confirmation summary text for one clip, several, and every clip

The widget layer stays thin wiring around those.

## Out of scope

- Range select (tap-drag or shift-select). Worth it only for very long lists.
- Sort or filter controls (by age, by size). Rows stay newest-first.
- Showing which manual card owns a clip — the mapping is not reachable from
  this process.
