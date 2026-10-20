import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:smart_wrong_notebook/src/features/analysis/presentation/widgets/geometry_diagram_widget.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/katex_math_view.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

/// 一个已栅格化的内容块：位图 + 逻辑尺寸（单位与 PDF pt 一致）。
///
/// 导出试卷不嵌入拍照原图，而是把首次解析产出的结构化文本
/// （LaTeX 公式 / diagram 图形 / markdown 表格）用与应用内一致的
/// 渲染器画成位图块，再排进 PDF，保证"文本题 = 已核对解析 = 原图"。
class ExamRenderBlock {
  const ExamRenderBlock({
    required this.png,
    required this.widthPt,
    required this.heightPt,
  });

  final Uint8List png;
  final double widthPt;
  final double heightPt;
}

/// 分块类型：用于测试与调试，栅格化前可独立检查。
enum ExamBlockKind { text, displayMath, diagram, table, diagramFallback }

class ExamBlockDescriptor {
  const ExamBlockDescriptor({
    required this.kind,
    required this.text,
    this.diagramData,
  });

  final ExamBlockKind kind;
  final String text;
  final Map<String, dynamic>? diagramData;
}

/// 纯逻辑分块器：把 AI 结构化文本拆成可独立排版的块。
///
/// 规则（与应用内 RichContentView 的渲染顺序一致）：
/// 1. ```diagram 围栏 → 图形块（GeometryDiagramWidget 数据）
/// 2. markdown 表格行 → 表格块
/// 3. $$...$$ 独立公式 → 公式块
/// 4. 其余 → 段落文本块（行内公式由 MathContentView 渲染）
/// 超长段落按行/句拆成多个块，保证单块不超过一页可容纳高度。
class ExamContentSplitter {
  static final _diagramFence = RegExp(
    r'```(?:\s*)diagram\s*\n?([\s\S]*?)```',
    caseSensitive: false,
  );
  static final _tableRow = RegExp(r'^\s*\|.*\|\s*$');
  static final _tableSeparator = RegExp(r'^\s*\|?[\s:\-]*\-[\s:\-|]*\|?\s*$');
  static final _displayMath = RegExp(r'\$\$([\s\S]*?)\$\$', multiLine: true);

  /// 单个段落块最多行数/字符数，防止栅格高度超过一整页。
  static const maxLinesPerChunk = 10;
  static const maxCharsPerChunk = 360;

  List<ExamBlockDescriptor> split(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return const <ExamBlockDescriptor>[];

    final out = <ExamBlockDescriptor>[];
    var cursor = 0;
    for (final match in _diagramFence.allMatches(trimmed)) {
      if (match.start > cursor) {
        out.addAll(_splitText(trimmed.substring(cursor, match.start)));
      }
      out.add(_diagramBlock(match.group(1)?.trim() ?? ''));
      cursor = match.end;
    }
    if (cursor < trimmed.length) {
      out.addAll(_splitText(trimmed.substring(cursor)));
    }
    return out;
  }

