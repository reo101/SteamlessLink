/*
 * SPDX-License-Identifier: MIT
 * Source: https://github.com/n0-computer/iroh-ffi/blob/v1.2.0/kotlin/android/src/main/kotlin/computer/iroh/IrohAndroid.kt
 *
 * Copyright 2025 N0, INC.
 *
 * Permission is hereby granted, free of charge, to any
 * person obtaining a copy of this software and associated
 * documentation files (the "Software"), to deal in the
 * Software without restriction, including without
 * limitation the rights to use, copy, modify, merge,
 * publish, distribute, sublicense, and/or sell copies of
 * the Software, and to permit persons to whom the Software
 * is furnished to do so, subject to the following
 * conditions:
 *
 * The above copyright notice and this permission notice
 * shall be included in all copies or substantial portions
 * of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
 * ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
 * TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
 * PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
 * SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
 * IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
package computer.iroh

import android.content.Context

/**
 * Android-specific iroh initialization. Apps must call
 * [installAndroidContext] once during startup (typically from
 * `Application.onCreate` or before constructing any [Endpoint]) so
 * that iroh's DNS resolver can reach Android's [`LinkProperties`] via
 * JNI.
 *
 * The call is idempotent — subsequent invocations are no-ops.
 */
object IrohAndroid {
    init {
        // libiroh_ffi exposes the JNI entry point Java_computer_iroh_IrohAndroid_installAndroidContext.
        // Loading the library here makes the symbol available before the first external call.
        System.loadLibrary("iroh_ffi")
    }

    @JvmStatic
    external fun installAndroidContext(context: Context)
}
