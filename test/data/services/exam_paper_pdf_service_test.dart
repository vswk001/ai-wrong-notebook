import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:smart_wrong_notebook/src/data/services/exam_content_rasterizer.dart';
import 'package:smart_wrong_notebook/src/data/services/exam_paper_pdf_service.dart';

/// 1x1 透明 PNG，作为占位栅格块。
final Uint8List _png1x1 =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
        'AAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

ExamRenderBlock _block(double widthPt, double heightPt) => ExamRenderBlock(
      png: _png1x1,
      widthPt: widthPt,
      heightPt: heightPt,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('builds PDF from pre-rendered stem blocks', () async {
    final service = ExamPaperPdfService();
    final result = await service.build(
      title: '数学错题练习卷',
      entries: <ExamPaperEntry>[
        ExamPaperEntry(
          stem: '计算 \\(\\frac{1}{2}+\\frac{1}{3}\\) 的结果。',
          stemBlocks: <ExamRenderBlock>[
            _block(440, 30),
            _block(200, 120),
          ],
          answer: '\\(\\frac{5}{6}\\)',
          answerBlocks: <ExamRenderBlock>[_block(120, 24)],
        ),
        ExamPaperEntry(
          stem: '纯文本兜底题：12 + 34 = ?',
          answer: '46',
        ),
      ],
      paperSize: ExamPaperSize.sixteenK,
      includeAnswers: true,
    );

    expect(result.bytes, isNotEmpty);
    expect(utf8.decode(result.bytes.sublist(0, 5), allowMalformed: true),
        '%PDF-');
  });

  test('oversized blocks are scaled down without throwing', () async {
    final service = ExamPaperPdfService();
    final result = await service.build(
      title: '超高块缩放测试',
      entries: <ExamPaperEntry>[
        ExamPaperEntry(
          stem: '超高图形题',
          stemBlocks: <ExamRenderBlock>[_block(440, 5000)],
        ),
      ],
      paperSize: ExamPaperSize.sixteenK,
      includeAnswers: false,
    );
    expect(result.bytes, isNotEmpty);
  });

  test('eightK layout also supports blocks and answers', () async {
    final service = ExamPaperPdfService();
    final result = await service.build(
      title: '八开大字版',
      entries: <ExamPaperEntry>[
        ExamPaperEntry(
          stem: '如图，求阴影部分面积。',
          stemBlocks: <ExamRenderBlock>[
            _block(630, 300),
          ],
          answer: '42',
          explanation: '长方形面积减三角形面积。',
          explanationBlocks: <ExamRenderBlock>[_block(300, 60)],
        ),
      ],
      paperSize: ExamPaperSize.eightK,
      includeAnswers: true,
    );
    expect(result.bytes, isNotEmpty);
  });

  test('contentWidthFor matches paper content area', () {
    final sixteenK = ExamPaperPdfService.contentWidthFor(
      ExamPaperSize.sixteenK,
    );
    final eightK =
        ExamPaperPdfService.contentWidthFor(ExamPaperSize.eightK);
    // 16 开：184mm 纸宽减左右各 14mm；8 开：260mm 减各 18mm。
    expect((sixteenK * 25.4 / 72).round(), 156);
    expect((eightK * 25.4 / 72).round(), 224);
  });
}
