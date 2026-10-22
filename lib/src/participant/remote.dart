// Copyright 2024 LiveKit, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Modified by Shaling AI in 2026: handling of out-of-date ParticipantInfo
// (see SHALING_PATCHES.md). Not part of upstream livekit/client-sdk-flutter.

import 'dart:async' as async;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart' as sync;

import '../core/room.dart';
import '../events.dart';
import '../exceptions.dart';
import '../extensions.dart';
import '../internal/events.dart';
import '../logger.dart';
import '../proto/livekit_models.pb.dart' as lk_models;
import '../publication/remote.dart';
import '../support/platform.dart';
import '../track/options.dart';
import '../track/remote/audio.dart';
import '../track/remote/remote.dart';
import '../track/remote/video.dart';
import '../types/other.dart';
import 'participant.dart';

/// Result of creating a RemoteParticipant with all its initial data populated.
///
/// This struct is returned by [RemoteParticipant.createFromInfo] and contains
/// the fully initialized participant along with the list of track publications
/// that were added during creation. The caller is responsible for emitting
/// events in the correct order.
@internal
class ParticipantCreationResult {
  /// The fully initialized remote participant with all basic info and tracks populated.
  final RemoteParticipant participant;

  /// List of new track publications that were added during participant creation.
  /// The caller should emit [TrackPublishedEvent] for each of these after
  /// emitting [ParticipantConnectedEvent].
  final List<RemoteTrackPublication> newPublications;

  const ParticipantCreationResult({
    required this.participant,
    required this.newPublications,
  });
}

/// Shaling AI fork patch (not upstream): an out-of-date
/// [lk_models.ParticipantInfo] received by [RemoteParticipant.updateFromInfo],
/// captured before its track list is (or is not) reconciled.
@immutable
class StaleParticipantInfo {
  const StaleParticipantInfo({
    required this.participantSid,
    required this.participantKind,
    required this.appliedVersion,
    required this.staleVersion,
    required this.staleTrackSids,
    required this.omittedTrackSids,
    required this.ignored,
  });

  /// Participant sid the out-of-date info was compared against.
  final String participantSid;

  /// Participant kind at that comparison.
  final ParticipantKind participantKind;

  /// Version already applied for that sid when the info was compared.
  final int appliedVersion;

  /// Version of the out-of-date info.
  final int staleVersion;

  /// Track sids the out-of-date info lists.
  final List<String> staleTrackSids;

  /// Published track sids the out-of-date info omits. The stock SDK removes
  /// these publications.
  final List<String> omittedTrackSids;

  /// Whether the info was ignored, see
  /// [RemoteParticipant.shouldIgnoreStaleParticipantInfo].
  final bool ignored;
}

/// Shaling AI fork patch (not upstream): see
/// [RemoteParticipant.staleParticipantInfoObserver].
typedef StaleParticipantInfoObserver = void Function(
  Room room,
  RemoteParticipant participant,
  StaleParticipantInfo info,
);

/// Represents other participant in the [Room].
class RemoteParticipant extends Participant<RemoteTrackPublication> {
  /// Shaling AI fork patch (not upstream).
  ///
  /// `Room` applies ParticipantUpdates received before the local participant
  /// exists only after `RoomConnectedEvent`, all at once, and the stock
  /// [updateFromInfo] removes live publications in two ways:
  /// - an info older than the one already applied still reconciles its track
  ///   list, because the early return after [Participant.updateFromInfo] is
  ///   commented out;
  /// - concurrent updates interleave at `await`s, so an older update can
  ///   compute its removals after a newer one added tracks.
  ///
  /// When this returns true, updates for a participant run one at a time and
  /// an out-of-date info is ignored, as in client-sdk-js. Null (the default),
  /// false or a throw keep the stock behaviour. It is called once per update,
  /// so the host app can return its current feature-flag value.
  static bool Function()? shouldIgnoreStaleParticipantInfo;

  /// Shaling AI fork patch (not upstream): called for every out-of-date info
  /// [updateFromInfo] receives. Errors are logged and swallowed.
  static StaleParticipantInfoObserver? staleParticipantInfoObserver;

