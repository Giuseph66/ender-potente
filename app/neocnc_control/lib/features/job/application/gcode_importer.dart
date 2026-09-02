import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../domain/gcode_job.dart';

/// Lê `.nc`/`.gcode` de FlatCAM, pcb2gcode ou qualquer CAM e o normaliza para
/// o dialeto que o Marlin da NeoCNC executa a partir do cartão.
///
/// A normalização é o ponto do importador: o arquivo sai daqui sempre em
/// milímetros, sempre em coordenadas absolutas e com o plano de corte deslocado
/// para a altura real da placa. É isso que permite validar o envelope antes de
/// gastar uma broca.
abstract final class GcodeImporter {
  /// Avanço assumido para `G0` quando o arquivo nunca declarou um `F`.
  static const double defaultRapidFeedMmPerMinute = 3000;

  /// `DEFAULT_MAX_FEEDRATE` do firmware: {500, 500, 10} mm/s.
  static const double maxXyFeedMmPerMinute = 500 * 60;
  static const double maxZFeedMmPerMinute = 10 * 60;

  /// Tolerância de corda ao achatar arcos `G2`/`G3` para o preview.
  static const double _arcChordToleranceMm = .02;

  static final RegExp _wordPattern = RegExp(
    r'([A-Za-z])\s*([+-]?(?:\d+\.?\d*|\.\d+))',
  );

