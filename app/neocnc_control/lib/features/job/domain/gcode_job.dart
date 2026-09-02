import 'dart:math' as math;
import 'dart:ui' as ui;

/// Perfil físico espelhado no firmware Marlin instalado na máquina.
class MachineLimits {
  const MachineLimits({
    required this.label,
    this.maxX = 220,
    this.maxY = 220,
    this.maxZ = 250,
  });

  final String label;
  final double maxX;
  final double maxY;
  final double maxZ;

  static const ender3_220 = MachineLimits(label: '220 × 220 mm');
  static const ender3_235 = MachineLimits(
    label: '235 × 235 mm',
    maxX: 235,
    maxY: 235,
  );
  static const profiles = <MachineLimits>[ender3_220, ender3_235];

  /// Perfil seguro padrão do NeoCNC 0.0.5.
  static const MachineLimits neoCnc = ender3_220;
}

enum GcodeMoveKind {
  /// `G0` — deslocamento rápido, fresa fora do material.
  rapid,

  /// `G1`/`G2`/`G3` — movimento com avanço programado.
  feed,
}

class GcodeBounds {
  const GcodeBounds({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.minZ,
    required this.maxZ,
  });

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
  final double minZ;
  final double maxZ;

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get depth => maxZ - minZ;

  bool get isEmpty => minX > maxX;

  static const GcodeBounds empty = GcodeBounds(
    minX: double.infinity,
    maxX: double.negativeInfinity,
    minY: double.infinity,
    maxY: double.negativeInfinity,
    minZ: double.infinity,
    maxZ: double.negativeInfinity,
  );
}

/// Um comando já normalizado: código (`G1`, `M3`, `T2`) e suas palavras.
class GcodeCommand {
  const GcodeCommand(this.code, this.words);

  final String code;
  final Map<String, double> words;

  GcodeCommand withWords(Map<String, double> replacements) =>
      GcodeCommand(code, {...words, ...replacements});

  String render() {
    final parts = <String>[
      if (code.isNotEmpty) code,
      for (final entry in words.entries)
        '${entry.key}${formatNumber(entry.value)}',
    ];
    return parts.join(' ');
  }

  static String formatNumber(double value) {
    if (value == value.roundToDouble() && value.abs() < 1e9) {
      return value.toInt().toString();
    }
    return value
        .toStringAsFixed(4)
        .replaceFirstMapped(RegExp(r'(\.\d*?)0+$'), (match) => match.group(1)!)
        .replaceFirst(RegExp(r'\.$'), '');
  }

  @override
  String toString() => render();
}

class GcodeJob {
  const GcodeJob({
    required this.name,
    required this.commands,
    required this.bounds,
    required this.cutPaths,
    required this.travelPaths,
    required this.cutLengthMm,
    required this.travelLengthMm,
    required this.estimatedDuration,
    required this.tools,
    required this.usesSpindle,
    required this.warnings,
    required this.blockingIssues,
    required this.byteSize,
  });

  final String name;
  final List<GcodeCommand> commands;
  final GcodeBounds bounds;

  /// Polilinhas em XY para desenho: trajetos com avanço (corte).
  final List<List<ui.Offset>> cutPaths;

  /// Polilinhas em XY dos deslocamentos rápidos.
  final List<List<ui.Offset>> travelPaths;

  final double cutLengthMm;
  final double travelLengthMm;
  final Duration estimatedDuration;
  final Set<int> tools;
  final bool usesSpindle;
  final List<String> warnings;

  /// Instruções cuja geometria ou efeito não pôde ser comprovado pelo app.
  /// Um trabalho com bloqueios nunca pode ser enviado ao cartão.
  final List<String> blockingIssues;
  final int byteSize;

  int get commandCount => commands.length;

  /// Nome 8.3 em maiúsculas aceito pelo `M23` do Marlin.
  static String toShortFilename(String source, {String extension = 'GCO'}) {
    final base = source
        .split(RegExp(r'[\\/]'))
        .last
        .split('.')
        .first
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final stem = base.isEmpty
        ? 'JOB'
        : base.substring(0, math.min(8, base.length));
    return '$stem.$extension';
  }

  /// Aponta o que impede o trabalho de rodar como está.
  List<String> violationsFor(MachineLimits limits) {
    final problems = <String>[...blockingIssues];
    if (bounds.isEmpty) {
      problems.add('O arquivo não contém nenhum movimento.');
      return problems;
    }
    if (bounds.minX < 0 || bounds.minY < 0) {
      problems.add(
        'O trabalho tem coordenadas negativas em XY '
        '(X mín ${bounds.minX.toStringAsFixed(2)}, '
        'Y mín ${bounds.minY.toStringAsFixed(2)}). '
        'Reposicione a origem antes de enviar.',
      );
    }
    if (bounds.maxX > limits.maxX || bounds.maxY > limits.maxY) {
      problems.add(
        'O trabalho ultrapassa a mesa: precisa de '
        '${bounds.maxX.toStringAsFixed(1)} × '
        '${bounds.maxY.toStringAsFixed(1)} mm, '
        'limite ${limits.maxX.toStringAsFixed(0)} × '
        '${limits.maxY.toStringAsFixed(0)} mm.',
      );
    }
    if (bounds.minZ < 0) {
      problems.add(
        'O trabalho mergulha até Z ${bounds.minZ.toStringAsFixed(3)} mm. '
        'O firmware recusa Z negativo: aplique o deslocamento de Z para levar '
        'o plano de corte à altura real da placa.',
      );
    }
    if (bounds.maxZ > limits.maxZ) {
      problems.add(
        'O trabalho sobe até Z ${bounds.maxZ.toStringAsFixed(1)} mm, '
        'acima do curso de ${limits.maxZ.toStringAsFixed(0)} mm.',
      );
    }
    return problems;
  }
}
