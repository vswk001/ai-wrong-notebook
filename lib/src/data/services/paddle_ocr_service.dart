import 'dart:io';

import 'package:flutter/services.dart';

/// 设备端离线 OCR 文本来源（PaddleOCR，仅 Android 实现）。
abstract class OcrTextSource {
  /// 返回按阅读顺序排列的整图识别文本；不可用时返回 null。
  Future<String?> recognize(String imagePath);
}

/// 通过 MethodChannel 调用 Android 端 PaddleOCR。
///
/// 非 Android 平台、引擎初始化失败或识别异常时返回 null，
/// 调用方应降级为纯 AI 视觉识别（现有流程不受影响）。
class PaddleOcrChannelService implements OcrTextSource {
  PaddleOcrChannelService();

  static const MethodChannel _channel =
      MethodChannel('com.smartwrongnotebook/paddle_ocr');

  @override
  Future<String?> recognize(String imagePath) async {
    if (!Platform.isAndroid) return null;
    if (imagePath.trim().isEmpty) return null;
    try {
      final result = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('recognize', imagePath);
      if (result == null) return null;
      final text = (result['text'] as String?)?.trim() ?? '';
      return text.isEmpty ? null : text;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