  static GcodeJob parse(
    String source, {
    required String name,
    double zOffsetMm = 0,
    MachineLimits limits = MachineLimits.neoCnc,
  }) {
    final commands = <GcodeCommand>[];
    final warnings = <String>{};
    final blockingIssues = <String>{};
    final tools = <int>{};
    final cutPaths = <List<ui.Offset>>[];
    final travelPaths = <List<ui.Offset>>[];

    var absolute = true;
    var inches = false;
    var usedInches = false;
    var usedRelative = false;
    var usesSpindle = false;

    var x = .0;
    var y = .0;
    var z = .0;
    var feed = .0;

    var minX = double.infinity;
    var maxX = double.negativeInfinity;
    var minY = double.infinity;
    var maxY = double.negativeInfinity;
    var minZ = double.infinity;
    var maxZ = double.negativeInfinity;

    var cutLength = .0;
    var travelLength = .0;
    var seconds = .0;

    // Antes do primeiro X/Y programado a máquina está numa posição que o
    // arquivo não declara; incluí-la no envelope inventaria um canto em (0,0).
    var hasXy = false;
    var hasZ = false;

    List<ui.Offset>? currentCut;
    List<ui.Offset>? currentTravel;

    void trackXy(double px, double py) {
      if (!hasXy) {
        return;
      }
      minX = math.min(minX, px);
      maxX = math.max(maxX, px);
      minY = math.min(minY, py);
      maxY = math.max(maxY, py);
    }

    void trackZ(double pz) {
      if (!hasZ) {
        return;
      }
      minZ = math.min(minZ, pz);
      maxZ = math.max(maxZ, pz);
    }

    void closePaths() {
      if (currentCut != null && currentCut!.length >= 2) {
        cutPaths.add(currentCut!);
      }
      currentCut = null;
      if (currentTravel != null && currentTravel!.length >= 2) {
        travelPaths.add(currentTravel!);
      }
      currentTravel = null;
    }

    void appendPreview(GcodeMoveKind kind, ui.Offset from, ui.Offset to) {
      if (kind == GcodeMoveKind.feed) {
        if (currentTravel != null) {
          if (currentTravel!.length >= 2) {
            travelPaths.add(currentTravel!);
          }
          currentTravel = null;
        }
        (currentCut ??= <ui.Offset>[from]).add(to);
      } else {
        if (currentCut != null) {
          if (currentCut!.length >= 2) {
            cutPaths.add(currentCut!);
          }
          currentCut = null;
        }
        (currentTravel ??= <ui.Offset>[from]).add(to);
      }
    }

    for (final rawLine in LineSplitter.split(source)) {
      for (final command in _splitCommands(rawLine)) {
        final code = command.code;
        final words = command.words;
        final scale = inches ? 25.4 : 1.0;

        switch (code) {
          case 'G20':
            inches = true;
            usedInches = true;
            continue;
          case 'G21':
            inches = false;
            continue;
          case 'G90':
            absolute = true;
            continue;
          case 'G91':
            absolute = false;
            usedRelative = true;
            continue;
          case 'G92':
            blockingIssues.add(
              'G92 redefine a origem e invalida o preview. Remova-o ou gere '
              'o G-code em coordenadas absolutas antes de enviar.',
            );
            continue;
          case 'M3':
          case 'M4':
            usesSpindle = true;
            commands.add(command);
            continue;
          case 'M5':
            commands.add(command);
            continue;
          case 'M6':
            blockingIssues.add(
              'M6 pede troca de ferramenta. A NeoCNC não troca ferramenta '
              'automaticamente; separe o trabalho por ferramenta.',
            );
            continue;
        }

        if (code.startsWith('T')) {
          final tool = int.tryParse(code.substring(1));
          if (tool != null) {
            tools.add(tool);
          }
          commands.add(command);
          continue;
        }

        final isMotion =
            code == 'G0' || code == 'G1' || code == 'G2' || code == 'G3';
        if (!isMotion) {
          if (code.isEmpty) {
            blockingIssues.add(
              'Há uma linha modal sem G/M/T explícito. Ela pode mover a '
              'máquina sem entrar no preview.',
            );
          } else if (_unsafeNonMotion.contains(code)) {
            blockingIssues.add(
              '$code altera a origem ou move a máquina fora do envelope '
              'validado; remova esse comando do arquivo CAM.',
            );
          } else if (!_safeNonMotion.contains(code)) {
            blockingIssues.add(
              'Comando $code não é suportado pelo verificador e não será '
              'repassado à máquina.',
            );
          } else {
            commands.add(command);
          }
          continue;
        }

        final startX = x;
        final startY = y;
        final startZ = z;
        hasXy = hasXy || words.containsKey('X') || words.containsKey('Y');
        hasZ = hasZ || words.containsKey('Z');

        double resolve(double current, String letter) {
          final value = words[letter];
          if (value == null) {
            return current;
          }
          return absolute ? value * scale : current + value * scale;
        }

        x = resolve(x, 'X');
        y = resolve(y, 'Y');
        z = resolve(z, 'Z');
        if (words.containsKey('F')) {
          feed = words['F']! * scale;
        }

        final kind = code == 'G0' ? GcodeMoveKind.rapid : GcodeMoveKind.feed;
        final effectiveFeed = kind == GcodeMoveKind.rapid && feed <= 0
            ? defaultRapidFeedMmPerMinute
            : (feed > 0 ? feed : defaultRapidFeedMmPerMinute);

        final from = ui.Offset(startX, startY);
        final to = ui.Offset(x, y);

        double planarLength;
        if (code == 'G2' || code == 'G3') {
          final arc = _flattenArc(
            from: from,
            to: to,
            words: words,
            scale: scale,
            clockwise: code == 'G2',
          );
          if (arc == null) {
            warnings.add(
              'Arco $code sem I/J/R utilizável; tratado como linha reta no '
              'preview.',
            );
            planarLength = (to - from).distance;
            appendPreview(kind, from, to);
            trackXy(x, y);
          } else {
            planarLength = .0;
            var previous = from;
            for (final point in arc.skip(1)) {
              planarLength += (point - previous).distance;
              appendPreview(kind, previous, point);
              trackXy(point.dx, point.dy);
              previous = point;
            }
          }
        } else {
          planarLength = (to - from).distance;
          appendPreview(kind, from, to);
          trackXy(x, y);
        }
        trackZ(z + zOffsetMm);

        final travelZ = (z - startZ).abs();
        final length = math.sqrt(
          planarLength * planarLength + travelZ * travelZ,
        );
        if (kind == GcodeMoveKind.feed) {
          cutLength += length;
        } else {
          travelLength += length;
        }
        if (effectiveFeed > 0) {
          seconds += length / effectiveFeed * 60;
        }

        if (planarLength < 1e-9 && travelZ > 1e-9) {
          if (feed > maxZFeedMmPerMinute && kind == GcodeMoveKind.feed) {
            warnings.add(
              'Mergulho em Z a ${feed.toStringAsFixed(0)} mm/min; o firmware '
              'limita o eixo Z a ${maxZFeedMmPerMinute.toStringAsFixed(0)} '
              'mm/min e vai reduzir o avanço.',
            );
          }
        } else if (feed > maxXyFeedMmPerMinute) {
          warnings.add(
            'Avanço de ${feed.toStringAsFixed(0)} mm/min acima do máximo de '
            '${maxXyFeedMmPerMinute.toStringAsFixed(0)} mm/min em XY.',
          );
        }

        // Reemite sempre absoluto, em mm e com o Z já deslocado.
        commands.add(
          GcodeCommand(code, {
            if (words.containsKey('X') || x != startX) 'X': x,
            if (words.containsKey('Y') || y != startY) 'Y': y,
            if (words.containsKey('Z') || z != startZ) 'Z': z + zOffsetMm,
            if (code == 'G2' || code == 'G3') ...{
              if (words.containsKey('I')) 'I': words['I']! * scale,
              if (words.containsKey('J')) 'J': words['J']! * scale,
              if (words.containsKey('R')) 'R': words['R']! * scale,
            },
            if (words.containsKey('F')) 'F': feed,
          }),
        );
      }
    }

    closePaths();

    if (usedInches) {
      warnings.add('Arquivo em polegadas convertido para milímetros.');
    }
    if (usedRelative) {
      warnings.add(
        'Trechos em G91 (relativo) foram reescritos em coordenadas absolutas.',
      );
    }
    if (!usesSpindle) {
      warnings.add(
        'O arquivo não liga a ferramenta (sem M3/M4). Ligue a microrretífica '
        'antes de iniciar, ou gere o arquivo com controle de spindle.',
      );
    }
    if (tools.length > 1) {
      final message =
          'O arquivo usa ${tools.length} ferramentas (${tools.join(', ')}). '
          'A máquina não troca ferramenta sozinha: separe um arquivo por '
          'ferramenta.';
      warnings.add(message);
      blockingIssues.add(message);
    }

    final bounds = minX > maxX
        ? GcodeBounds.empty
        : GcodeBounds(
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY,
            minZ: hasZ ? minZ : 0,
            maxZ: hasZ ? maxZ : 0,
          );

    final rendered = render(commands, name: name);

    return GcodeJob(
      name: name,
      commands: List<GcodeCommand>.unmodifiable(commands),
      bounds: bounds,
      cutPaths: List<List<ui.Offset>>.unmodifiable(cutPaths),
      travelPaths: List<List<ui.Offset>>.unmodifiable(travelPaths),
      cutLengthMm: cutLength,
      travelLengthMm: travelLength,
      estimatedDuration: Duration(seconds: seconds.round()),
      tools: Set<int>.unmodifiable(tools),
      usesSpindle: usesSpindle,
      warnings: List<String>.unmodifiable(warnings),
      blockingIssues: List<String>.unmodifiable(blockingIssues),
      byteSize: rendered.length,
    );
  }

