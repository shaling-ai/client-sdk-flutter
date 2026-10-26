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

/// A resume that the server rejects with a full-reconnect leave (patch P2, see
/// SHALING_PATCHES.md).
///
/// When a resume reaches a server that has already closed the participant, the
/// server answers `Leave{action: RECONNECT}` (`canReconnect: true` before
/// protocol 13). Stock 2.9.0 then sets `fullReconnectOnNext`, but the resume
/// attempt already in flight keeps waiting for a ReconnectResponse until
/// `Timeouts.connection` expires; only the retry after that runs the full
/// reconnect.
///
/// The `stock` group pins that behaviour and the other per-phase outcomes of a
/// resume, so a switchable patch can prove it leaves them unchanged. The `P2`
/// group states the intended behaviour and fails until the patch lands.
///
/// Real timers with short timeouts keep the suite fast; the stock wait scales
/// with `Timeouts.connection`, which an app may set to 15 s or more.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/core/engine.dart';
import 'package:livekit_client/src/core/signal_client.dart';
import 'package:livekit_client/src/internal/events.dart';
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import 'package:livekit_client/src/support/websocket.dart';
import '../mock/peerconnection_mock.dart';
import '../mock/websocket_mock.dart';
import 'signal_client_test.dart';

const _connectionTimeout = Duration(milliseconds: 1500);
const _peerConnectionTimeout = Duration(milliseconds: 1000);
// defaultRetryDelaysInMs[1]: the delay before the retry after a failed attempt.
const _retryDelay = Duration(milliseconds: 300);
const _slack = Duration(milliseconds: 400);

final _reconnectLeave = lk_rtc.SignalResponse(
  leave: lk_rtc.LeaveRequest(
    action: lk_rtc.LeaveRequest_Action.RECONNECT,
    reason: lk_models.DisconnectReason.STATE_MISMATCH,
  ),
);

// What a server that predates protocol 13 sends instead.
final _legacyReconnectLeave = lk_rtc.SignalResponse(
  leave: lk_rtc.LeaveRequest(
    canReconnect: true,
    reason: lk_models.DisconnectReason.STATE_MISMATCH,
  ),
);

final _resumeLeave = lk_rtc.SignalResponse(
  leave: lk_rtc.LeaveRequest(
    action: lk_rtc.LeaveRequest_Action.RESUME,
    reason: lk_models.DisconnectReason.MIGRATION,
  ),
);

final _reconnectResponse = lk_rtc.SignalResponse(reconnect: lk_rtc.ReconnectResponse());

final _options = ConnectOptions(
  timeouts: Timeouts(
    connection: _connectionTimeout,
    debounce: Timeouts.defaultTimeouts.debounce,
    publish: Timeouts.defaultTimeouts.publish,
    subscribe: Timeouts.defaultTimeouts.subscribe,
    peerConnection: _peerConnectionTimeout,
    iceRestart: Timeouts.defaultTimeouts.iceRestart,
  ),
);

/// [MockPeerConnection] throws from `setConfiguration`, which the engine calls
/// for every ReconnectResponse; a resume could never succeed on it.
class _ResumablePeerConnection extends MockPeerConnection {
  static Future<rtc.RTCPeerConnection> create(Map<String, dynamic> configuration,
          [Map<String, dynamic>? constraints]) async =>
      _ResumablePeerConnection();

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {}
}

/// A connected room on mocks that records the engine's reconnect milestones
/// with their time since the harness started.
class _Harness {
  final ws = MockWebSocketConnector();
  late final SignalClient client = SignalClient(_connect);
  late final Engine engine = Engine(
    connectOptions: _options,
    roomOptions: const RoomOptions(),
    signalClient: client,
    peerConnectionCreate: _ResumablePeerConnection.create,
  );
  late final Room room = Room(engine: engine);

  final _clock = Stopwatch()..start();
  final _marks = <(Duration, String)>[];
  final _listeners = <EventsListener<dynamic>>[];

  int connectCalls = 0;

  /// When set, the next signal connect never completes, like a WebSocket
  /// connect that hangs until `Timeouts.connection`.
  bool hangNextConnect = false;

  Duration get now => _clock.elapsed;