  /// Shaling AI fork patch (not upstream): how long an update waits for the
  /// previous update of the same participant before running without waiting.
  static const _updateLockTimeout = Duration(seconds: 5);

  final _updateLock = sync.Lock();

  RemoteParticipant._({
    required Room room,
    required String sid,
    required String identity,
    required String name,
  }) : super(
          room: room,
          sid: sid,
          identity: identity,
          name: name,
        );

  /// Creates a fully initialized RemoteParticipant without emitting events.
  ///
  /// Populates the participant with all data from [info] including metadata, permissions,
  /// and track publications. No events are emitted, allowing the caller to control event
  /// timing and order.
  ///
  /// Returns [ParticipantCreationResult] with the participant and new track publications.
  /// The caller should emit [ParticipantConnectedEvent] first, then [TrackPublishedEvent]
  /// for each track, ensuring the participant is fully populated when connected event fires.
  ///
  /// @internal - Should only be called by [Room].
  @internal
  static Future<ParticipantCreationResult> createFromInfo({
    required Room room,
    required lk_models.ParticipantInfo info,
  }) async {
    final participant = RemoteParticipant._(
      room: room,
      sid: info.sid,
      identity: info.identity,
      name: info.name,
    );
    // Update basic participant info (state, metadata, etc.)
    await participant._updateBasicInfo(info);
    // Add tracks to participant without emitting events
    final newPubs = await participant._addTracks(info.tracks);
    // Return result for caller to emit events in correct order
    return ParticipantCreationResult(
      participant: participant,
      newPublications: newPubs,
    );
  }

  Future<void> _updateBasicInfo(lk_models.ParticipantInfo info) async {
    // Only call superclass updateFromInfo to update basic participant state
    await super.updateFromInfo(info);
  }

  Future<List<RemoteTrackPublication>> _addTracks(List<lk_models.TrackInfo> tracks) async {
    final newPubs = <RemoteTrackPublication>[];
    for (final trackInfo in tracks) {
      final RemoteTrackPublication? pub = getTrackPublicationBySid(trackInfo.sid);
      if (pub == null) {
        final RemoteTrackPublication pub;
        if (trackInfo.type == lk_models.TrackType.VIDEO) {
          pub = RemoteTrackPublication<RemoteVideoTrack>(
            participant: this,
            info: trackInfo,
          );
        } else if (trackInfo.type == lk_models.TrackType.AUDIO) {
          pub = RemoteTrackPublication<RemoteAudioTrack>(
            participant: this,
            info: trackInfo,
          );
        } else {
          throw UnexpectedStateException('Unknown track type');
        }
        newPubs.add(pub);
        addTrackPublication(pub);
      } else {
        pub.updateFromInfo(trackInfo);
      }
    }
    return newPubs;
  }

  /// A convenience property to get all video tracks.
  @override
  List<RemoteTrackPublication<RemoteVideoTrack>> get videoTrackPublications =>
      trackPublications.values.whereType<RemoteTrackPublication<RemoteVideoTrack>>().toList();

  /// A convenience property to get all audio tracks.
  @override
  List<RemoteTrackPublication<RemoteAudioTrack>> get audioTrackPublications =>
      trackPublications.values.whereType<RemoteTrackPublication<RemoteAudioTrack>>().toList();

  List<RemoteTrackPublication> get subscribedTracks =>
      trackPublications.values.where((e) => e.subscribed).cast<RemoteTrackPublication>().toList();

  @override
  RemoteTrackPublication? getTrackPublicationByName(String name) {
    final track = super.getTrackPublicationByName(name);
    if (track != null) {
      return track;
    }
    return null;
  }

  @override
  RemoteTrackPublication? getTrackPublicationBySid(String sid) {
    final track = super.getTrackPublicationBySid(sid);
    if (track != null) {
      return track;
    }
    return null;
  }

  @override
  RemoteTrackPublication? getTrackPublicationBySource(TrackSource source) {
    final track = super.getTrackPublicationBySource(source);
    if (track != null) {
      return track;
    }
    return null;
  }

