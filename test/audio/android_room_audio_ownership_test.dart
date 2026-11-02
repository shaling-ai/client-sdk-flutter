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

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:livekit_client/src/support/native.dart';
import 'package:livekit_client/src/track/audio_management.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('replacement failure and duplicate cleanup leave the primary Room active', () async {
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => true,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final primary = Object(), candidate = Object();
    await owners.acquire(primary);
    await owners.acquire(candidate);
    await owners.release(candidate); // Engine connect failure after audio acquire.
    await owners.release(candidate); // Its later dispose is idempotent.
    expect(events, ['start']);
    await owners.release(primary);
    await owners.release(primary);
    expect(events, ['start', 'stop']);
  });

  test('closing old primary cannot stop a promoted or consultation Room', () async {
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => true,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final old = Object(), replacement = Object(), consultation = Object();
    await owners.acquire(old);
    await owners.acquire(replacement);
    await owners.acquire(consultation);
    await owners.release(old);
    await owners.release(replacement);
    expect(events, ['start']);
    await owners.release(consultation);
    expect(events, ['start', 'stop']);
  });

  test('actual pending stop blocks the next start and coalesces duplicate release', () async {
    final stopped = Completer<void>();
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => true,
      start: () async {
        events.add('start');
      },
      stop: () {
        events.add('stop');
        return stopped.future;
      },
    );
    final first = Object(), next = Object();
    await owners.acquire(first);
    final release = owners.release(first);
    final repeated = owners.release(first);
    var acquired = false;
    final acquire = owners.acquire(next).then((_) => acquired = true);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['start', 'stop']);
    expect(acquired, isFalse);
    stopped.complete();
    await Future.wait([release, repeated, acquire]);
    expect(events, ['start', 'stop', 'start']);
    await owners.release(next);
  });

  test('a failed stop remains a barrier and a subsequent acquire retries it first', () async {
    final events = <String>[];
    var reject = true;
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => true,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
        if (reject) throw StateError('native queue failure');
      },
    );
    final first = Object(), next = Object();
    await owners.acquire(first);
    await expectLater(owners.release(first), throwsStateError);
    await expectLater(owners.acquire(next), throwsStateError);
    expect(events, ['start', 'stop', 'stop']);
    reject = false;
    await owners.acquire(next);
    expect(events, ['start', 'stop', 'stop', 'stop', 'start']);
    await owners.release(first); // Stale old owner cannot remove the new one.
    expect(events.last, 'start');
    await owners.release(next);
  });

  test('partial startup retains cleanup even alongside a prior manual Room', () async {
    var automatic = false;
    var failStart = true;
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => automatic,
      start: () async {
        events.add('start');
        if (failStart) throw StateError('partial activation');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final manual = Object(), failed = Object(), successor = Object();
    await owners.acquire(manual);
    automatic = true;
    await expectLater(owners.acquire(failed), throwsStateError);
    await owners.release(failed);
    expect(events, ['start', 'stop']);
    failStart = false;
    await owners.acquire(successor);
    expect(events, ['start', 'stop', 'start']);
    await owners.release(manual);
    expect(events.last, 'start');
    await owners.release(successor);
  });

  test('manual host takeover does not stop or reactivate the host session', () async {
    var automatic = true;
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => automatic,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final a = Object(), b = Object();
    await owners.acquire(a);
    automatic = false;
    await owners.acquire(b);
    await owners.release(a);
    await owners.release(b);
    expect(events, ['start']);
  });

  test('automatic handback releases the last existing manual Room without another acquire', () async {
    var automatic = false;
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => automatic,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final room = Object();
    await owners.acquire(room);
    automatic = true; // AudioManager reapplies the native policy on handback.
    await owners.release(room);
    expect(events, ['stop']);
  });

  test('automatic manual automatic handback retains overlapping Room references', () async {
    var automatic = true;
    final events = <String>[];
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => automatic,
      start: () async {
        events.add('start');
      },
      stop: () async {
        events.add('stop');
      },
    );
    final a = Object(), b = Object();
    await owners.acquire(a);
    automatic = false;
    await owners.acquire(b);
    automatic = true;
    await owners.release(a);
    expect(events, ['start']);
    await owners.release(b);
    expect(events, ['start', 'stop']);
  });

  test('owner identity is exact even for equal-valued tokens', () async {
    var stops = 0;
    final owners = AndroidRoomAudioOwners(
      isAutomatic: () => true,
      start: () async {},
      stop: () async {
        stops++;
      },
    );
    final a = _EqualToken(), b = _EqualToken();
    await owners.acquire(a);
    await owners.acquire(b);
    await owners.release(a);
    expect(stops, 0);
    await owners.release(b);
    expect(stops, 1);
  });

  test('strict native lifecycle propagates errors; legacy callers keep compatibility', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(Native.channel, (_) async {
      throw PlatformException(code: 'audio_session_failed');
    });
    try {
      await expectLater(Native.configureAndroidAudioSession({}, strict: true), throwsA(isA<PlatformException>()));
      await expectLater(Native.stopAndroidAudioSession(strict: true), throwsA(isA<PlatformException>()));
      await Native.configureAndroidAudioSession({});
      await Native.stopAndroidAudioSession();
    } finally {
      messenger.setMockMethodCallHandler(Native.channel, null);
    }
  });
}

final class _EqualToken {
  @override
  bool operator ==(Object other) => other is _EqualToken;
  @override
  int get hashCode => 1;
}
