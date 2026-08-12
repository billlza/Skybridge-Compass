package com.skybridge.compass.audit.vectors

/**
 * 四面编解码适配层（Cross-Platform Parity Audit，任务 17.2 / R9.6）。
 *
 * 该文件位于 `:app` 的 `test` 源集，属**审计工具代码**，不随生产应用打包
 * （与任务 17.1 的 [CompatibilityVectorLoader] 同一约定）。
 *
 * ## 这是「适配层」，不是新的编解码实现（G4）
 *
 * 四个面的编解码逻辑**全部复用生产入口**，本层只做三件事：
 *
 * 1. 把生产入口抛出的异常（`require` → `IllegalArgumentException`、`BufferUnderflowException`、
 *    `SerializationException` 等）**归一**为可判别的 [CodecResult]；
 * 2. 在调用生产解码器**之前**做「实际字节长度 > 该面上限」的检查，给出
 *    [CodecResult.ExceedsLengthCap]；
 * 3. 保证 [CodecSurfaceAdapter.decode] 对**任意**输入都不抛出未捕获异常。
 *
 * ## 不改变接受/拒绝边界（G4/G5，R9.6 的硬约束）
 *
 * 归一化只对**已被拒绝**的输入再做「格式非法 / 超出长度上限」的二分类，
 * **不会**把原本接受的字节序列变成拒绝，也**不会**把原本拒绝的变成接受：
 *
 * - 任何 `decode` 返回 [CodecResult.Success] 的输入，生产入口也必然解析成功且得到相同值；
 * - 任何 `decode` 返回两类错误之一的输入，生产入口也必然拒绝。
 *
 * 为此每个适配器都必须论证「长度上限预检查不会拒绝生产入口会接受的字节」
 * （见各适配器 KDoc 的「边界保持论证」小节，F3 的论证由
 * `HpkeSealedBoxCodecAdapterTest` 的边界保持测试实证）。
 *
 * ## 解码护栏（R9.6）
 *
 * - **不抛未捕获异常、不终止进程**：[decode] 捕获生产入口的异常并归一；
 * - **完成长度校验前不按声明长度预分配缓冲**：本层在长度校验通过前只读取定长头部字段，
 *   绝不 `ByteArray(declaredLen)`；超出上限的输入在**任何**解码/转字符串动作之前即被拒绝；
 * - **单次解析新增分配 ≤ 该面上限 2 倍**：被拒绝的输入（含声明超大长度的敌意输入）
 *   只产生常数级分配；
 * - **已有会话状态与已接收数据不被修改**：适配器是无状态的纯函数，[decode] 不持有、
 *   不修改任何会话状态，且不写回入参数组。
 */

/**
 * 一次解码的结果：**成功**、**格式非法**、**超出长度上限**三者互斥。
 *
 * 两类错误是**独立的变体**（而非携带字符串的同一个错误类型），因此调用方可以在不解析
 * 错误文案的情况下判别两者——这是 R9.6「可判别错误」的要求。
 */
sealed interface CodecResult<out T> {

    /** 解码成功，[value] 为生产入口解析出的值。 */
    data class Success<out T>(val value: T) : CodecResult<T>

    /**
     * **格式非法**：字节长度在该面上限之内，但内容不符合该面的线格式
     * （魔数不符、版本不支持、字段截断、声明长度与实际长度不一致、JSON 不可解析等）。
     *
     * @param reason 人类可读的诊断信息，仅用于失败报告；**不参与**错误分类判别。
     * @param cause 生产入口抛出的原始异常（若有），便于定位。
     */
    data class MalformedFormat(
        val reason: String,
        val cause: Throwable? = null,
    ) : CodecResult<Nothing>

    /**
     * **超出长度上限**：字节长度（实际长度，或头部声明的总长度）超过该面上限。
     *
     * @param actualBytes 实际（或声明的）编码长度。
     * @param maxEncodedBytes 该面的上限，来自 [CodecSurface.maxEncodedBytes]。
     * @param scope 触发的上限维度（整条记录 / 单个键值对等），F4 用于区分 1300 B 与 255 B。
     */
    data class ExceedsLengthCap(
        val actualBytes: Int,
        val maxEncodedBytes: Int,
        val scope: LengthCapScope = LengthCapScope.WHOLE_MESSAGE,
    ) : CodecResult<Nothing>

    /** 是否解码成功。 */
    val isSuccess: Boolean get() = this is Success