  @internal
  Future<void> addSubscribedMediaTrack(
    rtc.MediaStreamTrack mediaTrack,
    rtc.MediaStream stream,
    String trackSid, {
    rtc.RTCRtpReceiver? receiver,
    AudioOutputOptions audioOutputOptions = const AudioOutputOptions(),
  }) async {
    logger.fine('addSubscribedMediaTrack()');

    // If publication doesn't exist yet...
    RemoteTrackPublication? pub = getTrackPublicationBySid(trackSid);
    if (pub == null) {
      logger.fine('addSubscribedMediaTrack() pub is null, will wait...');
      logger.fine('addSubscribedMediaTrack() tracks: $trackPublications');
      // Wait for the metadata to arrive
      final event = await events.waitFor<TrackPublishedEvent>(
        filter: (event) => event.participant == this && event.publication.sid == trackSid,
        duration: room.connectOptions.timeouts.publish,
        onTimeout: () => throw TrackSubscriptionExceptionEvent(
          participant: this,
          sid: trackSid,
          reason: TrackSubscribeFailReason.notTrackMetadataFound,
        ),
      );
      pub = event.publication;
      logger.fine('addSubscribedMediaTrack() did receive pub');
    }

    // Check if track type is supported, throw if not.
    if (![lk_models.TrackType.AUDIO, lk_models.TrackType.VIDEO].contains(pub.kind.toPBType())) {
      throw TrackSubscriptionExceptionEvent(
        participant: this,
        sid: trackSid,
        reason: TrackSubscribeFailReason.unsupportedTrackType,
      );
    }

    // create Track
    final RemoteTrack track;
    if (pub.kind == TrackType.VIDEO) {
      // video track
      track = RemoteVideoTrack(pub.source, stream, mediaTrack, receiver: receiver);
    } else if (pub.kind == TrackType.AUDIO) {
      // audio track
      track = RemoteAudioTrack(pub.source, stream, mediaTrack, receiver: receiver);

      final listener = track.createListener();
      listener.on<AudioPlaybackStarted>((event) {
        logger.fine('AudioPlaybackStarted');
        room.engine.events.emit(event);
      });

      listener.on<AudioPlaybackFailed>((event) {
        logger.fine('AudioPlaybackFailed');
        room.engine.events.emit(event);
      });
    } else {
      throw UnexpectedStateException('Unknown track type');
    }

    /// Apply audio output selection for the web.
    if (pub.kind == TrackType.AUDIO && lkPlatformIs(PlatformType.web)) {
      if (audioOutputOptions.deviceId != null) {
        (track as RemoteAudioTrack).setSinkId(audioOutputOptions.deviceId!);
      }
    }

    await pub.updateTrack(track);
    await pub.updateSubscriptionAllowed(true);
    addTrackPublication(pub);

    [events, room.events].emit(TrackSubscribedEvent(
      participant: this,
      track: track,
      publication: pub,
    ));

    await track.start();
  }

  @override
  @internal
  Future<bool> updateFromInfo(lk_models.ParticipantInfo info) async {
    // Shaling AI fork patch: see [shouldIgnoreStaleParticipantInfo].
    var patched = false;
    try {
      patched = shouldIgnoreStaleParticipantInfo?.call() ?? false;
    } catch (error) {
      logger.warning('shouldIgnoreStaleParticipantInfo failed: $error');
    }
    if (!patched) return _updateFromInfo(info, patched: false);
    var started = false;
    try {
      return await _updateLock.synchronized(() {
        started = true;
        return _updateFromInfo(info, patched: true);
      }, timeout: _updateLockTimeout);
    } on async.TimeoutException {
      if (started) rethrow;
      // Leaves the queue. Reconciliation checks the accepted snapshot again
      // after awaits so an older continuation cannot remove newer tracks.
      logger.warning('updateFromInfo: the previous update is still running, continuing without waiting');
      return _updateFromInfo(info, patched: true);
    }
  }