  /// Monta o arquivo final: cabeçalho com o estado modal fixado, os comandos
  /// normalizados e um encerramento que desliga a ferramenta.
  static String render(List<GcodeCommand> commands, {required String name}) {
    final buffer = StringBuffer()
      ..writeln('; NeoCNC job: $name')
      ..writeln('; gerado pelo NeoCNC Control')
      ..writeln('G21')
      ..writeln('G90');
    for (final command in commands) {
      final line = command.render();
      if (line.isNotEmpty) {
        buffer.writeln(line);
      }
    }
    buffer
      ..writeln('M5')
      ..writeln('M400');
    return buffer.toString();
  }

  /// Códigos sem movimento cuja semântica não altera os limites XY/Z.
  static const Set<String> _safeNonMotion = {
    'G4',
    'G17',
    'G18',
    'G19',
    'G94',
    'M0',
    'M1',
    'M2',
    'M7',
    'M8',
    'M9',
    'M30',
    'M400',
    'M117',
  };

  static const Set<String> _unsafeNonMotion = {
    'G28',
    'G53',
    'G54',
    'G55',
    'G56',
    'G57',
    'G58',
    'G59',
    'G64',
  };

  static Iterable<GcodeCommand> _splitCommands(String rawLine) sync* {
    final line = _stripComments(rawLine);
    if (line.trim().isEmpty) {
      return;
    }

    String? code;
    var words = <String, double>{};

    for (final match in _wordPattern.allMatches(line)) {
      final letter = match.group(1)!.toUpperCase();
      final value = double.tryParse(match.group(2)!);
      if (value == null) {
        continue;
      }

      if (letter == 'N' && code == null && words.isEmpty) {
        continue; // número de linha
      }

      if (letter == 'G' || letter == 'M' || letter == 'T') {
        if (code != null || words.isNotEmpty) {
          yield GcodeCommand(code ?? '', words);
          words = <String, double>{};
        }
        code = '$letter${value.toInt()}';
        continue;
      }
      words[letter] = value;
    }

    if (code != null || words.isNotEmpty) {
      yield GcodeCommand(code ?? '', words);
    }
  }

