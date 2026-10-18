import 'package:flutter/material.dart';

import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

/// 混合内容视图：AI 输出里的 markdown 表格块渲染为原生表格，
/// 其余文本（含 LaTeX）交给 [MathContentView]。
class RichContentView extends StatelessWidget {
  const RichContentView(
    this.content, {
    super.key,
    this.contentFormat,
    this.style,
  });

  final String content;
  final QuestionContentFormat? contentFormat;
  final TextStyle? style;

  static final _tableRow = RegExp(r'^\s*\|.*\|\s*$');
  static final _tableSeparator = RegExp(r'^\s*\|?[\s:\-]*\-[\s:\-|]*\|?\s*$');

  @override
  Widget build(BuildContext context) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return MathContentView(content,
          contentFormat: contentFormat, style: style);
    }

    final blocks = _splitBlocks(trimmed);
    final hasTable = blocks.any((block) => block.isTable);
    if (!hasTable) {
      return MathContentView(trimmed,
          contentFormat: contentFormat, style: style);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final block in blocks) ...<Widget>[
          if (block.isTable)
            _buildTable(context, block.lines)
          else
            MathContentView(block.text,
                contentFormat: contentFormat, style: style),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  List<_ContentBlock> _splitBlocks(String text) {
    final blocks = <_ContentBlock>[];
    final tableLines = <String>[];
    final textBuffer = StringBuffer();

    void flushText() {
      final value = textBuffer.toString().trim();
      if (value.isNotEmpty) blocks.add(_ContentBlock.plain(value));
      textBuffer.clear();
    }

    void flushTable() {
      if (tableLines.isNotEmpty) {
        blocks.add(_ContentBlock.table(List<String>.of(tableLines)));
        tableLines.clear();
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
    return blocks;
  }

  Widget _buildTable(BuildContext context, List<String> lines) {
    final colorScheme = Theme.of(context).colorScheme;
    final rows = <List<String>>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (_tableSeparator.hasMatch(trimmed)) continue;
      var cells = trimmed
          .substring(1, trimmed.length - 1)
          .split('|')
          .map((cell) => cell.trim())
          .toList();
      rows.add(cells);
    }
    if (rows.isEmpty) {
      return MathContentView(lines.join('\n'), style: style);
    }
    final columnCount = rows.first.length;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        border: TableBorder.all(
          color: colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(8),
        ),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: <int, TableColumnWidth>{
          for (var i = 0; i < columnCount; i++) i: const IntrinsicColumnWidth(),
        },
        children: <TableRow>[
          for (var r = 0; r < rows.length; r++)
            TableRow(
              decoration: BoxDecoration(
                color: r == 0
                    ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
                    : null,
              ),
              children: <Widget>[
                for (var c = 0; c < columnCount; c++)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text(
                      r < rows.length && c < rows[r].length
                          ? rows[r][c]
                          : '',
                      style: (style ?? DefaultTextStyle.of(context).style)
                          .copyWith(
                        fontSize: 13,
                        fontWeight: r == 0 ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ContentBlock {
  const _ContentBlock.plain(this.text)
      : isTable = false,
        lines = const <String>[];

  const _ContentBlock.table(this.lines)
      : isTable = true,
        text = '';

  final bool isTable;
  final String text;
  final List<String> lines;
}
