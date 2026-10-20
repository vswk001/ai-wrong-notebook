import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smart_wrong_notebook/src/data/services/exam_content_rasterizer.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/katex_math_view.dart';

void main() {
  group('ExamContentSplitter', () {
    final splitter = ExamContentSplitter();

    test('empty content yields no blocks', () {
      expect(splitter.split(''), isEmpty);
      expect(splitter.split('   \n  '), isEmpty);
    });

    test('plain text becomes a single text block', () {
      final blocks = splitter.split('计算 12 + 34 的结果。');
      expect(blocks.length, 1);
      expect(blocks.first.kind, ExamBlockKind.text);
      expect(blocks.first.text, contains('12 + 34'));
    });

    test('diagram fence becomes a diagram block with parsed data', () {
      const content = '如图所示，求面积。\n'
          '```diagram\n{"elements":[{"type":"polygon","points":[[0,0],[1,0],[1,1],[0,1]]}]}\n```';
      final blocks = splitter.split(content);
      expect(blocks.length, 2);
      expect(blocks.first.kind, ExamBlockKind.text);
      expect(blocks.last.kind, ExamBlockKind.diagram);
      expect(blocks.last.diagramData?['elements'], isA<List>());
    });

    test('invalid diagram json degrades to a fallback text block', () {
      const content = '题目\n```diagram\n{broken json\n```';
      final blocks = splitter.split(content);
      expect(blocks.last.kind, ExamBlockKind.diagramFallback);
      expect(blocks.last.text, contains('图形数据无法解析'));
    });

    test('markdown table becomes a table block', () {
      const content = '下表是商品价格：\n'
          '| 商品 | 价格 |\n'
          '| --- | --- |\n'
          '| 笔 | 2 元 |\n'
          '| 本 | 5 元 |';
      final blocks = splitter.split(content);
      expect(blocks.length, 2);
      expect(blocks.last.kind, ExamBlockKind.table);
      expect(blocks.last.text, contains('| 笔 | 2 元 |'));
    });

    test('display math splits into math block between text blocks', () {
      const content = '解方程：\n\$\$\\begin{cases} x+y=5 \\\\ x-y=1 \\end{cases}\$\$\n求 x 的值。';
      final blocks = splitter.split(content);
      expect(blocks.map((b) => b.kind).toList(), containsAll(<ExamBlockKind>[
        ExamBlockKind.text,
        ExamBlockKind.displayMath,
      ]));
      final math = blocks.firstWhere((b) => b.kind == ExamBlockKind.displayMath);
      expect(math.text, contains(r'\begin{cases}'));
    });

    test('long paragraphs are chunked to bounded size', () {
      final longText = List<String>.filled(40, '这是一段很长的题目内容行。').join('\n');
      final blocks = splitter.split(longText);
      expect(blocks.length, greaterThan(1));
      expect(blocks.every((b) => b.kind == ExamBlockKind.text), isTrue);
      for (final block in blocks) {
        expect(block.text.length, lessThanOrEqualTo(400));
        expect(block.text.split('\n').length,
            lessThanOrEqualTo(ExamContentSplitter.maxLinesPerChunk));
      }
    });

    test('inline latex stays inside a single text block', () {
      const content = r'已知 \(\frac{1}{2}+\frac{1}{3}\)，求和。';
      final blocks = splitter.split(content);
      expect(blocks.length, 1);
      expect(blocks.first.kind, ExamBlockKind.text);
      expect(blocks.first.text, contains(r'\frac'));
    });
  });

  group('ExamContentRasterizer.blockWidget', () {
    testWidgets('builds every block kind without errors', (tester) async {
      final rasterizer = ExamContentRasterizer();
      const style = TextStyle(fontSize: 11, color: Color(0xFF111111));
      final descriptors = <ExamBlockDescriptor>[
        const ExamBlockDescriptor(kind: ExamBlockKind.text, text: '纯文本块'),
        const ExamBlockDescriptor(
            kind: ExamBlockKind.displayMath, text: '\$\$x^2=4\$\$'),
        const ExamBlockDescriptor(
            kind: ExamBlockKind.diagram, text: '', diagramData: <String, dynamic>{
          'elements': <Map<String, dynamic>>[
            {'type': 'line', 'x1': 0.1, 'y1': 0.2, 'x2': 0.9, 'y2': 0.2},
          ],
        }),
        const ExamBlockDescriptor(
            kind: ExamBlockKind.table,
            text: '| a | b |\n| --- | --- |\n| 1 | 2 |'),
        const ExamBlockDescriptor(
            kind: ExamBlockKind.diagramFallback, text: '（图形数据无法解析）'),
      ];

      for (final descriptor in descriptors) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              child: rasterizer.blockWidget(descriptor, style: style),
            ),
          ),
        ));
        expect(tester.takeException(), isNull);
      }
    });

    test('KaTeX fallback preference is documented as disabled during capture',
        () {
      // KatexMathView.enabled 由 rasterizeAll 在截取期间临时置 false；
      // 这里仅锁定开关本身可静态切换（默认开启）。
      expect(KatexMathView.enabled, isTrue);
    });
  });
}
