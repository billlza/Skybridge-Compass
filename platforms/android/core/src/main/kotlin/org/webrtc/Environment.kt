package org.webrtc

/**
 * Runtime environment handle expected by newer libwebrtc factory builders.
 *
 * The bundled AAR references this type from Java bytecode but does not ship the
 * class itself, so we provide the minimal JNI-backed implementation that the
 * native library expects.
 */
class Environment private constructor(
    private val nativeHandle: Long
) : AutoCloseable {

    fun ref(): Long = nativeHandle

    override fun close() {
        if (nativeHandle != 0L) {
            nativeFree(nativeHandle)
        }
    }

    class Builder {
        private var fieldTrials: String? = null

        fun setFieldTrials(fieldTrials: String?): Builder = apply {
            this.fieldTrials = fieldTrials
        }

        fun build(): Environment = Environment(nativeCreate(fieldTrials))
    }

    companion object {
        @JvmStatic
        fun builder(): Builder = Builder()

        @JvmStatic
        private external fun nativeCreate(fieldTrials: String?): Long

        @JvmStatic
        private external fun nativeFree(nativeEnvironment: Long)
    }
}
