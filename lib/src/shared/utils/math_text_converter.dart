/// 把 AI 输出中的 LaTeX 转成可读 Unicode 文本，供 PDF 导出等
/// 不支持 LaTeX 渲染的场景使用。
class MathTextConverter {
  MathTextConverter._();

  static final _reBeginEnd = RegExp(r'\\?begin\{[^}]+\}|\\?end\{[^}]+\}');
  static final _reFrac = RegExp(r'\\frac\{([^}]*)\}\{([^}]*)\}');
  static final _reSqrt = RegExp(r'\\sqrt\{([^}]*)\}');
  static final _reMatrm = RegExp(r'\\mathrm\{([^}]*)\}');
  static final _reText = RegExp(r'\\text\{([^}]*)\}');
  static final _reCmd = RegExp(r'\\([a-zA-Z]+)(?=\b|[0-9])');
  static final _reNakedSymbols = RegExp(
      r'(?<![A-Za-z\\])(?:angle|triangle|circ|times|div|pm)(?=\b|[0-9])');
  static final _reSuperscript = RegExp(r'\^\{([^}]*)\}|\^([0-9])');
  static final _reSubscript = RegExp(r'_\{([^}]*)\}|_([0-9])');
  static final _reSpaces = RegExp(r'[ \t]+');

  static const _superscripts = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹',
    '+': '⁺', '-': '⁻', 'n': 'ⁿ', 'i': 'ⁱ',
  };

  static const _subscripts = {
    '0': '₀', '1': '₁', '2': '₂', '3': '₃', '4': '₄',
    '5': '₅', '6': '₆', '7': '₇', '8': '₈', '9': '₉',
  };

  static const _symbols = <String, String>{
    'angle': '∠', 'triangle': '△', 'circ': '°', 'pm': '±', 'mp': '∓',
    'times': '×', 'div': '÷', 'cdot': '·', 'leq': '≤', 'le': '≤',
    'geq': '≥', 'ge': '≥', 'neq': '≠', 'ne': '≠', 'approx': '≈',
    'equiv': '≡', 'sim': '∼', 'infty': '∞', 'perp': '⊥',
    'parallel': '∥', 'rightarrow': '→', 'leftarrow': '←',
    'Rightarrow': '⇒', 'Leftarrow': '⇐', 'to': '→',
    'therefore': '∴', 'because': '∵',
    'alpha': 'α', 'beta': 'β', 'gamma': 'γ', 'delta': 'δ',
    'epsilon': 'ε', 'varepsilon': 'ε', 'zeta': 'ζ', 'eta': 'η',
    'theta': 'θ', 'iota': 'ι', 'kappa': 'κ', 'lambda': 'λ',
    'mu': 'μ', 'nu': 'ν', 'xi': 'ξ', 'pi': 'π', 'rho': 'ρ',
    'sigma': 'σ', 'tau': 'τ', 'upsilon': 'υ', 'phi': 'φ',
    'varphi': 'ϕ', 'chi': 'χ', 'psi': 'ψ', 'omega': 'ω',
    'Gamma': 'Γ', 'Delta': 'Δ', 'Theta': 'Θ', 'Lambda': 'Λ',
    'Xi': 'Ξ', 'Pi': 'Π', 'Sigma': 'Σ', 'Upsilon': 'Υ',
    'Phi': 'Φ', 'Psi': 'Ψ', 'Omega': 'Ω',
    'in': '∈', 'notin': '∉', 'subset': '⊂', 'supset': '⊃',
    'cup': '∪', 'cap': '∩', 'emptyset': '∅',
    'degree': '°', 'sin': 'sin', 'cos': 'cos', 'tan': 'tan',
    'log': 'log', 'ln': 'ln', 'min': 'min', 'max': 'max',
  };

  /// 入口：LaTeX/混合文本 → 可读文本。
  static String toReadable(String value) {
    if (!value.contains('\\') && !value.contains('^') && !value.contains('_')) {
      return value.replaceAll(_reSpaces, ' ').trim();
    }
    var r = value;
    // 反斜杠双写（AI JSON 转义残留）先归一
    r = r.replaceAllMapped(RegExp(r'\\\\([a-zA-Z]+)'), (m) => '\\${m.group(1)}');
    r = r.replaceAllMapped(RegExp(r'\\\\(.)'), (m) => '\\${m.group(1)}');

    for (var i = 0; i < 3; i++) {
      // 嵌套分数最多展开三轮
      final next = r.replaceAllMapped(_reFrac, (m) {
        final a = _stripBraces(m.group(1)!);
        final b = _stripBraces(m.group(2)!);
        return '($a)/($b)';
      });
      if (next == r) break;
      r = next;
    }
    r = r.replaceAllMapped(_reSqrt, (m) => '√(${_stripBraces(m.group(1)!)})');
    r = r
        .replaceAllMapped(_reMatrm, (m) => m.group(1)!)
        .replaceAllMapped(_reText, (m) => m.group(1)!);
    r = r.replaceAllMapped(_reSuperscript, (m) {
      final body = (m.group(1) ?? m.group(2) ?? '').trim();
      return _toScript(body, _superscripts);
    });
    r = r.replaceAllMapped(_reSubscript, (m) {
      final body = (m.group(1) ?? m.group(2) ?? '').trim();
      return _toScript(body, _subscripts);
    });
    r = r
        .replaceAll(_reBeginEnd, '')
        .replaceAll(r'\newline', '\n')
        .replaceAll(r'\\', '\n')
        .replaceAll('&', '')
        .replaceAll(r'\left', '')
        .replaceAll(r'\right', '')
        .replaceAll(r'\cdot', '·')
        .replaceAll(r'\qquad', ' ')
        .replaceAll(r'\quad', ' ')
        .replaceAll(r'\{', '{')
        .replaceAll(r'\}', '}')
        .replaceAll(r'\$', '\$')
        .replaceAllMapped(_reCmd, (m) {
          final c = m.group(1)!;
          return _symbols[c] ?? c;
        })
        .replaceAllMapped(
            _reNakedSymbols, (m) => _symbols[m.group(0)!] ?? m.group(0)!)
        .replaceAll('\$', '')
        .replaceAll(_reSpaces, ' ')
        .trim();
    return r;
  }

  static String _stripBraces(String body) {
    var r = body.trim();
    while (r.startsWith('{') && r.endsWith('}')) {
      r = r.substring(1, r.length - 1).trim();
    }
    return r;
  }

  static String _toScript(String body, Map<String, String> table) {
    if (body.isEmpty) return '';
    final buffer = StringBuffer();
    var allMapped = true;
    for (final ch in body.split('')) {
      final mapped = table[ch];
      if (mapped == null) {
        allMapped = false;
        break;
      }
      buffer.write(mapped);
    }
    if (allMapped) return buffer.toString();
    // 无法整体映射（如 x^{10} 以外的复合内容）退化为括号形式
    return '^($body)';
  }
}