  ExamBlockDescriptor _diagramBlock(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is Map) {
        return ExamBlockDescriptor(
          kind: ExamBlockKind.diagram,
          text: rawJson,
          diagramData: Map<String, dynamic>.from(decoded),
        );
      }
    } catch (_) {
      // fallthrough
    }
    return const ExamBlockDescriptor(
      kind: ExamBlockKind.diagramFallback,
      text: '（图形数据无法解析，请核对原图）',
    );
  }

  List<ExamBlockDescriptor> _splitText(String text) {
    final out = <ExamBlockDescriptor>[];
    var tableLines = <String>[];
    final textBuffer = StringBuffer();

    void flushText() {
      final value = textBuffer.toString().trim();
      if (value.isNotEmpty) out.addAll(_splitMathAndParagraphs(value));
      textBuffer.clear();
    }

    void flushTable() {
      if (tableLines.isNotEmpty) {
        out.add(ExamBlockDescriptor(
          kind: ExamBlockKind.table,
          text: tableLines.join('\n'),
        ));
        tableLines = <String>[];
      }
    }

    for (final line in text.split('\n')) {
      if (_tableRow.hasMatch(line)) {
        if (textBuffer.isNotEmpty) flushText();
        tableLines.add(line);
      } else {
        if (tableLines.isNotEmpty) flushTable();
        textBuffer.writeln(line);
      }
    }
    flushText();
    flushTable();
    return out;
  }

  List<ExamBlockDescriptor> _splitMathAndParagraphs(String text) {
    final out = <ExamBlockDescriptor>[];
    var cursor = 0;
    for (final match in _displayMath.allMatches(text)) {
      if (match.start > cursor) {
        out.addAll(_paragraphChunks(text.substring(cursor, match.start)));
      }
      final formula = match.group(1)?.trim() ?? '';
      if (formula.isNotEmpty) {
        out.add(ExamBlockDescriptor(
          kind: ExamBlockKind.displayMath,
          text: '\$\$$formula\$\$',
        ));
      }
      cursor = match.end;
    }
    if (cursor < text.length) {
      out.addAll(_paragraphChunks(text.substring(cursor)));
    }
    return out;
  }

  List<ExamBlockDescriptor> _paragraphChunks(String text) {
    final value = text.trim();
    if (value.isEmpty) return const <ExamBlockDescriptor>[];

    final lines = value.split('\n');
    if (lines.length <= maxLinesPerChunk &&
        value.length <= maxCharsPerChunk) {
      return <ExamBlockDescriptor>[
        ExamBlockDescriptor(kind: ExamBlockKind.text, text: value),
      ];
    }

    // 先按行分箱；单行超长再按句末标点细分。
    final chunks = <String>[];
    final buffer = StringBuffer();
    var bufferedLines = 0;
    for (final line in lines) {
      for (final piece in _splitLongLine(line)) {
        buffer.write(piece);
        bufferedLines++;
        if (buffer.length >= maxCharsPerChunk ||
            bufferedLines >= maxLinesPerChunk) {
          chunks.add(buffer.toString());
          buffer.clear();
          bufferedLines = 0;
        } else {
          buffer.write('\n');
        }
      }
    }
    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) chunks.add(tail);

    return <ExamBlockDescriptor>[
      for (final chunk in chunks)
        if (chunk.trim().isNotEmpty)
          ExamBlockDescriptor(kind: ExamBlockKind.text, text: chunk.trim()),
    ];
  }

  List<String> _splitLongLine(String line) {
    if (line.length <= maxCharsPerChunk) return <String>[line];
    final pieces = <String>[];
    final sentences = line.split(RegExp(r'(?<=[。！？；;)】])'));
    final buffer = StringBuffer();
    for (final sentence in sentences) {
      if (buffer.length + sentence.length > maxCharsPerChunk &&
          buffer.isNotEmpty) {
        pieces.add(buffer.toString());
        buffer.clear();
      }
      buffer.write(sentence);
    }
    final tail = buffer.toString();
    if (tail.isNotEmpty) pieces.add(tail);
    return pieces;
  }
}

/// 离屏栅格化器：把分块后的 widget 渲染为高清 PNG。
///
/// 实现：把一批块放入 Overlay 上的离屏区域（屏幕外、固定宽度），
/// 等待两帧布局绘制完成后用 RepaintBoundary.toImage 截取。
/// 截取期间临时关闭 KaTeX WebView 兜底（平台视图无法被
/// RepaintBoundary 捕获，公式由 flutter_math 渲染，失败退化为可读文本）。
class ExamContentRasterizer {
  ExamContentRasterizer({this.pixelRatio = 3.0});

  /// 3x：16 开内容宽 442pt → 1326px，约合 216 DPI，打印清晰。
  final double pixelRatio;

  static const _batchSize = 24;

  /// [contents] 与返回值一一对应；某块失败时该题返回空列表，
  /// 调用方应退回纯文本排版。
  Future<List<List<ExamRenderBlock>>> rasterizeAll({
    required OverlayState overlay,
    required List<String> contents,
    required double widthPt,
    required double fontSize,
    void Function(int done, int total)? onProgress,
  }) async {
    final splitter = ExamContentSplitter();
    final descriptors = <List<ExamBlockDescriptor>>[
      for (final content in contents) splitter.split(content),
    ];

    // 展平成 (questionIndex, descriptor) 列表分批渲染。
    final flat = <(int, ExamBlockDescriptor)>[];
    for (var i = 0; i < descriptors.length; i++) {
      for (final descriptor in descriptors[i]) {
        flat.add((i, descriptor));
      }
    }

    final results = <List<ExamRenderBlock>>[
      for (var i = 0; i < contents.length; i++) <ExamRenderBlock>[],
    ];

    final katexWasEnabled = KatexMathView.enabled;
    KatexMathView.enabled = false;
    var done = 0;
    OverlayEntry? entry;
    try {
      for (var start = 0; start < flat.length; start += _batchSize) {
        final batch = flat.sublist(
            start, (start + _batchSize).clamp(0, flat.length));
        final keys = <GlobalKey>[
          for (var i = 0; i < batch.length; i++) GlobalKey(),
        ];
        entry = OverlayEntry(
          builder: (context) => _buildOffstageBatch(
            batch: batch,
            keys: keys,
            widthPt: widthPt,
            fontSize: fontSize,
          ),
        );
        overlay.insert(entry);
        await _waitForFrames();

        for (var i = 0; i < batch.length; i++) {
          final (questionIndex, _) = batch[i];
          final block = await _capture(keys[i]);
          if (block != null) {
            results[questionIndex].add(block);
          }
          done++;
          onProgress?.call(done, flat.length);
        }
        entry.remove();
        entry = null;
      }
    } finally {
      entry?.remove();
      KatexMathView.enabled = katexWasEnabled;
    }
    return results;
  }