  Future<LiveKitWebSocket> _connect(
    Uri uri, {
    WebSocketEventHandlers? options,
    Map<String, String>? headers,
    NetworkOptions? networkOptions,
  }) {
    connectCalls++;
    if (hangNextConnect) {
      hangNextConnect = false;
      return Completer<LiveKitWebSocket>().future;
    }
    return ws.connect(uri, options: options, headers: headers, networkOptions: networkOptions);
  }

  Future<void> connect() async {
    final connecting = room.connect(exampleUri, token, connectOptions: _options);
    unawaited(Future.delayed(const Duration(milliseconds: 1), () {
      deliver(joinResponse);
      deliver(offerResponse);
    }));
    await connecting;

    final engineListener = engine.createListener();
    engineListener
      ..on<EngineResumingEvent>((_) => _mark('resuming'))
      ..on<EngineResumedEvent>((_) => _mark('resumed'))
      ..on<EngineFullRestartingEvent>((_) => _mark('full_restarting'))
      ..on<EngineRestartedEvent>((_) => _mark('restarted'));
    final signalListener = client.createListener();
    signalListener
      ..on<SignalReconnectingEvent>((_) => _mark('signal_reconnecting'))
      ..on<SignalConnectedEvent>((_) => _mark('signal_open'));
    _listeners.addAll([engineListener, signalListener]);
  }

  void _mark(String name) => _marks.add((now, name));

  int count(String name) => _marks.where((m) => m.$2 == name).length;

