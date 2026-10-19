package com.smartwrongnotebook.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.benjaminwan.ocrlibrary.OcrEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.max

/**
 * 离线 PaddleOCR（RapidOcr onnxruntime 封装）的 Flutter 桥。
 *
 * recognize(imagePath) -> {text: 阅读顺序全文, lines: [{text, top, left}]}
 * 引擎在首次调用时初始化（约 1~2 秒），之后复用；识别在工作线程执行。
 */
class PaddleOcrPlugin(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.smartwrongnotebook/paddle_ocr"
    }

    private var engine: OcrEngine? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    @Synchronized
    private fun ensureEngine(): OcrEngine {
        return engine ?: OcrEngine(context.applicationContext).also { engine = it }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "recognize" -> {
                val path = call.arguments as? String
                if (path.isNullOrEmpty()) {
                    result.error("ARGS", "imagePath required", null)
                    return
                }
                Thread {
                    try {
                        val payload = recognizeSync(path)
                        mainHandler.post { result.success(payload) }
                    } catch (t: Throwable) {
                        val message = t.message ?: t.javaClass.simpleName
                        mainHandler.post { result.error("OCR_FAILED", message, null) }
                    }
                }.apply { isDaemon = true }.start()
            }
            else -> result.notImplemented()
        }
    }

    private fun recognizeSync(path: String): Map<String, Any> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        var sample = 1
        var longestSide = max(bounds.outWidth, bounds.outHeight)
        while (longestSide / sample > 2048) {
            sample *= 2
        }
        val bitmap = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: throw IllegalStateException("无法读取图片: $path")
        val box = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        val maxSideLen = max(bitmap.width, bitmap.height)

        val ocrResult = try {
            ensureEngine().detect(bitmap, box, maxSideLen)
        } finally {
            if (sample > 1) bitmap.recycle()
        }

        // 按框顶 y、再按左 x 排序，得到自然阅读顺序（行内左右）。
        val blocks = ocrResult.textBlocks
            .filter { it.text.isNotBlank() }
            .sortedWith(
                compareBy(
                    { block -> block.boxPoint.minOf { p -> p.y } },
                    { block -> block.boxPoint.minOf { p -> p.x } },
                )
            )
        val lines = blocks.map { block ->
            mapOf(
                "text" to block.text.trim(),
                "top" to block.boxPoint.minOf { p -> p.y },
                "left" to block.boxPoint.minOf { p -> p.x },
            )
        }
        val text = lines.joinToString("\n") { it["text"] as String }
        return mapOf(
            "text" to text,
            "lines" to lines,
        )
    }
}
