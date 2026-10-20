import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:smart_wrong_notebook/src/data/services/exam_content_rasterizer.dart';
import 'package:smart_wrong_notebook/src/shared/utils/math_text_converter.dart';

enum ExamPaperSize { sixteenK, eightK }

/// 一道进入试卷的题目。
///
/// 出卷不再嵌入拍照原图：题目内容以首次解析产出的结构化文本为准，
/// 由 [ExamContentRasterizer] 预渲染为位图块（公式/图形/表格高保真），
/// 纯文本块仅作为栅格化失败时的兜底。
class ExamPaperEntry {
  const ExamPaperEntry({
    required this.stem,
    this.answer,
    this.explanation,
    this.stemBlocks = const <ExamRenderBlock>[],
    this.answerBlocks = const <ExamRenderBlock>[],
    this.explanationBlocks = const <ExamRenderBlock>[],
  });

  /// 题干原文（结构化文本，兜底时线性化为可读文本）。
  final String stem;

  /// 参考答案（includeAnswers 时输出到答案页）。
  final String? answer;

  /// 解析说明（附在答案之后）。
  final String? explanation;

  /// 题干预渲染块（含公式/图形/表格）。
  final List<ExamRenderBlock> stemBlocks;

  /// 答案预渲染块。
  final List<ExamRenderBlock> answerBlocks;

  /// 解析预渲染块。
  final List<ExamRenderBlock> explanationBlocks;
}

class ExamPaperResult {
  const ExamPaperResult({required this.bytes});

  final Uint8List bytes;
}

/// 生成可打印的错题练习卷 PDF。
///
/// 16 开（184×260mm）单栏标准版；8 开（260×368mm）单栏大字版。
class ExamPaperPdfService {
  pw.Font? _font;

  /// 栅格化内容块时使用的逻辑宽度（pt），与版心宽度一致。
  static double contentWidthFor(ExamPaperSize paperSize) {
    final isEightK = paperSize == ExamPaperSize.eightK;
    final pageWidth = isEightK ? 260.0 : 184.0;
    final margin = isEightK ? 18.0 : 14.0;
    return (pageWidth - margin * 2) * PdfPageFormat.mm;
  }

  /// 栅格化内容块时使用的字号，与正文一致。
  static double baseFontSizeFor(ExamPaperSize paperSize) =>
      paperSize == ExamPaperSize.eightK ? 12.5 : 11.0;

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
    final baseFontSize = baseFontSizeFor(paperSize);
    final margins = pw.EdgeInsets.fromLTRB(
      isEightK ? 18 * PdfPageFormat.mm : 14 * PdfPageFormat.mm,
      isEightK ? 20 * PdfPageFormat.mm : 16 * PdfPageFormat.mm,
      isEightK ? 18 * PdfPageFormat.mm : 14 * PdfPageFormat.mm,
      isEightK ? 16 * PdfPageFormat.mm : 13 * PdfPageFormat.mm,
    );
    final contentWidth =
        pageFormat.width - margins.horizontal;
    // 预留页眉页脚后单个内容块可占的最大高度，超高块等比缩小。
    final maxBlockHeight =
        pageFormat.height - margins.vertical - 110;