  /// The time of the [occurrence]-th [name] milestone, waiting up to [within].
  Future<Duration> when(String name, {int occurrence = 1, required Duration within}) async {
    final deadline = now + within;
    while (true) {
      final hits = _marks.where((m) => m.$2 == name).toList();
      if (hits.length >= occurrence) return hits[occurrence - 1].$1;
      if (now > deadline) {
        throw TimeoutException('no "$name" #$occurrence within $within; seen: ${_marks.map((m) => m.$2)}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Like [when], but returns null instead of throwing.
  Future<Duration?> whenOrNull(String name, {int occurrence = 1, required Duration within}) async {
    try {
      return await when(name, occurrence: occurrence, within: within);
    } on TimeoutException {
      return null;
    }
  }

  void deliver(lk_rtc.SignalResponse response) => ws.onData(response.writeToBuffer());

  /// Closes the current signal socket, as an unexpected network drop does.
  void dropSignal() => ws.onDispose();

  void setPrimaryPeerConnectionState(rtc.RTCPeerConnectionState state) =>
      (engine.subscriber!.pc as MockPeerConnection).connectionState = state;

  /// Lets a full reconnect that has started join again.
  Future<void> completeFullRestart() async {
    unawaited(Future.delayed(const Duration(milliseconds: 1), () {
      deliver(joinResponse);
      deliver(offerResponse);
    }));
    await when('restarted', within: const Duration(seconds: 5));
  }

  Future<void> dispose() async {
    for (final listener in _listeners) {
      await listener.cancelAll();
    }
    await room.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Harness h;

  setUp(() async {
    h = _Harness();
    await h.connect();
  });

  tearDown(() async {
    await h.dispose();
  });

  /// Drops the signal, waits until the resume's WebSocket is open, waits
  /// [settle] and delivers [leave]. Returns the time the socket opened.
  Future<Duration> leaveDuringResume(lk_rtc.SignalResponse leave,
      {Duration settle = const Duration(milliseconds: 50)}) async {
    h.dropSignal();
    await h.when('resuming', within: const Duration(seconds: 2));
    final opened = await h.when('signal_open', within: const Duration(seconds: 2));
    await Future<void>.delayed(settle);
    h.deliver(leave);
    return opened;
  }

  group('stock 2.9.0', () {
    for (final (name, leave) in [
      ('Leave{action: RECONNECT}', _reconnectLeave),
      ('legacy Leave{canReconnect: true}', _legacyReconnectLeave),
    ]) {
      test('$name during a resume: the full reconnect waits for Timeouts.connection', () async {
        final opened = await leaveDuringResume(leave);

        final restart = await h.when('full_restarting', within: _connectionTimeout + _retryDelay + _slack * 2);
        final waited = restart - opened;
        expect(waited, greaterThanOrEqualTo(_connectionTimeout - const Duration(milliseconds: 50)),
            reason: 'the resume keeps waiting for a ReconnectResponse after the leave');
        expect(waited, lessThan(_connectionTimeout + _retryDelay + _slack));
        expect(h.count('resuming'), 1, reason: 'the retry after the wait is the full reconnect, not a resume');

        await h.completeFullRestart();
      });
    }

    test('a WebSocket connect that times out: the next attempt is a resume again', () async {
      h.hangNextConnect = true;
      h.dropSignal();
      final first = await h.when('resuming', within: const Duration(seconds: 2));

      final second = await h.when('resuming', occurrence: 2, within: _connectionTimeout + _retryDelay + _slack * 2);
      expect(second - first, greaterThanOrEqualTo(_connectionTimeout));
      expect(second - first, lessThan(_connectionTimeout + _retryDelay + _slack));
      expect(h.count('full_restarting'), 0, reason: 'a TimeoutException does not escalate');

      await h.when('signal_open', within: const Duration(seconds: 2));
      h.deliver(_reconnectResponse);
      await h.when('resumed', within: const Duration(seconds: 2));
    });

    test('no ReconnectResponse: the resume is retried after Timeouts.connection', () async {
      h.dropSignal();
      final opened = await h.when('signal_open', within: const Duration(seconds: 2));

      final second = await h.when('resuming', occurrence: 2, within: _connectionTimeout + _retryDelay + _slack * 2);
      expect(second - opened, greaterThanOrEqualTo(_connectionTimeout - const Duration(milliseconds: 50)));
      expect(h.count('full_restarting'), 0, reason: 'a ConnectException does not escalate');

      await h.when('signal_open', occurrence: 2, within: const Duration(seconds: 2));
      h.deliver(_reconnectResponse);
      await h.when('resumed', within: const Duration(seconds: 2));
    });

    test('a ReconnectResponse: the resume succeeds without a full reconnect', () async {
      h.dropSignal();
      await h.when('signal_open', within: const Duration(seconds: 2));
      h.deliver(_reconnectResponse);

      await h.when('resumed', within: const Duration(seconds: 2));
      expect(h.count('full_restarting'), 0);
    });

    test(
        'a primary PeerConnection that goes disconnected while the signal is connected: '
        'the SDK resumes, which closes the open signal socket, and escalates after the PC wait', () async {
      expect(h.connectCalls, 1);

      h.setPrimaryPeerConnectionState(rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);

      await h.when('resuming', within: const Duration(seconds: 2));
      await h.when('signal_reconnecting', within: const Duration(seconds: 2));
      final opened = await h.when('signal_open', within: const Duration(seconds: 2));
      expect(h.connectCalls, 2, reason: 'the healthy socket was replaced by a resume socket');

      h.deliver(_reconnectResponse);
      final restart = await h.when('full_restarting', within: _peerConnectionTimeout + _retryDelay + _slack * 2);
      expect(restart - opened, greaterThanOrEqualTo(_peerConnectionTimeout - const Duration(milliseconds: 50)),
          reason: 'the resume waits Timeouts.peerConnection for the primary PC, then escalates');

      await h.completeFullRestart();
    });

    test('Leave{action: RESUME} during a resume: no escalation; the resume is retried', () async {
      final opened = await leaveDuringResume(_resumeLeave);

      final second = await h.when('resuming', occurrence: 2, within: _connectionTimeout + _retryDelay + _slack * 2);
      expect(second - opened, greaterThanOrEqualTo(_connectionTimeout - const Duration(milliseconds: 50)));
      expect(h.count('full_restarting'), 0);

      await h.when('signal_open', occurrence: 2, within: const Duration(seconds: 2));
      h.deliver(_reconnectResponse);
      await h.when('resumed', within: const Duration(seconds: 2));
    });
  });

  group('P2 (fails until the patch lands)', () {
    test('Leave{action: RECONNECT} during a resume starts the full reconnect within the retry delay', () async {
      await leaveDuringResume(_reconnectLeave);
      final leaveAt = h.now;

      final restart = await h.whenOrNull('full_restarting', within: _retryDelay + const Duration(milliseconds: 150));
      expect(restart, isNotNull,
          reason: 'stock 2.9.0 keeps waiting about Timeouts.connection '
              '(${_connectionTimeout.inMilliseconds} ms here) before the full reconnect');
      expect(restart! - leaveAt, lessThan(_retryDelay + const Duration(milliseconds: 150)));

      await h.completeFullRestart();
    });
  });
}
