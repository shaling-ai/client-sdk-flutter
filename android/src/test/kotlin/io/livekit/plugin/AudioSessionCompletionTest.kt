/*
 * Copyright 2026 LiveKit, Inc.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.livekit.plugin

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertSame

class AudioSessionCompletionTest {
  @Test fun `receipt waits for queued native work`() {
    val queued = mutableListOf<Runnable>()
    val events = mutableListOf<String>()
    dispatchAudioSessionOperation({ queued.add(it); true }, { events.add("receipt") }) {
      events.add("native-stop")
    }
    assertEquals(emptyList(), events)
    queued.single().run()
    assertEquals(listOf("native-stop", "receipt"), events)
  }

  @Test fun `native failure is returned instead of acknowledged as success`() {
    val queued = mutableListOf<Runnable>()
    val expected = IllegalStateException("native-stop")
    var failure: Throwable? = null
    dispatchAudioSessionOperation({ queued.add(it); true }, { failure = it }) { throw expected }
    queued.single().run()
    assertSame(expected, failure)
  }

  @Test fun `closed native queue returns an error without running work`() {
    var ran = false
    var failure: Throwable? = null
    dispatchAudioSessionOperation({ false }, { failure = it }) { ran = true }
    assertFalse(ran)
    assertIs<IllegalStateException>(failure)
  }

  @Test fun `enqueue failure is returned to the strict caller`() {
    val expected = IllegalStateException("enqueue")
    var failure: Throwable? = null
    dispatchAudioSessionOperation({ throw expected }, { failure = it }) {
      error("rejected work must not run")
    }
    assertSame(expected, failure)
  }

  @Test fun `stop receipt precedes a subsequently queued start`() {
    val queued = mutableListOf<Runnable>()
    val events = mutableListOf<String>()
    dispatchAudioSessionOperation({ queued.add(it); true }, { events.add("stop-receipt") }) {
      events.add("stop")
    }
    dispatchAudioSessionOperation({ queued.add(it); true }, { events.add("start-receipt") }) {
      events.add("start")
    }
    queued.forEach { it.run() }
    assertEquals(listOf("stop", "stop-receipt", "start", "start-receipt"), events)
  }
}
