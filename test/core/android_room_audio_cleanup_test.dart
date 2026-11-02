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

import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/support/native.dart';

import '../mock/e2e_container.dart';

// These lifecycle regressions intentionally exercise Room's real Android path.
// Run on an Android Flutter test target; desktop helper tests live in audio/.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android Room native release', () {
    late E2EContainer container;
    var rejectStop = false;
    var stops = 0;
    Completer<void>? stopGate;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() async {
      AudioManager.instance.resetForTest();
      rejectStop = false;
      stops = 0;
      stopGate = null;
      messenger.setMockMethodCallHandler(Native.channel, (call) async {
        if (call.method == 'stopAndroidAudioSession') {
          stops++;
          if (rejectStop) throw PlatformException(code: 'audio_session_failed');
          await stopGate?.future;
        }
        return null;
      });
      container = E2EContainer();
      await container.connectRoom();
    });

    tearDown(() async {
      rejectStop = false;
      final gate = stopGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      await container.dispose();
      messenger.setMockMethodCallHandler(Native.channel, null);
    });

    test('native failure preserves terminal delivery and closed-engine retry', () async {
      rejectStop = true;
      final terminal = container.room.events.waitFor<RoomDisconnectedEvent>(
        duration: const Duration(seconds: 3),
      );
      // A disconnected signaling transport takes Engine's terminal branch.
      await container.engine.cleanUp();
      await container.engine.disconnect();
      await terminal;
      expect(container.engine.isClosed, isTrue);
      expect(stops, 1);

      await expectLater(container.room.disconnect(), throwsA(isA<PlatformException>()));
      expect(stops, 2);
      rejectStop = false;
      await container.room.disconnect();
      expect(stops, 3);
      await container.room.disconnect();
      expect(stops, 3); // duplicate cleanup cannot release a successor owner.
    });

    test('failed dispose is observable and leaves the Room retryable', () async {
      rejectStop = true;
      await expectLater(container.room.dispose(), throwsA(isA<PlatformException>()));
      expect(container.room.isDisposed, isFalse);
      expect(stops, 1);
      rejectStop = false;
      await container.room.dispose();
      expect(container.room.isDisposed, isTrue);
      expect(stops, 2);
      await container.room.dispose();
      expect(stops, 2);
    });

    test('slow native stop bounds terminal delivery while true cleanup stays pending', () async {
      stopGate = Completer<void>();
      final terminal = container.room.events.waitFor<RoomDisconnectedEvent>(
        duration: const Duration(seconds: 3),
      );
      // A disconnected signaling transport takes Engine's terminal branch.
      await container.engine.cleanUp();
      await container.engine.disconnect();
      await terminal;
      expect(stopGate!.isCompleted, isFalse);
      expect(stops, 1);

      var disposed = false;
      final disposal = container.room.dispose().then((_) => disposed = true);
      await Future<void>.delayed(Duration.zero);
      expect(disposed, isFalse);
      expect(container.room.isDisposed, isFalse);
      stopGate!.complete();
      await disposal;
      expect(container.room.isDisposed, isTrue);
      expect(stops, 1);
    });
  }, skip: !lkPlatformIs(PlatformType.android));
}
