# Modified by Shaling AI in 2026: WebRTC-SDK 144.7559.10 (see SHALING_PATCHES.md).
# Not part of upstream livekit/client-sdk-flutter.
Pod::Spec.new do |s|
  s.name                = 'livekit_client'
  s.version             = '2.9.0'
  s.summary             = 'Open source platform for real-time audio and video.'
  s.description         = 'Open source platform for real-time audio and video.'
  s.homepage            = 'https://livekit.io/'
  s.license             = { :file => '../LICENSE' }
  s.author              = { 'LiveKit' => 'contact@livekit.io' }
  s.source              = { :path => '.' }
  s.source_files        = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.platform            = :ios, '13.0'
  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version       = '5.0'
  s.static_framework    = true

  s.dependency 'Flutter'
  # Shaling AI fork patch P3: 144.7559.10 fixes the AudioEngineDevice null
  # FineAudioBuffer crash of .09. flutter_webrtc must pin the same version
  # (shaling-ai/flutter-webrtc patch W1; see SHALING_PATCHES.md P3).
  s.dependency 'WebRTC-SDK', '144.7559.10'
  s.dependency 'flutter_webrtc'
end
