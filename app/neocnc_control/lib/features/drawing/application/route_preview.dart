import 'dart:math' as math;
import 'dart:ui' as ui;

/// Um trecho do percurso da ferramenta: ou desenhando (caneta baixa) ou
/// apenas se deslocando entre traços (caneta levantada).
class RouteMove {
  const RouteMove({
    required this.from,
    required this.to,
    required this.drawing,
  });

  final ui.Offset from;
  final ui.Offset to;
  final bool drawing;

  double get length => (to - from).distance;
}

/// O percurso completo que a máquina vai fazer para uma rota, na ordem em que
/// vai fazer: serve para prever por onde a ferramenta passa antes de gastar
/// caneta e material.
class RoutePreview {
  RoutePreview._({
    required this.moves,
    required this.drawLength,
    required this.travelLength,
    required this.strokeCount,
  });

  /// Monta o percurso a partir dos traços, na ordem em que serão enviados.
  /// [origin] é onde a ferramenta está antes de começar (o primeiro
  /// deslocamento sai de lá).
  factory RoutePreview.fromStrokes(
    List<List<ui.Offset>> strokes, {
    ui.Offset? origin,
  }) {
    final moves = <RouteMove>[];
    var drawLength = 0.0;
    var travelLength = 0.0;
    var strokeCount = 0;
    var position = origin;

    for (final stroke in strokes) {
      if (stroke.length < 2) {
        continue;
      }
      strokeCount++;
      if (position != null && position != stroke.first) {
        final move = RouteMove(
          from: position,
          to: stroke.first,
          drawing: false,
        );
        moves.add(move);
        travelLength += move.length;
      }
      for (var i = 0; i + 1 < stroke.length; i++) {
        final move = RouteMove(
          from: stroke[i],
          to: stroke[i + 1],
          drawing: true,
        );
        moves.add(move);
        drawLength += move.length;
      }
      position = stroke.last;
    }

    return RoutePreview._(
      moves: List<RouteMove>.unmodifiable(moves),
      drawLength: drawLength,
      travelLength: travelLength,
      strokeCount: strokeCount,
    );
  }

  final List<RouteMove> moves;

  /// Milímetros com a caneta baixa (o desenho em si).
  final double drawLength;

  /// Milímetros com a caneta levantada (os pulos entre traços).
  final double travelLength;

  final int strokeCount;

  double get totalLength => drawLength + travelLength;

  bool get isEmpty => moves.isEmpty;

  /// Quantas vezes a caneta sobe e desce: uma por traço, fora o primeiro
  /// posicionamento.
  int get penLifts => math.max(0, strokeCount - 1);

  /// Estimativa de duração: percurso no avanço configurado, mais as subidas e
  /// descidas em Z. Ignora aceleração, então é um piso, não uma promessa.
  Duration estimate({
    required double feedrateMmPerSecond,
    required double penLiftMm,
    double zFeedrateMmPerSecond = 20,
  }) {
    if (feedrateMmPerSecond <= 0 || isEmpty) {
      return Duration.zero;
    }
    final planar = totalLength / feedrateMmPerSecond;
    final zSpeed = zFeedrateMmPerSecond <= 0 ? 20.0 : zFeedrateMmPerSecond;
    // Sobe e desce a cada traço, mais a descida inicial e a subida final.
    final zTravel = penLiftMm * 2 * (penLifts + 1);
    return Duration(
      milliseconds: ((planar + zTravel / zSpeed) * 1000).round(),
    );
  }

  /// Posição da ferramenta depois de percorrer [distance] milímetros do
  /// percurso, e se nesse ponto ela está desenhando.
  ({ui.Offset position, bool drawing}) sampleAt(double distance) {
    if (isEmpty) {
      return (position: ui.Offset.zero, drawing: false);
    }
    var remaining = distance.clamp(0.0, totalLength).toDouble();
    for (final move in moves) {
      final length = move.length;
      if (length <= 0) {
        continue;
      }
      if (remaining <= length) {
        final t = remaining / length;
        return (
          position: ui.Offset.lerp(move.from, move.to, t)!,
          drawing: move.drawing,
        );
      }
      remaining -= length;
    }
    return (position: moves.last.to, drawing: moves.last.drawing);
  }
}
