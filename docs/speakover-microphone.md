# Speak-over microphone startup

Speak-over records raw audio through AudioBridge/MediaRecorder. Starting reserves
one pending native request before microphone teardown, permission and filesystem
awaits. Duplicate starts return mic-busy. Stop, Cancel, backgrounding and disposal
invalidate the pending token, so resumed async work cannot open a cancelled
recorder. A stale completion cannot release a newer request's reservation.

Speech callbacks are detached and the old listening UI is reset before stopping
the recognizer. Late stop/cancel errors and transcripts cannot open a speech
fallback dialog over a recording. Speech input refuses to claim a microphone
that is recording or reserved for startup, including after asynchronous init.

The webapp shows a cancellable starting state before permissions or recordStart
returns. Recording duration begins on successful startup. Changing cards cancels
pending starts; a late start response deletes its abandoned file without sending
a global Stop that could interrupt the new card's recording. Errors restore an
idle Record button with permission/busy/startup guidance. Update the native app
and web source together for cancellation across bridge awaits.
