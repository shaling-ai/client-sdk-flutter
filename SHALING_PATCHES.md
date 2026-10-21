# Shaling AI patches on livekit_client

This branch builds on upstream tag `v2.9.0` (`8f86c55`). The package version stays `2.9.0`; the
host app pins the commit SHA in `dependency_overrides`. Tag `shaling/livekit_client-2.9.0-stale-info-1`
marks the first patch (`8880cb57`). A host must advance its SHA to include subsequent fixes.

Licensed under the Apache License 2.0 like upstream; `LICENSE` and `NOTICE` are unchanged. Each file this
patch changes carries a "Modified by Shaling AI" line; the added test carries its own header.

## Out-of-date ParticipantInfo removes live tracks

`Room._onParticipantUpdateEvent` holds back ParticipantUpdates received before the local participant exists
and applies them after `RoomConnectedEvent`, all at once. Two things then remove publications that are still
live, without unsubscribing:

1. An info older than the one already applied is rejected by `Participant.updateFromInfo`, but
   `RemoteParticipant.updateFromInfo` ignores the result (`//return false;`, since v2.0.0 / #435) and
   reconciles the old track list.
2. The held-back updates interleave at `await`s, so an older update computes its removals after a newer one
   added tracks; no version check fails.

The commit adds, with no change to the default behavior:

- `RemoteParticipant.shouldIgnoreStaleParticipantInfo` (static `bool Function()?`, null = stock). When it
  returns true, `updateFromInfo` runs one update at a time per participant (a `synchronized` lock; an update
  that waits more than 5 s runs without waiting) and returns `false` for an out-of-date info before touching
  tracks. A throwing callback counts as false. It is read once per update, so the host app returns its
  current feature-flag value.
- `RemoteParticipant.staleParticipantInfoObserver` (static, optional): called with the room, the participant
  and an immutable `StaleParticipantInfo` (compared participant sid and kind, applied and stale versions, the stale
  info's track sids, the published sids it omits, whether it was ignored) for every out-of-date info. The
  compared state is captured right before the base class compares. Errors are swallowed.
- `Participant.appliedInfoVersion` and `Participant.appliedInfoTrackSids` (`@internal`).
- `Room`: pending tracks are flushed after an ignored info too, as stock flushes after every update.
- `test/core/stale_participant_info_test.dart`: every scenario with the switch false (the defect reproduces)
  and true, including the production order where all newer updates are held back together.

### Reconciliation after the lock timeout

The 5 s escape keeps a stuck native track stop from blocking all future updates, but serialization alone
does not protect the old update when that stop eventually completes. Its previously computed removal list
can delete a track retained by a newer snapshot that ran after the timeout.

With the switch ON, reconciliation now checks that its exact accepted snapshot is still current after the
base update and before each removal. Equal-version replacements and a new participant SID also supersede
that snapshot; rejected stale updates do not. New-publication events are emitted only for publications still
present and listed by the current snapshot. A retained publication is still announced even if the update
that first added it was superseded, because the newer update treats it as existing.

This does not cancel an already running native stop. It prevents its continuation from removing additional
publications under an obsolete snapshot. The OFF path and the 5 s escape remain available. Regression tests
hold a real SDK media-track cleanup at a controlled future, let a replacement snapshot pass the timeout,
then release the old cleanup and verify the retained publication survives. A rejected-update control verifies
that valid cleanup can still finish.

Upstream issue: (link after posting).

## Maintenance

- Upgrading the SDK: rebase this commit onto the new tag, run
  `flutter test test/core/stale_participant_info_test.dart` and the full suite, tag and push, then update
  the SHA in the host app (its version guard test pins it).
- When upstream fixes both paths, drop this fork and the host override.
