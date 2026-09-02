import 'dart:ui' as ui;

/// Reordena os traços de uma rota para encurtar o caminho com a caneta
/// levantada. A ordem em que um SVG guarda as formas não tem nada a ver com a
/// ordem em que convém desenhá-las: sem isso a caneta cruza a mesa à toa.
///
/// Um traço desenhado de trás para frente é o mesmo traço, então além de
/// reordenar também invertemos quando compensa.
abstract final class RouteOptimizer {
  /// Acima disso o refinamento 2-opt (quadrático por passada) sai caro demais
  /// para o ganho que traz; fica só a heurística gulosa.
  static const _maxStrokesFor2Opt = 2000;
  static const _maxPasses = 12;

  static List<List<ui.Offset>> optimize(
    List<List<ui.Offset>> strokes, {
    ui.Offset? origin,
  }) {
    final items = [
      for (final stroke in strokes)
        if (stroke.length >= 2) _Item(stroke),
    ];
    final ignored = [
      for (final stroke in strokes)
        if (stroke.length < 2) stroke,
    ];
    if (items.length < 2) {
      return List<List<ui.Offset>>.unmodifiable(strokes);
    }

    final order = _nearestNeighbour(items, origin);
    if (order.length <= _maxStrokesFor2Opt) {
      _twoOpt(order, origin);
    }

    return List<List<ui.Offset>>.unmodifiable([
      for (final item in order) item.points,
      ...ignored,
    ]);
  }

  /// Distância total com a caneta levantada de uma rota, na ordem dada.
  static double travelLength(
    List<List<ui.Offset>> strokes, {
    ui.Offset? origin,
  }) {
    var total = 0.0;
    var position = origin;
    for (final stroke in strokes) {
      if (stroke.length < 2) {
        continue;
      }
      if (position != null) {
        total += (stroke.first - position).distance;
      }
      position = stroke.last;
    }
    return total;
  }

  /// Sempre pula para a ponta mais próxima ainda não usada, entrando pelo lado
  /// que estiver mais perto.
  static List<_Item> _nearestNeighbour(List<_Item> items, ui.Offset? origin) {
    final remaining = List<_Item>.from(items);
    final order = <_Item>[];
    var position = origin;

    while (remaining.isNotEmpty) {
      var bestIndex = 0;
      var bestReversed = false;
      var bestDistance = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final item = remaining[i];
        if (position == null) {
          bestIndex = i;
          bestReversed = false;
          break;
        }
        final toStart = (item.points.first - position).distance;
        final toEnd = (item.points.last - position).distance;
        if (toStart < bestDistance) {
          bestDistance = toStart;
          bestIndex = i;
          bestReversed = false;
        }
        if (toEnd < bestDistance) {
          bestDistance = toEnd;
          bestIndex = i;
          bestReversed = true;
        }
      }
      final chosen = remaining.removeAt(bestIndex);
      if (bestReversed) {
        chosen.reverse();
      }
      order.add(chosen);
      position = chosen.end;
    }
    return order;
  }

  /// 2-opt: inverte trechos da ordem enquanto isso encurtar o deslocamento.
  /// Ao inverter um trecho, cada traço dele também vira de ponta-cabeça.
  static void _twoOpt(List<_Item> order, ui.Offset? origin) {
    var improved = true;
    var passes = 0;
    while (improved && passes < _maxPasses) {
      improved = false;
      passes++;
      for (var i = 0; i < order.length - 1; i++) {
        final previousEnd = i == 0 ? origin : order[i - 1].end;
        for (var j = i + 1; j < order.length; j++) {
          final next = j + 1 < order.length ? order[j + 1].start : null;

          var before = 0.0;
          var after = 0.0;
          if (previousEnd != null) {
            before += (order[i].start - previousEnd).distance;
            after += (order[j].end - previousEnd).distance;
          }
          if (next != null) {
            before += (next - order[j].end).distance;
            after += (next - order[i].start).distance;
          }
          if (after + 1e-9 >= before) {
            continue;
          }

          // Inverte o trecho e a orientação de cada traço nele.
          final segment = order.sublist(i, j + 1).reversed.toList();
          for (final item in segment) {
            item.reverse();
          }
          order.replaceRange(i, j + 1, segment);
          improved = true;
        }
      }
    }
  }
}

class _Item {
  _Item(this._points);

  List<ui.Offset> _points;

  List<ui.Offset> get points => _points;

  ui.Offset get start => _points.first;

  ui.Offset get end => _points.last;

  void reverse() {
    _points = _points.reversed.toList(growable: false);
  }
}
