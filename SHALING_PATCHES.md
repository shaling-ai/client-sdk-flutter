# Shaling AI fork of livekit_client: maintainer guide

This repository is Shaling AI's fork of [livekit/client-sdk-flutter](https://github.com/livekit/client-sdk-flutter),
the Flutter package `livekit_client`. It carries a few small fixes on top of upstream releases until upstream ships
them. It is not an official LiveKit project and is not published to pub.dev: apps use it as a git dependency pinned
to a commit SHA.

Read this before you change the SDK, upgrade it, or need to know what an app build runs.

[Rules](#rules) · [Branches and tags](#branches-and-tags) · [Pinned commits](#pinned-commits) ·
[Patches](#patches) · [Making a change](#making-a-change) · [Upgrading upstream](#upgrading-to-a-newer-upstream-release) ·
[Reporting upstream](#reporting-upstream) · [Consumers](#consumers) · [Repository settings](#repository-settings)

## Rules

1. **Everything here is public**: code, comments, tests, commit messages, branch and tag names, tag messages, pull
   requests and reviews. Never write internal information into any of them: no user, account, session, room or
   phone identifiers, no customer names, no production logs, no internal links, hosts or repository names, no
   credentials. Tests use made-up values (`PA_agent`, `TR_a`).
2. **Commit as your GitHub noreply address** (`<id>+<login>@users.noreply.github.com`, from GitHub → Settings →
   Emails), not a work or personal address. Set it in your clone: `git config user.email <id>+<login>@users.noreply.github.com`.
3. **Pull requests go to this repository.** For a fork, GitHub preselects `livekit/client-sdk-flutter` as the base
   repository. Switch it to `shaling-ai/client-sdk-flutter`, with the line you change as the base branch
   (`shaling/v2.9.0`). With the CLI, run `gh repo set-default shaling-ai/client-sdk-flutter` once per clone.
   Anything meant for LiveKit goes through [Reporting upstream](#reporting-upstream).
4. **`shaling/*` branches and tags are append-only.** Never force-push them, rebase them in place or delete them.
   Apps pin commits by SHA, and pub fetches a git dependency by cloning this repository's branches and tags. A pinned
   commit that no branch or tag contains may no longer be fetchable, and every app version that pins it would stop
   building. Repository rulesets enforce this (see [Repository settings](#repository-settings)).
5. **Leave `main` and upstream's tags alone.** `main` is upstream's `main` as it was when we forked; nobody maintains
   it. GitHub Actions is off in this repository, so the workflows inherited from upstream (`.github/workflows/`:
   pub.dev publishing, web and docs deploys) never run here. Still:
   - do not use GitHub's "Sync fork" button on a `shaling/*` branch, because it merges upstream `main` into it (the
     rulesets do not stop this: a merge is a normal update);
   - do not push upstream tags to this repository;
   - push named refs only (`git push origin shaling/v2.9.0`), never `--all`, `--tags` or `--mirror`.
6. **Behaviour changes are switchable and off by default.** A patch that changes what the SDK does adds a static
   switch that the SDK reads each time it is needed (null or false = stock behaviour). That way an app can turn the
   patch off from a remote flag without a new build. If a patch cannot change behaviour that works today, for example
   a crash fix, say so in its ledger entry instead.
7. **Keep upstream's version.** `version:` in `pubspec.yaml` and `LiveKitClient.version` in `lib/src/livekit.dart`
   stay at the upstream value, because the SDK reports its version to the LiveKit server. The commit SHA identifies
   the fork.
8. **Mark every change.** Apache-2.0 section 4(b) requires the first item.
   - Each modified upstream file carries this notice below its license header. A later patch extends the
     `<what>` list of a file that already has one.

     ```dart
     // Modified by Shaling AI in 2026: <what, in a few words>
     // (see SHALING_PATCHES.md). Not part of upstream livekit/client-sdk-flutter.
     ```

   - Every changed site has a comment that starts with `Shaling AI fork patch`. Then
     `git grep -n "Shaling AI fork patch"` lists them all, and rebase conflicts are easy to place.
   - A new file starts with the Apache-2.0 header and `Copyright <year> Shaling AI`.
   - `LICENSE` and `NOTICE` stay unchanged.

## Branches and tags

| Ref | What it is |
|---|---|
| `shaling/v2.9.0` | **Maintenance line for upstream 2.9.0**: upstream tag `v2.9.0` plus our commits, linear and append-only. New work for apps on 2.9.0 starts here. |
| tags `shaling/v2.9.0-<n>` | One annotated tag for each commit an app pins, numbered from 1. Never moved or deleted. |
| `shaling/v2.9.0-stale-participant-info` | Where P1 was first published. It is frozen at `8880cb57`; do not push to it. |
| tag `shaling/livekit_client-2.9.0-stale-info-1` | First tag of `8880cb57`, made before the numbering above. Same commit as `shaling/v2.9.0-1`; keep it. |
| `main` | Upstream `main` as forked, not maintained (rule 5). |

A newer upstream base gets its own line, `shaling/v<upstream version>`, with its own tags
`shaling/v<upstream version>-<n>`. Older lines stay as they are, for the app versions that pin them.

## Pinned commits

Apps pin only commits listed here. The tip of a line may be ahead of its last tag with documentation commits.

| Tag | Commit | Base | Patches |
|---|---|---|---|
| `shaling/v2.9.0-1` | `8880cb57c54dfc66ec9c193d524e2bfb8408f1eb` | `v2.9.0` (`8f86c55`) | P1 |
| `shaling/v2.9.0-2` | `b3e7057d6f33e8fac4dfea54e55453b82b76ec53` | `v2.9.0` (`8f86c55`) | P1, with its lock-timeout follow-up (#1) |
| `shaling/v2.9.0-3` | `228e27c7b2712f82d906f8c01d87faa68d1472fe` | `v2.9.0` (`8f86c55`) | P1 and P2 (#4) |

## Patches

### P2: stop waiting after a rejected resume

- Since: `shaling/v2.9.0-3` (commit `228e27c7`, #4).

- Switch: `ResumeLeaveAbort.shouldAbortResumeOnReconnectLeave(Engine)`, read once per
  attempt; null, false or an exception uses the unchanged stock resume body.
- Enabled scope: a `STATE_MISMATCH` reconnect leave from the socket opened by the
  current attempt, before its reconnect response has been accepted. Both protocol
  action RECONNECT and legacy canReconnect are supported; RESUME retains priority.
- A socket-bound opaque owner excludes messages from older sockets. The attempt
  waits for connect to return before throwing `ResumeAbortedByLeaveException`;
  it never races socket creation. The response wait is woken without an error
  future, and its timer is always cancelled. The retry catch independently selects
  full restart even if the leave handler's upgrade is overwritten.
- Accepted resumes, migration and other leave reasons, idle/full-restart leaves,
  retry delay, retry budget and PC-trigger policy retain their existing behavior.
- `EngineResumeAbortedByLeaveEvent` is internal observation of an actual abort.
  No application data or alarm implementation lives in this public SDK.
- Tests: `test/core/resume_leave_abort_test.dart`, including stock controls,
  early replies, old-socket replies, close-after-leave, priority, accepted-response
  boundary, callback errors, one-read semantics and two independent engines.
- Validation: 23 focused tests passed; full suite 421 passed / 1 skipped both
  with the default unset and with the default forced on. Six mutations were
  detected. Controlled physical-device testing received a real rejection and
  reduced leave-to-full-restart from 15,312 ms (off) to 319 ms (on), preserving
  the session in the successful enabled retry. This does not establish the
  natural production trigger or replace consumer release acceptance.

### P1: out-of-date ParticipantInfo removes live tracks

| | |
|---|---|
| Since | `shaling/v2.9.0-1` (commit `8880cb57`). The lock-timeout follow-up since `shaling/v2.9.0-2` (commit `b3e7057d`, #1). |
| Files | `lib/src/participant/remote.dart`, `lib/src/participant/participant.dart`, `lib/src/core/room.dart`. No new dependencies (`synchronized` is already one). |
| Tests | `test/core/stale_participant_info_test.dart`: 29 tests on the line since the two bypass tests; 27 at `shaling/v2.9.0-2`; 23 at `shaling/v2.9.0-1`. |
| Switch | `RemoteParticipant.shouldIgnoreStaleParticipantInfo` (`bool Function()?`, null = stock). Observer: `RemoteParticipant.staleParticipantInfoObserver`. |
| Upstream | Not reported yet. |
| Drop when | Upstream both ignores an out-of-date info in `RemoteParticipant.updateFromInfo` and applies a participant's held-back updates in order (see [Upgrading](#upgrading-to-a-newer-upstream-release)). |

**Problem.** `Room._onParticipantUpdateEvent` holds back ParticipantUpdates that arrive before the local participant
exists, then applies them all at once after `RoomConnectedEvent`. Two things then remove publications that are still
live, without unsubscribing:

1. `Participant.updateFromInfo` rejects an info that is older than the one already applied. But
   `RemoteParticipant.updateFromInfo` ignores that result (`//return false;`, since v2.0.0 / #435) and reconciles the
   old track list.
2. The held-back updates interleave at `await`s. An older update computes its removals after a newer one has added
   tracks, so no version check fails.

**Change.** Nothing changes while the switch is unset.

- When `shouldIgnoreStaleParticipantInfo` returns true, `updateFromInfo` runs one update at a time per participant,
  using a `synchronized` lock. An update that waits more than 5 s runs without waiting and still keeps the version
  check. For an out-of-date info, `updateFromInfo` returns `false` before touching tracks. A callback that throws
  counts as false. The switch is read once per update, so the app can return its current feature-flag value.
- `staleParticipantInfoObserver` (optional) is called for every out-of-date info, with the switch on or off. It gets
  the room, the participant and an immutable `StaleParticipantInfo`: participant sid and kind, applied and stale
  versions, the stale info's track sids, the published sids that info omits, and whether it was ignored. The compared
  state is captured right before the base class compares. Errors thrown by the observer are swallowed.
- `Participant.appliedInfoVersion` and `Participant.appliedInfoTrackSids` (`@internal`) expose the applied info.
  `Participant.isCurrentInfo` (`@protected`, since `shaling/v2.9.0-2`) tells whether an info is still the accepted one.
- `Room` flushes pending tracks after an ignored info too, as stock does after every update.

**Tests.** Every scenario runs with the switch off and on, including the order where all newer updates are held back
together. The `switch off (stock)` cases assert the defect itself: the track *is* removed. They therefore also check
that upstream still behaves this way.

**Mutation check.** Undo one part of the patch at a time and run the test file. Each undo must turn tests red:

| Undo | Tests that fail |
|---|---|
| the early `return false` for an out-of-date info | 5 `switch on` tests, e.g. "an older ParticipantInfo after a newer one" |
| the pending-track flush after an ignored info (`room.dart`) | "media queued while reconnecting attaches when the next update is an older one" |
| the `try`/`catch` around the switch call | "a switch that throws keeps the stock behaviour" |
| the omitted sids (compute them from the wrong list) | "an older ParticipantInfo after a newer one", "the snapshot holds the state the out-of-date info was compared against" (both switch states) |
| the per-participant lock | "updates parked together after the join snapshot keep every published track", "an update stuck past the lock timeout does not block later updates" |
| the lock timeout | "an update stuck past the lock timeout does not block later updates" |
| capturing the compared state, or the participant kind, before the `await` | "the snapshot holds the state the out-of-date info was compared against" |
| `-2`: the snapshot check after the base update (`_updateFromInfo`) | "an update that bypasses the queue … right after the base update: the superseded update adds no tracks" |
| `-2`: the snapshot check before each removal (`_updateTracks`) | "a timed-out update protects retained tracks when slow cleanup resumes" (all 3 variants) |
| `-2`: the publication-event filter (`_updateTracks`) | "an update that bypasses the queue … after the accepted update added a track: the track is not announced" |
| `-2`: `isCurrentInfo` made always true | the 3 "a timed-out update protects retained tracks …" variants and both bypass tests |
| `-2`: `_updateTracks` called without the snapshot | the 3 "a timed-out update protects retained tracks …" variants and "… the track is not announced" |
| `-2`: `isCurrentInfo` made always false | 9 tests, including "a rejected update after the lock timeout does not cancel accepted cleanup" |

Rows marked `-2` belong to the lock-timeout follow-up below. They were run on the line after the two bypass tests were
added. The bypass tests turn the switch off between two updates. They need that because the windows they cover are one
microtask long, and only an update that bypasses the per-participant queue can enter them. Updates that wait in the
queue, or that leave it after the lock timeout, cannot.

Full SDK suite (Flutter 3.38.4), first with no switch set, then with the switch forced on in every test:

- at `shaling/v2.9.0-1`: 392 passed, 0 failed, 1 skipped; forced on, 391 passed and 1 failed;
- at `shaling/v2.9.0-2`: 396 passed, 0 failed, 1 skipped; forced on, 395 passed and 1 failed;
- on the line with the two bypass tests (no new tag, tests only): 398 passed, 0 failed, 1 skipped; forced on, 397
  passed and 1 failed.

With the switch forced on, the one failure is "the switch defaults to the stock behaviour", as expected.

**Reconciliation after the lock timeout** (since `shaling/v2.9.0-2`).

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

Validation of this follow-up: 396 tests passed and 1 was skipped; analysis, formatting, import order and
version consistency checks passed. The two same-SID retention regressions fail without the fix. The mutation
table above shows which of its checks the tests cover.

## Making a change

Fixing a patch and adding a new one follow the same steps.

1. **Check that it belongs here.** It does when all three hold:
   - the defect is in `livekit_client`;
   - the app cannot reasonably work around it;
   - no upstream release has the fix that we could move to instead (read upstream `main` and its `CHANGELOG.md` first).

   Keep the diff as small as the fix allows. Avoid new package dependencies, because every app's lockfile resolves
   them too.
2. **Set up a clone** (once):

   ```bash
   git clone https://github.com/shaling-ai/client-sdk-flutter.git
   cd client-sdk-flutter
   git remote add upstream https://github.com/livekit/client-sdk-flutter.git
   git fetch upstream --tags            # upstream tags stay in your clone (rule 5)
   gh repo set-default shaling-ai/client-sdk-flutter
   git config user.email <id>+<login>@users.noreply.github.com
   ```

3. **Branch from the line** the app uses: `git switch -c fix/<topic> origin/shaling/v2.9.0`.
4. **Write the failing test first.** Put it in the test file of the area, or in a new `test/**/<topic>_test.dart`
   with the rule 8 header. For a switchable patch, run each scenario with the switch off and on, as P1's tests do.
5. **Implement it** following rules 6–8. In the same commit, add or update the patch's entry under
   [Patches](#patches): problem, change, files, tests, switch, mutation check and drop condition.
6. **Check it** with the Flutter version the apps release with (3.38.x at the time of writing):

   ```bash
   flutter pub get
   dart format . --set-exit-if-changed   # page width 120, from analysis_options.yaml
   flutter analyze
   flutter test test/core/stale_participant_info_test.dart <your tests>
   flutter test                          # full suite; compare with the counts under Patches
   ```

   Then do the mutation check: undo each part of your change on its own and re-run your tests. Each undo must make at
   least one test fail. If the switch may be on in production, also run the full suite once with it forced on, then
   revert. For example, temporarily declare
   `static bool Function()? shouldIgnoreStaleParticipantInfo = _forcedOn; static bool _forcedOn() => true;`.
   Only tests that assert the stock default may fail.
7. **Commit, and open a pull request** in this repository against `shaling/v2.9.0` (rule 3). Make one commit per
   change, with a message that says what changes and why, in upstream's terms. A second engineer reviews it. Merge it
   with "Squash and merge" so the line stays linear.
8. **Publish it for apps.** Tag the merged commit and push the tag:

   ```bash
   git fetch origin
   git tag -a shaling/v2.9.0-<n> <commit> -m "livekit_client 2.9.0 with Shaling AI patches P1, P<k>"
   git push origin shaling/v2.9.0-<n>
   ```

   Add the tag to [Pinned commits](#pinned-commits) in a follow-up pull request. Then point the app at the full
   40-character SHA (see [Consumers](#consumers)).

## Upgrading to a newer upstream release

```bash
git fetch upstream --tags
git switch -c shaling/v<new> v<new>                  # e.g. shaling/v2.13.1 from tag v2.13.1
git cherry-pick v2.9.0..origin/shaling/v2.9.0        # our patch and documentation commits, in order
```

- Resolve conflicts at the `Shaling AI fork patch` sites. This is a new branch, so you may squash each patch into one
  commit here.
- For each patch, check whether upstream fixed the problem: read upstream's code at the patched sites and run the
  patch's tests. If a `switch off (stock)` test of P1 fails because the track is no longer removed, upstream changed
  that path. Then drop or shrink the patch instead of editing the test. Drop P1 entirely once upstream covers both
  causes: the early return and the ordering.
- Run the checks of step 6 above and push the new line. Tag it `shaling/v<new>-1`, then update this file on the new
  line: pinned commits, patches, and the base in [Branches and tags](#branches-and-tags).
- Leave the old line as it is. Moving an app to a new SDK version is a change in that app, with its own testing.

## Reporting upstream

These fixes belong upstream. Before you open an issue or a pull request at livekit/client-sdk-flutter:

1. reproduce the problem on upstream `main`, without our switch;
2. write it up in upstream's terms, with made-up identifiers (rule 1);
3. get the repository owner's OK.

Then link the issue in the patch's "Upstream" row.

## Consumers

Apps pin a commit by its full SHA, never by a tag or a branch, because both can move. A dependency override applies
the fork to every package in the app that depends on `livekit_client`:

```yaml
dependency_overrides:
  livekit_client:
    git:
      url: https://github.com/shaling-ai/client-sdk-flutter.git
      ref: 8880cb57c54dfc66ec9c193d524e2bfb8408f1eb   # shaling/v2.9.0-1
```

After you change `ref`, run `flutter pub get` with the app's release Flutter version. Check that `pubspec.lock` changed
only for this package, and that its `resolved-ref` equals `ref`. To try an unpublished change in an app, point the
override at your clone (`path: ../client-sdk-flutter`), and never commit that. Each app documents in its own
repository which commit it pins, how it turns the switches on, and how it rolls back.

## Repository settings

Only a repository admin changes these, and only with the reason recorded here.

| Setting | Value | Why |
|---|---|---|
| Default branch | `main` (upstream's, not maintained) | GitHub offers "Sync fork" on the default branch; on a maintenance line it would merge upstream `main` into it. |
| GitHub Actions | Off | The inherited workflows publish to pub.dev and deploy LiveKit's docs and web demo. None of them is ours to run. |
| Ruleset "Protect shaling branches" | `refs/heads/shaling/**`: no deletion, no force-push | Rule 4. Normal pushes, merges and new branches are allowed. |
| Ruleset "Protect shaling tags" | `refs/tags/shaling/**`: no deletion, no update, no force-push | Rule 4: a tag never moves. New tags are allowed. |

GitHub rejects a push that breaks a ruleset with "push declined due to repository rule violations". That rejection is
working as intended: add a new commit or a new tag instead. Do not relax a ruleset to get a push through.

## License

Apache License 2.0, like upstream. `LICENSE` and `NOTICE` are upstream's files, unchanged. Shaling AI's changes are
under the same license.