    final baseStyle = pw.TextStyle(font: font, fontSize: baseFontSize, lineSpacing: 3);
    final boldStyle = pw.TextStyle(
        font: font, fontSize: baseFontSize + 1, fontWeight: pw.FontWeight.bold);

    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );

    doc.addPage(pw.MultiPage(
      pageFormat: pageFormat,
      margin: margins,
      header: (context) => _buildHeader(title, baseStyle),
      footer: (context) => _buildFooter(context, font),
      build: (context) => <pw.Widget>[
        // 块级展开为顶层 widget，MultiPage 可在块之间分页。
        for (var i = 0; i < entries.length; i++) ..._questionWidgets(
          index: i,
          blocks: entries[i].stemBlocks,
          fallbackText: entries[i].stem,
          contentWidth: contentWidth,
          maxBlockHeight: maxBlockHeight,
          baseStyle: baseStyle,
          questionGap: 10,
        ),
      ],
    ));

    if (includeAnswers) {
      doc.addPage(pw.MultiPage(
        pageFormat: pageFormat,
        margin: margins,
        header: (context) => _buildHeader('$title·参考答案', baseStyle),
        footer: (context) => _buildFooter(context, font),
        build: (context) => <pw.Widget>[
          for (var i = 0; i < entries.length; i++) ..._answerWidgets(
            index: i,
            entry: entries[i],
            contentWidth: contentWidth,
            maxBlockHeight: maxBlockHeight,
            baseStyle: baseStyle,
            boldStyle: boldStyle,
          ),
        ],
      ));
    }

    return ExamPaperResult(bytes: await doc.save());
  }

  /// 题号与首个内容块合并为一个 widget，其余块独立输出便于分页。
  List<pw.Widget> _questionWidgets({
    required int index,
    required List<ExamRenderBlock> blocks,
    required String fallbackText,
    required double contentWidth,
    required double maxBlockHeight,
    required pw.TextStyle baseStyle,
    required double questionGap,
  }) {
    if (blocks.isEmpty) {
      return <pw.Widget>[
        pw.Padding(
          padding: pw.EdgeInsets.only(bottom: questionGap),
          child: pw.Text(
            '${index + 1}. ${MathTextConverter.toReadable(fallbackText)}',
            style: baseStyle,
          ),
        ),
      ];
    }

    final out = <pw.Widget>[];
    for (var b = 0; b < blocks.length; b++) {
      final isLast = b == blocks.length - 1;
      final image = _blockImage(
        blocks[b],
        contentWidth: contentWidth,
        maxBlockHeight: maxBlockHeight,
      );
      out.add(pw.Padding(
        padding: pw.EdgeInsets.only(
          bottom: isLast ? questionGap : 4,
          left: 14,
        ),
        child: b == 0
            ? pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: <pw.Widget>[
                  pw.Text('${index + 1}.', style: baseStyle),
                  pw.SizedBox(height: 4),
                  image,
                ],
              )
            : image,
      ));
    }
    return out;
  }

  List<pw.Widget> _answerWidgets({
    required int index,
    required ExamPaperEntry entry,
    required double contentWidth,
    required double maxBlockHeight,
    required pw.TextStyle baseStyle,
    required pw.TextStyle boldStyle,
  }) {
    final answerText = entry.answer?.trim().isNotEmpty == true
        ? entry.answer!
        : '（本题暂无答案记录）';
    final explanationText = entry.explanation?.trim().isNotEmpty == true
        ? entry.explanation!
        : null;

    pw.Widget label(String text, pw.TextStyle style) =>
        pw.Text(text, style: style);

    if (entry.answerBlocks.isEmpty && entry.explanationBlocks.isEmpty) {
      final buffer = StringBuffer('答案：${MathTextConverter.toReadable(answerText)}');
      if (explanationText != null) {
        buffer.write('\n解析：${MathTextConverter.toReadable(explanationText)}');
      }
      return <pw.Widget>[
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: <pw.Widget>[
              label('${index + 1}. ', boldStyle),
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 14),
                child: pw.Text(buffer.toString(), style: baseStyle),
              ),
            ],
          ),
        ),
      ];
    }

    final out = <pw.Widget>[
      pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            label('${index + 1}. 答案', boldStyle),
            if (entry.answerBlocks.isEmpty)
              pw.Padding(
                padding: const pw.EdgeInsets.only(left: 14),
                child: label(
                    '答案：${MathTextConverter.toReadable(answerText)}',
                    baseStyle),
              ),
          ],
        ),
      ),
    ];
    for (final block in entry.answerBlocks) {
      out.add(pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4, left: 14),
        child: _blockImage(
          block,
          contentWidth: contentWidth,
          maxBlockHeight: maxBlockHeight,
        ),
      ));
    }
    if (entry.explanationBlocks.isNotEmpty || explanationText != null) {
      out.add(pw.Padding(
        padding: const pw.EdgeInsets.only(top: 2),
        child: label('解析', boldStyle),
      ));
      if (entry.explanationBlocks.isEmpty) {
        out.add(pw.Padding(
          padding: const pw.EdgeInsets.only(left: 14),
          child: pw.Text(
            MathTextConverter.toReadable(explanationText!),
            style: pw.TextStyle(
                font: baseStyle.font,
                fontSize: baseStyle.fontSize! - 1,
                color: const PdfColor(0.35, 0.35, 0.35)),
          ),
        ));
      }
      for (final block in entry.explanationBlocks) {
        out.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 4, left: 14),
          child: _blockImage(
            block,
            contentWidth: contentWidth,
            maxBlockHeight: maxBlockHeight,
          ),
        ));
      }
    }
    out.add(pw.SizedBox(height: 8));
    return out;
  }

  /// 位图块 → PDF 图片；超宽超高时等比缩放居中。
  pw.Widget _blockImage(
    ExamRenderBlock block, {
    required double contentWidth,
    required double maxBlockHeight,
  }) {
    var width = block.widthPt;
    var height = block.heightPt;
    final maxWidth = contentWidth - 14; // 题号缩进
    if (width > maxWidth) {
      height = height * maxWidth / width;
      width = maxWidth;
    }
    if (height > maxBlockHeight) {
      width = width * maxBlockHeight / height;
      height = maxBlockHeight;
    }
    return pw.Align(
      alignment: pw.Alignment.centerLeft,
      child: pw.Image(
        pw.MemoryImage(block.png),
        width: width,
        height: height,
        fit: pw.BoxFit.contain,
      ),
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
