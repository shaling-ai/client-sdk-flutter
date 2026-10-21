// Copyright 2026 Shaling AI
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

// Shaling AI fork patch tests (not upstream) for
// RemoteParticipant.shouldIgnoreStaleParticipantInfo. Every scenario runs with
// the switch returning false (stock 2.9.0 behaviour, the defect reproduces) and
// true (patched).
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/core/signal_client.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import '../mock/e2e_container.dart';
import '../mock/peerconnection_mock.dart';
import '../mock/websocket_mock.dart';
import 'signal_client_test.dart';

const agentSid = 'PA_agent';
const agentIdentity = 'agent';

final sipTrack = lk_models.TrackInfo(
  sid: 'TR_a',
  name: 'track-a',
  type: lk_models.TrackType.AUDIO,
);
final clientTrack = lk_models.TrackInfo(
  sid: 'TR_b',
  name: 'track-b',
  type: lk_models.TrackType.AUDIO,
);

lk_models.ParticipantInfo agentInfo(
  int version,
  List<lk_models.TrackInfo> tracks, {
  String sid = agentSid,
  String metadata = '',
  lk_models.ParticipantInfo_Kind kind = lk_models.ParticipantInfo_Kind.AGENT,
}) =>
    lk_models.ParticipantInfo(
      sid: sid,
      identity: agentIdentity,
      state: lk_models.ParticipantInfo_State.ACTIVE,
      kind: kind,
      version: version,
      metadata: metadata,
      tracks: tracks,
    );

List<int> update(lk_models.ParticipantInfo info) =>
    lk_rtc.SignalResponse(update: lk_rtc.ParticipantUpdate(participants: [info])).writeToBuffer();

RemoteParticipant? agentOf(Room room) => room.remoteParticipants[agentIdentity];

Future<void> settle([int ms = 50]) => Future<void>.delayed(Duration(milliseconds: ms));

class _Recorder {
  final published = <String>[];
  final unpublished = <String>[];
  final subscribed = <String>[];
  final unsubscribed = <String>[];
  final failures = <String>[];
  _Recorder(Room room) {
    room.events.on<TrackPublishedEvent>((e) => published.add(e.publication.sid));
    room.events.on<TrackUnpublishedEvent>((e) => unpublished.add(e.publication.sid));
    room.events.on<TrackSubscribedEvent>((e) => subscribed.add(e.publication.sid));
    room.events.on<TrackUnsubscribedEvent>((e) => unsubscribed.add(e.publication.sid));
    room.events.on<TrackSubscriptionExceptionEvent>((e) => failures.add('${e.sid}:${e.reason}'));
  }
}

void _deliverMedia(Engine engine, _FakeTrack track) => engine.events.emit(EngineTrackAddedEvent(
      track: track,
      stream: _FakeMediaStream('$agentSid|agent_stream'),
      receiver: null,
    ));

/// Engine whose connection state a test can hold at `reconnecting`.
class _HoldableEngine extends Engine {
  _HoldableEngine(SignalClient signalClient)
      : super(
          connectOptions: const ConnectOptions(),
          roomOptions: const RoomOptions(),
          signalClient: signalClient,
          peerConnectionCreate: MockPeerConnection.create,
        );

  ConnectionState? held;

  @override
  ConnectionState get connectionState => held ?? super.connectionState;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final observed = <StaleParticipantInfo>[];
  final observedRooms = <Room>[];
  setUp(() {
    observed.clear();
    observedRooms.clear();
    RemoteParticipant.staleParticipantInfoObserver = (room, participant, info) {
      observed.add(info);
      observedRooms.add(room);
    };
  });
  tearDown(() {
    RemoteParticipant.shouldIgnoreStaleParticipantInfo = null;
    RemoteParticipant.staleParticipantInfoObserver = null;
  });

  test('the switch defaults to the stock behaviour', () {
    expect(RemoteParticipant.shouldIgnoreStaleParticipantInfo, isNull);
  });

