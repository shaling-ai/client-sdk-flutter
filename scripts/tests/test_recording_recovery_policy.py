#!/usr/bin/env python3
# Copyright 2026 LiveKit
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Compile the actual iOS observer/bridge with platform boundary stubs on macOS."""

import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
STUBS = r'''
import Foundation
struct AVAudioSession {
    struct Category { let rawValue: String
        static let playAndRecord = Category(rawValue: "playAndRecord")
        static let playback = Category(rawValue: "playback")
    }
    struct Mode { let rawValue: String
        static let spokenAudio = Mode(rawValue: "spokenAudio")
    }
    struct CategoryOptions: OptionSet {
        let rawValue: UInt
        static let mixWithOthers = CategoryOptions(rawValue: 1)
        static let allowBluetooth = CategoryOptions(rawValue: 2)
    }
}
class RTCAudioSessionConfiguration {
    var category = "playAndRecord"
    var categoryOptions: AVAudioSession.CategoryOptions = [.allowBluetooth]
    var mode = "voiceChat"
    var sampleRate = 48000.0
    var ioBufferDuration = 0.02
    var inputNumberOfChannels = 1
    var outputNumberOfChannels = 1
}
class FlutterMethodChannel { func invokeMethod(_ method: String, arguments: Any?) {} }
class RTCAudioDeviceModule {}
protocol RTCAudioDeviceModuleDelegate {}
class AVAudioEngine {}
class AVAudioNode {}
class AVAudioFormat {}
struct RTCSpeechActivityEvent {}
class FlutterWebRTCPlugin {
    static func sharedSingleton() -> FlutterWebRTCPlugin? { nil }
    func audioDeviceModuleDidUpdateDevices(_ module: RTCAudioDeviceModule) {}
}
'''

CHECKS = r'''
let observer = LKAudioEngineObserver(channel: FlutterMethodChannel())
let module = RTCAudioDeviceModule()
let engine = AVAudioEngine()
func policy(_ mode: String = "voiceChat", speaker: Bool = false) {
    let config = RTCAudioSessionConfiguration()
    config.mode = mode
    observer.updatePolicy(config, automaticManagementEnabled: true,
                          selectCategoryByEngineState: true, forceSpeakerOutput: speaker)
}
func enable() {
    precondition(observer.audioDeviceModule(module, willEnableEngine: engine,
        isPlayoutEnabled: true, isRecordingEnabled: true) == 0)
}
func disableInput() {
    precondition(observer.audioDeviceModule(module, didDisableEngine: engine,
        isPlayoutEnabled: true, isRecordingEnabled: false) == 0)
}
func expectRejected(_ expected: LiveKitPlugin.RecordingRecoveryPolicyError,
                    _ operation: () throws -> Void) {
    do { try operation(); fatalError("scope should have been rejected") }
    catch let error as LiveKitPlugin.RecordingRecoveryPolicyError { precondition(error == expected) }
    catch { fatalError("unexpected error: \(error)") }
}
expectRejected(.observerUnavailable) {
    try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("missing observer entered") }
}
LiveKitPlugin.registerRecordingRecoveryObserver(observer)
expectRejected(.recordingPolicyUnavailable) {
    try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("missing policy entered") }
}
policy(); enable(); disableInput()
precondition(LiveKitPlugin.applied.last?.category == "playback")
precondition(LiveKitPlugin.applied.last?.mode == "spokenAudio")
enable()
let returned: Int = try LiveKitPlugin.withRecordingRecoveryPolicy {
    expectRejected(.recoveryInProgress) {
        try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("nested scope entered") }
    }
    let rejected = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        expectRejected(.recoveryInProgress) {
            try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("concurrent scope entered") }
        }
        rejected.signal()
    }
    precondition(rejected.wait(timeout: .now() + 3) == .success)
    // Real callback takes the same observer lock. This would hang if the scope held it.
    disableInput()
    precondition(LiveKitPlugin.applied.last?.category == "playAndRecord")
    precondition(LiveKitPlugin.applied.last?.mode == "voiceChat")
    precondition(LiveKitPlugin.applied.last?.categoryOptions == [.allowBluetooth])
    // Route/policy changes during a scope must survive its exit.
    policy("videoChat", speaker: true)
    precondition(observer.applyCachedConfiguration() == nil)
    precondition(LiveKitPlugin.applied.last?.mode == "videoChat")
    precondition(LiveKitPlugin.forcedSpeaker.last == true)
    enable()
    return 42
}
precondition(returned == 42)
disableInput()
precondition(LiveKitPlugin.applied.last?.category == "playback")
enable()
precondition(LiveKitPlugin.applied.last?.mode == "videoChat")
precondition(LiveKitPlugin.forcedSpeaker.last == true)
enum TestFailure: Error { case stopOrStartFailed }
do {
    try LiveKitPlugin.withRecordingRecoveryPolicy { throw TestFailure.stopOrStartFailed }
    fatalError("thrown error swallowed")
} catch TestFailure.stopOrStartFailed {}
disableInput()
precondition(LiveKitPlugin.applied.last?.category == "playback")
// A returned stop/start failure must also release ownership.
enable()
let failed: Bool = try LiveKitPlugin.withRecordingRecoveryPolicy { false }
precondition(!failed)
try LiveKitPlugin.withRecordingRecoveryPolicy { () }
// Scope rejects playout-only, manual-management and non-recording policies.
disableInput()
expectRejected(.recordingPolicyUnavailable) {
    try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("playout-only entered") }
}
enable()
observer.setAutomaticManagementEnabled(false)
expectRejected(.recordingPolicyUnavailable) {
    try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("manual management entered") }
}
let playback = RTCAudioSessionConfiguration(); playback.category = "playback"
observer.updatePolicy(playback, automaticManagementEnabled: true,
    selectCategoryByEngineState: false, forceSpeakerOutput: false)
expectRejected(.recordingPolicyUnavailable) {
    try LiveKitPlugin.withRecordingRecoveryPolicy { fatalError("playback policy entered") }
}
print("PASS: actual observer and public bridge recovery-policy scope")
'''


class RecordingRecoveryPolicyTest(unittest.TestCase):
    def test_actual_observer_and_bridge(self):
        source = (ROOT / "shared_swift/LiveKitPlugin.swift").read_text()
        begin = source.find("// BEGIN RecordingRecoveryPolicyBridge")
        end = source.find("// END RecordingRecoveryPolicyBridge", begin)
        bridge = source[begin:end] if begin >= 0 and end > begin else ""
        bridge = bridge.replace("#if os(iOS)", "#if true")
        # The test registers the actual observer without Flutter's registrar.
        bridge = bridge.replace("private static func registerRecordingRecoveryObserver",
                                "static func registerRecordingRecoveryObserver")
        observer = source[source.index("@available(iOS 13.0, macOS 10.15, *)\nclass LKAudioEngineObserver"):]
        observer = observer.replace("#if !os(macOS)", "#if true")
        plugin = '''
class LiveKitPlugin {
    static let kAudioEngineErrorFailedToConfigureAudioSession = -4100
    static var applied: [RTCAudioSessionConfiguration] = []
    static var forcedSpeaker: [Bool] = []
    static func applyAudioSessionConfiguration(_ config: RTCAudioSessionConfiguration,
        forceSpeakerOutput: Bool, isActive: Bool) -> Error? {
        applied.append(config); forcedSpeaker.append(forceSpeakerOutput); return nil
    }
    static func deactivateAudioSession() -> Error? { nil }
'''+bridge+"\n}\n"
        with tempfile.TemporaryDirectory(prefix="livekit-recovery-policy-") as directory:
            main = pathlib.Path(directory) / "main.swift"
            executable = pathlib.Path(directory) / "policy-test"
            main.write_text(STUBS+plugin+observer+CHECKS)
            compiled = subprocess.run(["xcrun", "swiftc", str(main), "-o", str(executable)],
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout+compiled.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn("PASS: actual observer", result.stdout)


if __name__ == "__main__":
    unittest.main()
