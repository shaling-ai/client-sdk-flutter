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

import 'package:meta/meta.dart';

import '../audio/android_audio_session_adapter.dart';
import '../audio/audio_manager.dart';
import '../audio/audio_session.dart';
import '../audio/audio_session_policy.dart';
import '../support/native.dart';
import '../support/platform.dart';
import 'local/local.dart';
import 'remote/remote.dart';

@Deprecated('Audio session lifecycle is managed by AudioManager instead')
mixin LocalAudioManagementMixin on LocalTrack, AudioTrack {}

@Deprecated('Audio session lifecycle is managed by AudioManager instead')
mixin RemoteAudioManagementMixin on RemoteTrack, AudioTrack {}

/// Internal process lease for Android Room audio. An owner is one stable Room
/// token; repeated cleanup and a failed replacement cannot release another Room.
@internal
final class AndroidRoomAudioOwners {
  AndroidRoomAudioOwners({required this.isAutomatic, required this.start, required this.stop});

  final bool Function() isAutomatic;
  final Future<void> Function() start;
  final Future<void> Function() stop;
  final Set<Object> _owners = Set<Object>.identity();
  Future<void> _tail = Future<void>.value();
  Object? _pendingRelease;
  bool _ownsSession = false;

  Future<void> _serialize(Future<void> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> acquire(Object owner) => _serialize(() async {
    // Failed stop is still an owned native session. A new Room cannot
    // bypass it just because the prior release Future completed in error.
    final pending = _pendingRelease;
    if (pending != null) await _release(pending);
    if (_owners.contains(owner)) return;
    _owners.add(owner);
    if (!isAutomatic()) {
      // Manual is an explicit host takeover. Never stop its session later.
      _ownsSession = false;
      return;
    }
    if (_ownsSession) return;
    // Configuration can fail after native creation/activation. Record the
    // owner first so Room's failure cleanup can retry that exact resource.
    _ownsSession = true;
    try {
      await start();
      if (!isAutomatic()) _ownsSession = false;
    } catch (_) {
      _pendingRelease = owner;
      rethrow;
    }
  });

  Future<void> release(Object owner) => _serialize(() => _release(owner));

  Future<void> _release(Object owner) async {
    if (!_owners.contains(owner)) return;
    final automatic = isAutomatic();
    if (!automatic) _ownsSession = false;
    // Returning to automatic reapplies AudioManager's native policy even when
    // no new Room connects. The last Room then owns release again; the cached
    // _ownsSession bit is only useful for avoiding duplicate acquire/start.
    if ((_owners.length > 1 && !identical(_pendingRelease, owner)) || !automatic) {
      _owners.remove(owner);
      if (identical(_pendingRelease, owner)) _pendingRelease = null;
      return;
    }
    _pendingRelease = owner;
    await stop();
    // Clear only after the actual AudioSwitch thread confirms release. On
    // error the same owner and pending release survive for an exact retry.
    _owners.remove(owner);
    _ownsSession = false;
    _pendingRelease = null;
  }
}

class NativeAudioManagement {
  static final _unscopedOwner = Object();
  static final _androidOwners = AndroidRoomAudioOwners(
    isAutomatic: () => AudioManager.instance.managementMode != AudioSessionManagementMode.manual,
    start: () async {
      final manager = AudioManager.instance;
      final policy = ResolvedAudioSessionPolicy(
        options: manager.options,
        preferSpeakerOutput: manager.isSpeakerOutputPreferred,
        forceSpeakerOutput: manager.isSpeakerOutputForced,
        automatic: true,
      );
      // One native operation configures, starts and routes on the AudioSwitch
      // thread. A successful MethodChannel receipt means those actions ran.
      await Native.configureAndroidAudioSession({
        ...androidAudioSessionConfigurationToMap(policy.androidConfiguration),
        'speakerOutputPreferred': policy.preferSpeakerOutput,
        'speakerOutputForced': policy.forceSpeakerOutput,
      }, strict: true);
    },
    stop: () => Native.stopAndroidAudioSession(strict: true),
  );

  static Future<void> start({Object? owner}) async {
    if (lkPlatformIs(PlatformType.android)) {
      await _androidOwners.acquire(owner ?? _unscopedOwner);
      return;
    }
    // Preserve Apple/web behavior and the host's existing management mode.
    await AudioManager.instance.applyOptionsForConnect();
  }

  static Future<void> stop({Object? owner}) async {
    if (lkPlatformIs(PlatformType.android)) {
      await _androidOwners.release(owner ?? _unscopedOwner);
    }
  }
}