  for (final guard in [false, true]) {
    group(guard ? 'switch on' : 'switch off (stock)', () {
      setUp(() => RemoteParticipant.shouldIgnoreStaleParticipantInfo = () => guard);

      group('connected room', () {
        late E2EContainer container;
        late Room room;
        setUp(() async {
          container = E2EContainer();
          room = container.room;
          await container.connectRoom();
        });
        tearDown(() async => container.dispose());

        test('an older ParticipantInfo after a newer one', () async {
          final rec = _Recorder(room);
          container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack], metadata: 'm5')));
          await settle();
          container.wsConnector.onData(update(agentInfo(4, [sipTrack], metadata: 'm4')));
          await settle();

          final agent = agentOf(room)!;
          expect(observed, hasLength(1));
          final info = observed.single;
          expect(observedRooms.single, same(room));
          expect(info.participantSid, agentSid);
          expect(info.participantKind, ParticipantKind.AGENT);
          expect(info.appliedVersion, 5);
          expect(info.staleVersion, 4);
          expect(info.staleTrackSids, [sipTrack.sid]);
          expect(info.omittedTrackSids, [clientTrack.sid]);
          expect(info.ignored, guard);
          expect(() => info.omittedTrackSids.add('x'), throwsUnsupportedError);
          expect(agent.metadata, 'm5', reason: 'the base class already ignores the stale metadata');
          expect(agent.appliedInfoVersion, 5);
          expect(agent.appliedInfoTrackSids, [sipTrack.sid, clientTrack.sid],
              reason: 'the applied info still lists the track in both states');
          if (guard) {
            expect(rec.unpublished, isEmpty);
            expect(agent.getTrackPublicationBySid(clientTrack.sid), isNotNull);
          } else {
            expect(rec.unpublished, [clientTrack.sid], reason: 'stock: phantom unpublish');
            expect(agent.getTrackPublicationBySid(clientTrack.sid), isNull);
          }
        });

        test('the snapshot holds the state the out-of-date info was compared against', () async {
          container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
          await settle();
          final agent = agentOf(room)!;
          final rejoined = lk_models.TrackInfo(sid: 'TR_rejoined', name: 'track-b', type: lk_models.TrackType.AUDIO);
          // Called back to back, as two concurrent Room handlers would: the older
          // info is compared first, then the re-joined sid is applied before the
          // first call resumes.
          final older = agent.updateFromInfo(agentInfo(4, [sipTrack]));
          final newer = agent.updateFromInfo(
            agentInfo(1, [rejoined], sid: 'PA_agent_rejoined', kind: lk_models.ParticipantInfo_Kind.STANDARD),
          );
          await Future.wait([older, newer]);

          final info = observed.single;
          expect(info.participantSid, agentSid);
          expect(info.participantKind, ParticipantKind.AGENT);
          expect(agent.kind, ParticipantKind.STANDARD);
          expect(info.appliedVersion, 5);
          expect(info.omittedTrackSids, [clientTrack.sid]);
          expect(agent.sid, 'PA_agent_rejoined');
        });

        test('an attached track is not stopped by an older ParticipantInfo', () async {
          final rec = _Recorder(room);
          container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
          await settle();
          final media = _FakeTrack(id: clientTrack.sid);
          _deliverMedia(container.engine, media);
          await settle(200);
          expect(rec.subscribed, [clientTrack.sid]);

          container.wsConnector.onData(update(agentInfo(4, [sipTrack])));
          await settle(200);

          final pub = agentOf(room)!.getTrackPublicationBySid(clientTrack.sid);
          if (guard) {
            expect(media.stopCalls, 0);
            expect(rec.unsubscribed, isEmpty);
            expect(pub?.track, isNotNull);
          } else {
            expect(media.stopCalls, 1, reason: 'stock: the live media track is stopped');
            expect(rec.unsubscribed, [clientTrack.sid]);
            expect(pub, isNull);
          }
        });

        test('newer and equal versions still reconcile tracks', () async {
          final rec = _Recorder(room);
          container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
          await settle();
          container.wsConnector.onData(update(agentInfo(6, [sipTrack])));
          await settle();
          expect(rec.unpublished, [clientTrack.sid], reason: 'a newer info is authoritative');

          final mutedSip = sipTrack.deepCopy()..muted = true;
          container.wsConnector.onData(update(agentInfo(6, [mutedSip])));
          await settle();
          expect(agentOf(room)!.getTrackPublicationBySid(sipTrack.sid)!.muted, isTrue,
              reason: 'an equal version is not stale');
          expect(observed, isEmpty);
        });

        test('a lower version from a new participant sid is applied', () async {
          final rec = _Recorder(room);
          container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
          await settle();
          final rejoined = lk_models.TrackInfo(sid: 'TR_rejoined', name: 'track-b', type: lk_models.TrackType.AUDIO);
          container.wsConnector.onData(update(agentInfo(1, [rejoined], sid: 'PA_agent_rejoined')));
          await settle();

          final agent = agentOf(room)!;
          expect(agent.sid, 'PA_agent_rejoined');
          expect(agent.trackPublications.keys, ['TR_rejoined']);
          expect(rec.unpublished, unorderedEquals([sipTrack.sid, clientTrack.sid]));
          expect(observed, isEmpty);
        });
      });

      test('media that arrives after an older ParticipantInfo still attaches', () async {
        final container = E2EContainer();
        final room = container.room;
        final connectFuture = room.connect(
          exampleUri,
          token,
          connectOptions: const ConnectOptions(
            timeouts: Timeouts(
              connection: Duration(seconds: 10),
              debounce: Duration(milliseconds: 20),
              publish: Duration(milliseconds: 800),
              subscribe: Duration(seconds: 10),
              peerConnection: Duration(seconds: 10),
              iceRestart: Duration(seconds: 10),
            ),
          ),
        );
        await settle(1);
        container.wsConnector.onData(joinResponse.writeToBuffer());
        container.wsConnector.onData(offerResponse.writeToBuffer());
        await connectFuture;
        final rec = _Recorder(room);

        container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
        await settle();
        container.wsConnector.onData(update(agentInfo(4, [sipTrack])));
        await settle();
        // The SFU still forwards the track: the client never unsubscribed.
        _deliverMedia(container.engine, _FakeTrack(id: clientTrack.sid));
        await settle(1500);

        if (guard) {
          expect(rec.failures, isEmpty);
          expect(rec.subscribed, [clientTrack.sid]);
        } else {
          expect(rec.failures.single, contains('notTrackMetadataFound'), reason: 'stock: the media is dropped');
          expect(rec.subscribed, isEmpty);
        }
        await container.dispose();
      });

      test('media queued while reconnecting attaches when the next update is an older one', () async {
        final ws = MockWebSocketConnector();
        final engine = _HoldableEngine(SignalClient(ws.connect));
        final room = Room(engine: engine);
        final connecting = room.connect(exampleUri, token);
        await settle(1);
        ws.onData(joinResponse.writeToBuffer());
        ws.onData(offerResponse.writeToBuffer());
        await connecting;
        final rec = _Recorder(room);
        ws.onData(update(agentInfo(5, [sipTrack, clientTrack])));
        await settle();

        // Media that arrives while not connected waits in the pending-track queue.
        engine.held = ConnectionState.reconnecting;
        _deliverMedia(engine, _FakeTrack(id: clientTrack.sid));
        await settle();
        engine.held = null;
        expect(rec.subscribed, isEmpty);
        // Stock flushes the queue after every update, including an out-of-date one.
        ws.onData(update(agentInfo(4, [sipTrack, clientTrack])));
        await settle(200);

        expect(observed.single.ignored, guard);
        expect(rec.subscribed, [clientTrack.sid]);
        await room.dispose();
      });

      test('updates parked before the local participant exists cannot remove join-snapshot tracks', () async {
        final container = E2EContainer();
        final room = container.room;
        final rec = _Recorder(room);
        var roomConnected = false;
        room.events.on<RoomConnectedEvent>((_) => roomConnected = true);

        final connectFuture = room.connect(exampleUri, token);
        await settle(1);
        // Room parks these until RoomConnectedEvent (room.dart, `_localParticipant == null`).
        container.wsConnector.onData(update(agentInfo(2, [])));
        container.wsConnector.onData(update(agentInfo(3, [sipTrack])));
        await settle(20);
        expect(room.localParticipant, isNull);
        final join = joinResponse.deepCopy()..join.otherParticipants.add(agentInfo(5, [sipTrack, clientTrack]));
        container.wsConnector.onData(join.writeToBuffer());
        container.wsConnector.onData(offerResponse.writeToBuffer());
        await connectFuture;
        for (var i = 0; i < 200 && !roomConnected; i++) {
          await settle(5);
        }
        await settle(200);

        final agent = agentOf(room)!;
        expect(observed.map((i) => '${i.staleVersion}<${i.appliedVersion}:${i.ignored}'), ['2<5:$guard', '3<5:$guard']);
        if (guard) {
          expect(rec.unpublished, isEmpty);
          expect(agent.trackPublications.keys, unorderedEquals([sipTrack.sid, clientTrack.sid]));
        } else {
          expect(rec.unpublished, contains(clientTrack.sid), reason: 'stock: parked v2/v3 replay after v5');
          expect(agent.getTrackPublicationBySid(clientTrack.sid), isNull);
        }
        await container.dispose();
      });

      // Order seen in production: the JoinResponse lists the agent
      // without tracks, then three newer updates arrive before the local
      // participant exists. All are parked and resume together after
      // RoomConnected; none is older than the applied info when it is checked.
      test('updates parked together after the join snapshot keep every published track', () async {
        final container = E2EContainer();
        final room = container.room;
        final rec = _Recorder(room);
        final live = <String>[];
        room.events.on<TrackPublishedEvent>((e) {
          final current = room.remoteParticipants[agentIdentity]?.getTrackPublicationBySid(e.publication.sid);
          if (identical(current, e.publication)) live.add(e.publication.sid);
        });

        final connectFuture = room.connect(exampleUri, token);
        await settle(1);
        final join = joinResponse.deepCopy()..join.otherParticipants.add(agentInfo(2, []));
        container.wsConnector.onData(join.writeToBuffer());
        container.wsConnector.onData(update(agentInfo(3, [sipTrack])));
        container.wsConnector.onData(update(agentInfo(4, [sipTrack])));
        container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
        container.wsConnector.onData(offerResponse.writeToBuffer());
        await connectFuture;
        await settle(300);

        final agent = agentOf(room)!;
        expect(observed, isEmpty, reason: 'no update is older than the applied one when it is checked');
        if (guard) {
          expect(rec.unpublished, isEmpty);
          expect(agent.trackPublications.keys, unorderedEquals([sipTrack.sid, clientTrack.sid]));
          expect(live, unorderedEquals(rec.published), reason: 'every TrackPublished names a live publication');
        } else {
          expect(rec.unpublished, [clientTrack.sid], reason: 'stock: v3 removes what v5 added');
          expect(agent.getTrackPublicationBySid(clientTrack.sid), isNull);
        }
        await container.dispose();
      });

      test('an observer that throws does not change the outcome', () async {
        RemoteParticipant.staleParticipantInfoObserver = (_, __, ___) => throw StateError('observer');
        final container = E2EContainer();
        await container.connectRoom();
        container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
        await settle();
        container.wsConnector.onData(update(agentInfo(4, [sipTrack])));
        await settle();
        expect(agentOf(container.room)!.getTrackPublicationBySid(clientTrack.sid) != null, guard);
        await container.dispose();
      });
    });
  }

  test('an update stuck past the lock timeout does not block later updates', () async {
    RemoteParticipant.shouldIgnoreStaleParticipantInfo = () => true;
    final container = E2EContainer();
    final room = container.room;
    await container.connectRoom();
    final rec = _Recorder(room);
    container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
    await settle();
    _deliverMedia(container.engine, _FakeTrack(id: clientTrack.sid, stopForever: true));
    await settle(200);
    expect(rec.subscribed, [clientTrack.sid]);

    // v6 removes the attached track; stopping it never completes, so v6 keeps the lock.
    container.wsConnector.onData(update(agentInfo(6, [sipTrack])));
    await settle();
    final extra = lk_models.TrackInfo(sid: 'TR_extra', name: 'extra', type: lk_models.TrackType.AUDIO);
    container.wsConnector.onData(update(agentInfo(7, [sipTrack, extra])));
    await settle(1000);
    expect(agentOf(room)!.getTrackPublicationBySid(extra.sid), isNull, reason: 'v7 waits for v6');
    await settle(5000);
    expect(agentOf(room)!.getTrackPublicationBySid(extra.sid), isNotNull, reason: 'v7 runs after the timeout');
    await container.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a switch that throws keeps the stock behaviour', () async {
    RemoteParticipant.shouldIgnoreStaleParticipantInfo = () => throw StateError('flags');
    final container = E2EContainer();
    await container.connectRoom();
    container.wsConnector.onData(update(agentInfo(5, [sipTrack, clientTrack])));
    await settle();
    container.wsConnector.onData(update(agentInfo(4, [sipTrack])));
    await settle();
    expect(observed.single.ignored, isFalse);
    expect(agentOf(container.room)!.getTrackPublicationBySid(clientTrack.sid), isNull);
    await container.dispose();
  });
}

