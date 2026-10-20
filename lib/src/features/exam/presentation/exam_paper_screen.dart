import 'dart:io';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/services/exam_content_rasterizer.dart';
import 'package:smart_wrong_notebook/src/data/services/exam_paper_pdf_service.dart';
import 'package:smart_wrong_notebook/src/domain/models/generated_exercise.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

class ExamPaperScreen extends ConsumerStatefulWidget {
  const ExamPaperScreen({super.key});

  @override
  ConsumerState<ExamPaperScreen> createState() => _ExamPaperScreenState();
}

enum _ExamSource { original, variant }

class _ExamPaperScreenState extends ConsumerState<ExamPaperScreen> {
  final Set<String> _selectedIds = <String>{};
  Subject? _subjectFilter;
  bool _generating = false;

  @override
  Widget build(BuildContext context) {
    final questionsAsync = ref.watch(questionListProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('出卷')),
      body: questionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载错题失败：$error')),
        data: (questions) {
          final usable = questions
              .where((q) =>
                  q.correctedText.trim().isNotEmpty ||
                  q.normalizedQuestionText.trim().isNotEmpty ||
                  q.extractedQuestionText.trim().isNotEmpty)
              .toList();
          if (usable.isEmpty) {
            return const Center(child: Text('错题本还没有可用题目，先去拍照录题吧'));
          }
          final subjects = <Subject?>[null, ...{
            for (final q in usable) q.subject
          }];
          final filtered = _subjectFilter == null
              ? usable
              : usable.where((q) => q.subject == _subjectFilter).toList();
          final selectedCount =
              _selectedIds.intersection(usable.map((q) => q.id).toSet()).length;

          return Column(
            children: <Widget>[
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: <Widget>[
                    for (final subject in subjects)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(subject?.label ?? '全部'),
                          selected: _subjectFilter == subject,
                          onSelected: (_) =>
                              setState(() => _subjectFilter = subject),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final question = filtered[index];
                    final selected = _selectedIds.contains(question.id);
                    return _QuestionPickCard(
                      question: question,
                      selected: selected,
                      onToggle: () => setState(() {
                        if (selected) {
                          _selectedIds.remove(question.id);
                        } else {
                          _selectedIds.add(question.id);
                        }
                      }),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  decoration: BoxDecoration(
                    color: colorScheme.surface,
                    border: Border(
                        top: BorderSide(color: colorScheme.outlineVariant)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Text('随机',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: colorScheme.onSurfaceVariant)),
                          const SizedBox(width: 6),
                          for (final n in const <int>[5, 10, 15, 20])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ActionChip(
                                label: Text('$n题'),
                                labelStyle: const TextStyle(fontSize: 12),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _randomPick(filtered, n),
                              ),
                            ),
                          const Spacer(),
                          Text('已选 $selectedCount 题',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: selectedCount == 0 || _generating
                              ? null
                              : _showExportSheet,
                          icon: const Icon(CupertinoIcons.doc_plaintext),
                          label: const Text('生成试卷 PDF'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _randomPick(List<QuestionRecord> pool, int count) {
    if (pool.isEmpty) return;
    final shuffled = List<QuestionRecord>.of(pool)..shuffle(Random());
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(shuffled.take(min(count, pool.length)).map((q) => q.id));
    });
  }

  Future<void> _showExportSheet() async {
    final questionsAsync = ref.read(questionListProvider).valueOrNull ?? const <QuestionRecord>[];
    final byId = <String, QuestionRecord>{
      for (final q in questionsAsync) q.id: q
    };
    final selected = <QuestionRecord>[
      for (final id in _selectedIds)
        if (byId[id] != null) byId[id]!
    ];
    if (selected.isEmpty) return;

    var source = _ExamSource.original;
    var paperSize = ExamPaperSize.sixteenK;
    var includeAnswers = true;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('试卷设置',
                        style: TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 14),
                    _optionGroup(
                      '题目来源',
                      <Widget>[
                        _choiceRow(
                          '错题原题',
                          '以首次解析的结构化文本排版，公式与图形按原样重绘（不嵌入拍照原图）',
                          source == _ExamSource.original,
                          () => setSheetState(() => source = _ExamSource.original),
                        ),
                        _choiceRow(
                          'AI 变式新题',
                          '根据每道错题举一反三生成新题（较慢）',
                          source == _ExamSource.variant,
                          () => setSheetState(() => source = _ExamSource.variant),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _optionGroup(
                      '纸张大小',
                      <Widget>[
                        _choiceRow(
                          '16 开（184×260mm）标准版',
                          '单栏排版，适合普通练习本打印',
                          paperSize == ExamPaperSize.sixteenK,
                          () => setSheetState(
                              () => paperSize = ExamPaperSize.sixteenK),
                        ),
                        _choiceRow(
                          '8 开（260×368mm）大字版',
                          '单栏大字号，适合低年级或放大打印',
                          paperSize == ExamPaperSize.eightK,
                          () => setSheetState(
                              () => paperSize = ExamPaperSize.eightK),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('附参考答案页'),
                      subtitle: const Text('在试卷末尾单独一页列出答案与解析',
                          style: TextStyle(fontSize: 12)),
                      value: includeAnswers,
                      onChanged: (value) =>
                          setSheetState(() => includeAnswers = value),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(sheetContext, true),
                        child: Text(
                            '生成（${selected.length}题${source == _ExamSource.variant ? '·AI生成中请耐心等待' : ''}）'),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (confirmed != true || !mounted) return;
    await _generate(selected, source, paperSize, includeAnswers);
  }

  Widget _optionGroup(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        ...children,
      ],
    );
  }

  Widget _choiceRow(
      String title, String subtitle, bool selected, VoidCallback onTap) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? colorScheme.primary : colorScheme.outlineVariant,
            width: selected ? 1.6 : 1,
          ),
          color: selected
              ? colorScheme.primary.withValues(alpha: 0.06)
              : null,
        ),
        child: Row(
          children: <Widget>[
            Icon(
              selected
                  ? CupertinoIcons.checkmark_circle_fill
                  : CupertinoIcons.circle,
              size: 18,
              color: selected ? colorScheme.primary : colorScheme.outline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: const TextStyle(fontSize: 14)),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _stemOf(QuestionRecord question) {
    final corrected = question.correctedText.trim();
    if (corrected.isNotEmpty) return corrected;
    final normalized = question.normalizedQuestionText.trim();
    if (normalized.isNotEmpty) return normalized;
    return question.extractedQuestionText.trim();
  }

  Future<void> _generate(
    List<QuestionRecord> selected,
    _ExamSource source,
    ExamPaperSize paperSize,
    bool includeAnswers,
  ) async {
    final overlay = Overlay.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    setState(() => _generating = true);
    final subjects = selected.map((q) => q.subject).toSet();
    final subjectLabel = subjects.length == 1 ? subjects.first.label : '综合';
    final now = DateTime.now();
    final title =
        '$subjectLabel错题练习卷（${now.year}.${now.month}.${now.day}）';

    try {
      _showProgressDialog(overlay, '准备生成…');
      final stems = <String>[];
      final answers = <String?>[];
      final explanations = <String?>[];
      String? warning;

      if (source == _ExamSource.variant) {
        final service = ref.read(aiAnalysisServiceProvider);
        var done = 0;
        var failedCount = 0;
        for (final question in selected) {
          List<GeneratedExercise> exercises;
          try {
            exercises = await service.generateExercisesForQuestion(question);
          } catch (_) {
            exercises = const <GeneratedExercise>[];
          }
          if (exercises.isEmpty) {
            failedCount++;
            stems.add(_stemOf(question));
            answers.add(question.analysisResult?.finalAnswer);
            explanations.add(null);
          } else {
            final exercise = exercises.first;
            stems.add(exercise.question);
            answers.add(exercise.answer);
            explanations.add(exercise.explanation);
          }
          done++;
          _updateProgressDialog(done, selected.length);
        }
        if (failedCount > 0) {
          warning = '有 $failedCount 题生成变式失败，已用原题代替。';
        }
      } else {
        for (final question in selected) {
          stems.add(_stemOf(question));
          answers.add(question.analysisResult?.finalAnswer);
          explanations.add(question.analysisResult?.finalAnswerDerivation);
        }
      }

      // 结构化文本 → 高保真位图块（公式/图形/表格），与首次解析一致。
      var stemBlocks = <List<ExamRenderBlock>>[
        for (var i = 0; i < stems.length; i++) const <ExamRenderBlock>[],
      ];
      var answerBlocks = stemBlocks;
      var explanationBlocks = stemBlocks;
      try {
        final rasterizer = ExamContentRasterizer();
        final widthPt = ExamPaperPdfService.contentWidthFor(paperSize);
        final fontSize = ExamPaperPdfService.baseFontSizeFor(paperSize);
        final renderTargets = <String>[
          ...stems,
          for (final answer in answers)
            if (answer != null && answer.trim().isNotEmpty) answer,
          for (final explanation in explanations)
            if (explanation != null && explanation.trim().isNotEmpty)
              explanation,
        ];
        var rendered = 0;
        Future<List<List<ExamRenderBlock>>> renderPass(
          List<String> contents,
        ) {
          final nonEmpty =
              contents.where((c) => c.trim().isNotEmpty).length;
          return rasterizer
              .rasterizeAll(
                overlay: overlay,
                contents: contents,
                widthPt: widthPt,
                fontSize: fontSize,
                onProgress: (done, total) {
                  _progressNotifier.value =
                      '正在渲染题目内容 ${rendered + done}/${renderTargets.length}…';
                },
              )
              .whenComplete(() => rendered += nonEmpty);
        }

        stemBlocks = await renderPass(stems);
        answerBlocks = await renderPass(<String>[
          for (final answer in answers) answer ?? '',
        ]);
        explanationBlocks = await renderPass(<String>[
          for (final explanation in explanations) explanation ?? '',
        ]);
        final fallbackCount = stems
            .asMap()
            .entries
            .where((e) =>
                e.value.trim().isNotEmpty && stemBlocks[e.key].isEmpty)
            .length;
        if (fallbackCount > 0) {
          warning = '有 $fallbackCount 题内容渲染失败，已按纯文本排版。';
        }
      } catch (_) {
        warning = '内容渲染失败，已按纯文本排版。';
      }

      final entries = <ExamPaperEntry>[
        for (var i = 0; i < stems.length; i++)
          ExamPaperEntry(
            stem: stems[i],
            answer: answers[i],
            explanation: explanations[i],
            stemBlocks: stemBlocks[i],
            answerBlocks: answerBlocks[i],
            explanationBlocks: explanationBlocks[i],
          ),
      ];

      _progressNotifier.value = '正在排版生成 PDF…';
      final pdfService = ExamPaperPdfService();
      final result = await pdfService.build(
        title: title,
        entries: entries,
        paperSize: paperSize,
        includeAnswers: includeAnswers,
      );
      _closeProgressDialog();

      final dir = await getTemporaryDirectory();
      final safeTitle = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '-');
      final file = File('${dir.path}/$safeTitle.pdf');
      await file.writeAsBytes(result.bytes, flush: true);

      if (warning != null) {
        scaffoldMessenger.showSnackBar(SnackBar(content: Text(warning)));
      }
      await Share.shareXFiles(
        <XFile>[XFile(file.path, mimeType: 'application/pdf')],
        subject: title,
        text: '分享试卷：$title',
      );
    } catch (error) {
      _closeProgressDialog();
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('生成试卷失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  OverlayEntry? _progressOverlay;
  final ValueNotifier<String> _progressNotifier = ValueNotifier<String>('');

  void _showProgressDialog(OverlayState overlay, String text) {
    _progressNotifier.value = text;
    _progressOverlay ??= OverlayEntry(
      builder: (context) {
        return PopScope(
          canPop: false,
          child: ColoredBox(
            color: Colors.black38,
            child: Center(
              child: Material(
                borderRadius: BorderRadius.circular(14),
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: ValueListenableBuilder<String>(
                    valueListenable: _progressNotifier,
                    builder: (context, value, _) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          const CircularProgressIndicator(),
                          const SizedBox(height: 14),
                          Text(value.isEmpty ? '处理中…' : value,
                              style: const TextStyle(fontSize: 14)),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(_progressOverlay!);
  }

  void _updateProgressDialog(int done, int total) {
    _progressNotifier.value = 'AI 正在生成变式题 $done/$total…';
  }

  void _closeProgressDialog() {
    _progressOverlay?.remove();
    _progressOverlay = null;
  }

  @override
  void dispose() {
    _closeProgressDialog();
    _progressNotifier.dispose();
    super.dispose();
  }
}

class _QuestionPickCard extends StatelessWidget {
  const _QuestionPickCard({
    required this.question,
    required this.selected,
    required this.onToggle,
  });

  final QuestionRecord question;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final stem = [
      question.correctedText.trim(),
      question.normalizedQuestionText.trim(),
      question.extractedQuestionText.trim()
    ].firstWhere((text) => text.isNotEmpty, orElse: () => '（无文本题干）');

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? colorScheme.primary : colorScheme.outlineVariant,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                selected
                    ? CupertinoIcons.checkmark_circle_fill
                    : CupertinoIcons.circle,
                size: 20,
                color: selected ? colorScheme.primary : colorScheme.outline,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MathContentView(
                      stem,
                      mode: MathContentViewMode.compact,
                      maxLines: 2,
                      style: TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: colorScheme.onSurface),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Text(question.subject.label,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: question.subject.color)),
                        if (question.analysisResult == null)
                          Text('未解析',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  color: colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
