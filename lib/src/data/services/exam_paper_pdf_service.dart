import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:smart_wrong_notebook/src/shared/utils/math_text_converter.dart';

enum ExamPaperSize { sixteenK, eightK }

/// 一道进入试卷的题目。
class ExamPaperEntry {
  const ExamPaperEntry({
    required this.stem,
    this.answer,
    this.explanation,
    this.imagePath,
  });

  /// 题干（纯文本/LaTeX 混合，导出时转换为可读文本）。
  final String stem;

  /// 参考答案（includeAnswers 时输出到答案页）。
  final String? answer;

  /// 解析说明（附在答案之后）。
  final String? explanation;

  /// 原题图片（可选，仅错题原题模式）。
  final String? imagePath;
}

class ExamPaperResult {
  const ExamPaperResult({required this.bytes, this.warning});

  final Uint8List bytes;

  /// 非致命提示（如某张图片读取失败），生成完成后展示给用户。
  final String? warning;
}

/// 生成可打印的错题练习卷 PDF。
///
/// 16 开（184×260mm）单栏标准版；8 开（260×368mm）单栏大字版。
class ExamPaperPdfService {
  pw.Font? _font;

  Future<pw.Font> _loadFont() async {
    if (_font != null) return _font!;
    final data = await rootBundle
        .load('assets/fonts/NotoSansSC-Regular.ttf');
    _font = pw.Font.ttf(data);
    return _font!;
  }

  Future<ExamPaperResult> build({
    required String title,
    required List<ExamPaperEntry> entries,
    required ExamPaperSize paperSize,
    required bool includeAnswers,
  }) async {
    final font = await _loadFont();
    final isEightK = paperSize == ExamPaperSize.eightK;
    final pageFormat = isEightK
        ? PdfPageFormat(260 * PdfPageFormat.mm, 368 * PdfPageFormat.mm)
        : PdfPageFormat(184 * PdfPageFormat.mm, 260 * PdfPageFormat.mm);
    final baseFontSize = isEightK ? 12.5 : 11.0;
    final margins = pw.EdgeInsets.fromLTRB(
      isEightK ? 18 * PdfPageFormat.mm : 14 * PdfPageFormat.mm,
      isEightK ? 20 * PdfPageFormat.mm : 16 * PdfPageFormat.mm,
      isEightK ? 18 * PdfPageFormat.mm : 14 * PdfPageFormat.mm,
      isEightK ? 16 * PdfPageFormat.mm : 13 * PdfPageFormat.mm,
    );

    final warnings = <String>[];
    final images = <pw.ImageProvider?>[];
    for (final entry in entries) {
      pw.ImageProvider? image;
      final path = entry.imagePath;
      if (path != null && path.isNotEmpty) {
        try {
          final bytes = await File(path).readAsBytes();
          image = pw.MemoryImage(bytes);
        } catch (_) {
          warnings.add('有一张原题图片读取失败，已跳过。');
        }
      }
      images.add(image);
    }

    final baseStyle = pw.TextStyle(font: font, fontSize: baseFontSize, lineSpacing: 3);
    final boldStyle = pw.TextStyle(
        font: font, fontSize: baseFontSize + 1, fontWeight: pw.FontWeight.bold);

    pw.Widget questionBlock(int index, ExamPaperEntry entry, pw.ImageProvider? image) {
      return pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 10),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              '${index + 1}. ${MathTextConverter.toReadable(entry.stem)}',
              style: baseStyle,
            ),
            if (image != null)
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 6, left: 12),
                constraints: pw.BoxConstraints(
                  maxWidth: pageFormat.availableWidth * 0.55,
                  maxHeight: pageFormat.availableHeight * 0.32,
                ),
                child: pw.Image(image, fit: pw.BoxFit.contain),
              ),
          ],
        ),
      );
    }

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );

    doc.addPage(pw.MultiPage(
      pageFormat: pageFormat,
      margin: margins,
      header: (context) => _buildHeader(title, baseStyle),
      footer: (context) => _buildFooter(context, font),
      build: (context) => <pw.Widget>[
        for (var i = 0; i < entries.length; i++)
          questionBlock(i, entries[i], images[i]),
      ],
    ));

    if (includeAnswers) {
      doc.addPage(pw.MultiPage(
        pageFormat: pageFormat,
        margin: margins,
        header: (context) => _buildHeader('$title·参考答案', baseStyle),
        footer: (context) => _buildFooter(context, font),
        build: (context) => <pw.Widget>[
          for (var i = 0; i < entries.length; i++)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Text('${i + 1}. ', style: boldStyle),
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(left: 14),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: <pw.Widget>[
                        pw.Text(
                          '答案：${MathTextConverter.toReadable(
                            entries[i].answer?.trim().isNotEmpty == true
                                ? entries[i].answer!
                                : '（本题暂无答案记录）',
                          )}',
                          style: baseStyle,
                        ),
                        if (entries[i].explanation?.trim().isNotEmpty == true)
                          pw.Padding(
                            padding: const pw.EdgeInsets.only(top: 2),
                            child: pw.Text(
                              '解析：${MathTextConverter.toReadable(entries[i].explanation!)}',
                              style: pw.TextStyle(
                                  font: font,
                                  fontSize: baseFontSize - 1,
                                  color: const PdfColor(0.35, 0.35, 0.35)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ));
    }

    return ExamPaperResult(
      bytes: await doc.save(),
      warning: warnings.isEmpty ? null : warnings.join(),
    );
  }

  pw.Widget _buildHeader(String title, pw.TextStyle baseStyle) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.Text(title,
              style: pw.TextStyle(
                  font: baseStyle.font,
                  fontSize: baseStyle.fontSize! + 4,
                  fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text('姓名：__________　班级：__________　得分：__________',
              style: baseStyle),
          pw.Divider(thickness: 0.6),
        ],
      ),
    );
  }

  pw.Widget _buildFooter(pw.Context context, pw.Font font) {
    return pw.Container(
      alignment: pw.Alignment.center,
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Text(
        '第 ${context.pageNumber} 页 / 共 ${context.pagesCount} 页',
        style: pw.TextStyle(
            font: font,
            fontSize: 9,
            color: const PdfColor(0.45, 0.45, 0.45)),
      ),
    );
  }
}