class _FakeMediaStream extends rtc.MediaStream {
  final List<rtc.MediaStreamTrack> _tracks = [];
  _FakeMediaStream(String id) : super(id, 'fake-owner');
  @override
  bool? get active => true;
  @override
  Future<void> addTrack(rtc.MediaStreamTrack track, {bool addToNative = true}) async => _tracks.add(track);
  @override
  Future<rtc.MediaStream> clone() async => _FakeMediaStream('${id}_clone');
  @override
  List<rtc.MediaStreamTrack> getAudioTracks() => _tracks.where((t) => t.kind == 'audio').toList();
  @override
  Future<void> getMediaTracks() async {}
  @override
  List<rtc.MediaStreamTrack> getTracks() => List<rtc.MediaStreamTrack>.from(_tracks);
  @override
  List<rtc.MediaStreamTrack> getVideoTracks() => _tracks.where((t) => t.kind == 'video').toList();
  @override
  Future<void> removeTrack(rtc.MediaStreamTrack track, {bool removeFromNative = true}) async => _tracks.remove(track);
}

class _FakeTrack implements rtc.MediaStreamTrack {
  final bool stopForever;
  int stopCalls = 0;
  @override
  rtc.StreamTrackCallback? onEnded;
  @override
  rtc.StreamTrackCallback? onMute;
  @override
  rtc.StreamTrackCallback? onUnMute;
  @override
  bool enabled = true;
  @override
  final String id;
  @override
  String get kind => 'audio';
  @override
  String? get label => 'audio-track';
  @override
  bool? get muted => false;
  _FakeTrack({required this.id, this.stopForever = false});
  @override
  Future<void> applyConstraints([Map<String, dynamic>? constraints]) async {}
  @override
  Future<rtc.MediaStreamTrack> clone() async => _FakeTrack(id: id);
  @override
  Future<void> dispose() async {}
  @override
  Future<void> adaptRes(int width, int height) async {}
  @override
  Map<String, dynamic> getConstraints() => const {};
  @override
  Map<String, dynamic> getSettings() => const {};
  @override
  Future<void> stop() {
    stopCalls++;
    return stopForever ? Completer<void>().future : Future<void>.value();
  }

  @override
  void enableSpeakerphone(bool enable) {}
  @override
  Future<ByteBuffer> captureFrame() => throw UnimplementedError();
  @override
  Future<bool> hasTorch() async => false;
  @override
  Future<void> setTorch(bool torch) async {}
  @override
  Future<bool> switchCamera() async => false;
}