  Future<bool> _updateFromInfo(lk_models.ParticipantInfo info, {required bool patched}) async {
    logger.fine('RemoteParticipant.updateFromInfo(info: $info)');
    // Shaling AI fork patch: the base class compares synchronously when
    // called, so this is the state the comparison sees.
    final compared = staleParticipantInfoObserver == null
        ? null
        : (sid: sid, kind: kind, version: appliedInfoVersion, published: trackPublications.keys.toList());
    if (!await super.updateFromInfo(info)) {
      // Shaling AI fork patch: upstream leaves `//return false;` here.
      if (compared != null) _observeStaleInfo(info, compared, ignored: patched);
      if (patched) return false;
    }

    // Shaling AI fork patch: a timed-out update can replace the snapshot while
    // the base-class future is being awaited, even when both updates passed the
    // version check.
    if (patched && !isCurrentInfo(info)) return false;
    return _updateTracks(info.tracks, currentInfo: patched ? info : null);
  }

  void _observeStaleInfo(
    lk_models.ParticipantInfo info,
    ({String sid, ParticipantKind kind, int? version, List<String> published}) compared, {
    required bool ignored,
  }) {
    final observer = staleParticipantInfoObserver;
    if (observer == null) return;
    try {
      final staleTrackSids = List<String>.unmodifiable(info.tracks.map((track) => track.sid));
      observer(
        room,
        this,
        StaleParticipantInfo(
          participantSid: compared.sid,
          participantKind: compared.kind,
          appliedVersion: compared.version!,
          staleVersion: info.version,
          staleTrackSids: staleTrackSids,
          omittedTrackSids: List<String>.unmodifiable(
            compared.published.where((sid) => !staleTrackSids.contains(sid)),
          ),
          ignored: ignored,
        ),
      );
    } catch (error) {
      logger.warning('staleParticipantInfoObserver failed: $error');
    }
  }

  // Shaling AI fork patch: [currentInfo] and the bool result are not upstream.
  // With a null [currentInfo] (switch off) this behaves as stock and returns
  // true; otherwise it returns whether [currentInfo] is still the accepted one.
  Future<bool> _updateTracks(List<lk_models.TrackInfo> tracks, {lk_models.ParticipantInfo? currentInfo}) async {
    // Add new tracks
    final newPubs = await _addTracks(tracks);

    // Emit events for new publications
    for (final pub in newPubs) {
      // Shaling AI fork patch: a newer update may have removed or replaced this
      // publication across the await. Keep announcing retained publications:
      // the newer update saw them as existing and therefore will not emit
      // their published event.
      if (currentInfo != null &&
          (isDisposed ||
              !identical(getTrackPublicationBySid(pub.sid), pub) ||
              !appliedInfoTrackSids.contains(pub.sid))) {
        continue;
      }
      final event = TrackPublishedEvent(
        participant: this,
        publication: pub,
      );
      if (room.connectionState == ConnectionState.connected) {
        [events, room.events].emit(event);
      }
    }

    // Remove any published track that is not in the info
    final validSids = tracks.map((e) => e.sid);
    final removeSids = trackPublications.keys.where((e) => !validSids.contains(e)).toSet();
    for (final sid in removeSids) {
      // Shaling AI fork patch: stopping the previous media track may outlive
      // the lock timeout. The precomputed removal list is no longer
      // authoritative after that await.
      if (currentInfo != null && !isCurrentInfo(currentInfo)) return false;
      await removePublishedTrack(sid);
    }
    return currentInfo == null || isCurrentInfo(currentInfo);
  }

  Future<void> removePublishedTrack(String trackSid, {bool notify = true}) async {
    logger.finer('removePublishedTrack track sid: $trackSid, notify: $notify');
    final pub = trackPublications.remove(trackSid);
    if (pub == null) {
      logger.warning('Publication not found $trackSid');
      return;
    }
    final track = pub.track;
    // if has track
    if (track != null) {
      await track.stop();
      [events, room.events].emit(TrackUnsubscribedEvent(
        participant: this,
        track: track,
        publication: pub,
      ));
    }

    if (notify) {
      [events, room.events].emit(TrackUnpublishedEvent(
        participant: this,
        publication: pub,
      ));
    }

    await pub.dispose();
  }

  Future<void> removeAllPublishedTracks({bool notify = true}) async {
    final sids = trackPublications.keys.toList();
    for (final sid in sids) {
      await removePublishedTrack(sid, notify: notify);
    }
  }

  @internal
  lk_models.ParticipantTracks participantTracks() => lk_models.ParticipantTracks(
        participantSid: sid,
        trackSids: trackPublications.values.map((e) => e.sid),
      );
}