    /** 成功时返回值，否则返回 null。 */
    fun valueOrNull(): T? = (this as? Success)?.value

    /**
     * 成功时返回值，否则抛出 [AssertionError]（仅供测试断言使用，含诊断信息）。
     */
    fun valueOrFail(): T = when (this) {
        is Success -> value
        is MalformedFormat -> throw AssertionError("expected Success but was MalformedFormat: $reason", cause)
        is ExceedsLengthCap -> throw AssertionError(
            "expected Success but was ExceedsLengthCap: $scope actual=$actualBytes max=$maxEncodedBytes"
        )
    }
}

/** [CodecResult.ExceedsLengthCap] 触发的上限维度。 */
enum class LengthCapScope {
    /** 整条消息 / 整条记录的编码长度上限（四面都有）。 */
    WHOLE_MESSAGE,

    /** 单个键值对的编码长度上限（仅 F4 Bonjour TXT 的 255 B/对）。 */
    SINGLE_PAIR,
}

/**
 * 一个编解码面的适配器。[T] 是该面的**已解析值**类型。
 *
 * 实现必须满足 R9.6 的解码护栏（见文件头 KDoc）。属性测试 17.3–17.9 直接以本接口为被测对象。
 */
interface CodecSurfaceAdapter<T> {

    /** 该适配器覆盖的编解码面。上限的**唯一真源**是 [CodecSurface.maxEncodedBytes]。 */
    val surface: CodecSurface

    /** 该面单条编码的字节上限，等于 `surface.maxEncodedBytes`。 */
    val maxEncodedBytes: Int get() = surface.maxEncodedBytes

    /** 该适配器委托的生产入口（`文件:行`），用于审计报告与「未重新实现编解码」的自证。 */
    val delegatesTo: String

    /**
     * 解码 [bytes]。对**任意**输入（含截断、随机、敌意字节）都必须返回三态之一，
     * **不得**抛出异常，**不得**修改 [bytes]，**不得**在长度校验前按声明长度预分配缓冲。
     */
    fun decode(bytes: ByteArray): CodecResult<T>

    /**
     * 编码 [value]，字节由生产入口产出。
     *
     * 值本身违反该面长度上限时按生产入口的既有行为抛出；需要可判别结果的调用方用 [tryEncode]。
     */
    fun encode(value: T): ByteArray

    /**
     * [encode] 的归一化版本：把生产入口的编码期异常归一为 [CodecResult]，
     * 使「超出长度上限」在编码方向上同样可判别（F4 的 255 B/对上限只在编码方向可触发）。
     */
    fun tryEncode(value: T): CodecResult<ByteArray> = try {
        val bytes = encode(value)
        if (bytes.size > maxEncodedBytes) {
            CodecResult.ExceedsLengthCap(bytes.size, maxEncodedBytes)
        } else {
            CodecResult.Success(bytes)
        }
    } catch (e: Exception) {
        CodecResult.MalformedFormat(e.message ?: e::class.java.name, e)
    }
}

/**
 * 长度上限预检查：实际字节数超过上限时返回 [CodecResult.ExceedsLengthCap]，否则返回 null。
 *
 * 该检查在**任何**按声明长度分配缓冲、任何字节转字符串之前执行，因此超长输入的解析成本是常数级。
 */
internal fun <T> CodecSurfaceAdapter<T>.lengthCapViolationOrNull(bytes: ByteArray): CodecResult<T>? =
    if (bytes.size > maxEncodedBytes) {
        CodecResult.ExceedsLengthCap(
            actualBytes = bytes.size,
            maxEncodedBytes = maxEncodedBytes,
            scope = LengthCapScope.WHOLE_MESSAGE,
        )
    } else {
        null
    }

/**
 * 在 [block] 中调用生产解码入口，把异常归一为 [CodecResult.MalformedFormat]。
 *
 * 只捕获 [Exception]：四面的生产解码器在本层的长度预检查之后都不会按未校验的声明长度分配缓冲
 * （见各适配器 KDoc），因此不会出现 `OutOfMemoryError` 之类的 [Error]；把 [Error] 继续上抛
 * 保留了 JVM 级故障的可见性，不与「不终止进程」冲突（[Error] 并非解码器对敌意输入的正常反应）。
 */
internal inline fun <T> normalizingMalformed(
    context: String,
    block: () -> T,
): CodecResult<T> = try {
    CodecResult.Success(block())
} catch (e: Exception) {
    CodecResult.MalformedFormat("$context: ${e.message ?: e::class.java.name}", e)
}