  Widget _buildOffstageBatch({
    required List<(int, ExamBlockDescriptor)> batch,
    required List<GlobalKey> keys,
    required double widthPt,
    required double fontSize,
  }) {
    final style = TextStyle(
      fontSize: fontSize,
      height: 1.5,
      color: const Color(0xFF111111),
    );
    return Positioned(
      // 屏幕外固定宽度离屏区；Column 放进纵向滚动容器以获得无界高度约束。
      left: -20000,
      top: 0,
      width: widthPt,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Theme(
          data: ThemeData.light(useMaterial3: true),
          child: MediaQuery(
            data: const MediaQueryData(),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (var i = 0; i < batch.length; i++)
                    RepaintBoundary(
                      key: keys[i],
                      child: blockWidget(batch[i].$2, style: style),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 单个块 → 待栅格化的 widget。公开以便测试各类型块的构建。
  Widget blockWidget(
    ExamBlockDescriptor descriptor, {
    required TextStyle style,
  }) {
    switch (descriptor.kind) {
      case ExamBlockKind.diagram:
        return GeometryDiagramWidget(
          diagramData: descriptor.diagramData ?? const <String, dynamic>{},
          showAuxiliaryButton: false,
          plain: true,
        );
      case ExamBlockKind.diagramFallback:
      case ExamBlockKind.text:
      case ExamBlockKind.displayMath:
        return MathContentView(
          descriptor.text,
          style: style,
        );
      case ExamBlockKind.table:
        return _TableWidget(lines: descriptor.text.split('\n'), style: style);
    }
  }

  Future<ExamRenderBlock?> _capture(GlobalKey key) async {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return null;
    final size = object.size;
    if (size.width <= 0 || size.height <= 0) return null;

    final ui.Image image;
    try {
      image = await object.toImage(pixelRatio: pixelRatio);
    } catch (_) {
      return null;
    }
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes == 0) return null;
      return ExamRenderBlock(
        png: data.buffer.asUint8List(),
        widthPt: size.width,
        heightPt: size.height,
      );
    } finally {
      image.dispose();
    }
  }

  Future<void> _waitForFrames() async {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < 2; i++) {
      try {
        // 无待调度帧时 endOfFrame 可能不返回，超时即视为布局已稳定。
        await binding.endOfFrame.timeout(const Duration(milliseconds: 200));
      } catch (_) {
        // timeout 超时，继续。
      }
    }
  }
}

/// 打印用 markdown 表格：与应用内表格解析规则一致，
/// 但不做横向滚动，超宽时整体等比缩小以适配纸宽。
class _TableWidget extends StatelessWidget {
  const _TableWidget({required this.lines, required this.style});

  final List<String> lines;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (ExamContentSplitter._tableSeparator.hasMatch(trimmed)) continue;
      final cells = trimmed
          .substring(1, trimmed.length - 1)
          .split('|')
          .map((cell) => cell.trim())
          .toList();
      rows.add(cells);
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    final columnCount = rows.first.length;
    final outline = Colors.grey.shade500;

    final table = Table(
      border: TableBorder.all(color: outline, width: 0.8),
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: <int, TableColumnWidth>{
        for (var i = 0; i < columnCount; i++) i: const IntrinsicColumnWidth(),
      },
      children: <TableRow>[
        for (var r = 0; r < rows.length; r++)
          TableRow(
            children: <Widget>[
              for (var c = 0; c < columnCount; c++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  child: MathContentView(
                    r < rows.length && c < rows[r].length ? rows[r][c] : '',
                    style: style.copyWith(
                      fontSize: style.fontSize! - 0.5,
                      fontWeight: r == 0 ? FontWeight.w600 : null,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );

    return FittedBox(
      alignment: Alignment.centerLeft,
      fit: BoxFit.scaleDown,
      child: table,
    );
  }
}