  static String _stripComments(String line) {
    final withoutParens = line.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    final semicolon = withoutParens.indexOf(';');
    final withoutSemicolon = semicolon >= 0
        ? withoutParens.substring(0, semicolon)
        : withoutParens;
    final percent = withoutSemicolon.trim();
    return percent == '%' ? '' : withoutSemicolon;
  }

  /// Achata um arco em polilinha. Devolve `null` quando o centro não pode ser
  /// determinado a partir de I/J ou R.
  static List<ui.Offset>? _flattenArc({
    required ui.Offset from,
    required ui.Offset to,
    required Map<String, double> words,
    required double scale,
    required bool clockwise,
  }) {
    ui.Offset? center;
    if (words.containsKey('I') || words.containsKey('J')) {
      center = ui.Offset(
        from.dx + (words['I'] ?? 0) * scale,
        from.dy + (words['J'] ?? 0) * scale,
      );
    } else if (words.containsKey('R')) {
      final radius = words['R']! * scale;
      final chord = to - from;
      final chordLength = chord.distance;
      if (chordLength < 1e-9 || radius.abs() * 2 < chordLength) {
        return null;
      }
      final middle = ui.Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
      final height = math.sqrt(
        math.max(0, radius * radius - chordLength * chordLength / 4),
      );
      final normal = ui.Offset(-chord.dy, chord.dx) / chordLength;
      final flip = (radius < 0) == clockwise ? 1.0 : -1.0;
      center = middle + normal * height * flip;
    }
    if (center == null) {
      return null;
    }

    final startAngle = math.atan2(from.dy - center.dy, from.dx - center.dx);
    var endAngle = math.atan2(to.dy - center.dy, to.dx - center.dx);
    final radius = (from - center).distance;
    if (radius < 1e-9) {
      return null;
    }

    if (clockwise) {
      while (endAngle >= startAngle) {
        endAngle -= 2 * math.pi;
      }
    } else {
      while (endAngle <= startAngle) {
        endAngle += 2 * math.pi;
      }
    }

    final sweep = (endAngle - startAngle).abs();
    final maxStep =
        2 *
        math.acos(math.max(-1, math.min(1, 1 - _arcChordToleranceMm / radius)));
    final steps = math.max(
      2,
      math.min(2000, (sweep / math.max(1e-3, maxStep)).ceil()),
    );

    final points = <ui.Offset>[from];
    for (var index = 1; index <= steps; index += 1) {
      final angle = startAngle + (endAngle - startAngle) * index / steps;
      points.add(
        ui.Offset(
          center.dx + radius * math.cos(angle),
          center.dy + radius * math.sin(angle),
        ),
      );
    }
    points[points.length - 1] = to;
    return points;
  }
}
