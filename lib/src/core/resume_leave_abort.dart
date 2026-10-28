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

import 'engine.dart';

/// Shaling AI fork patch P2: opt in per engine to aborting a resume explicitly
/// rejected with STATE_MISMATCH before its ReconnectResponse is accepted.
/// Other leave reasons, old sockets, and accepted resumes retain stock behavior.
class ResumeLeaveAbort {
  /// Read once per attempt. Unset, false, or a thrown exception means stock.
  static bool Function(Engine engine)? shouldAbortResumeOnReconnectLeave;
}
