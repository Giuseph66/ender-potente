import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/drawing/application/route_optimizer.dart';

void main() {
  test('reordena traços fora de ordem e encurta o deslocamento', () {
    // Quatro traços em fila, embaralhados: na ordem dada a caneta vai e volta.
    const strokes = [
      [ui.Offset(0, 0), ui.Offset(10, 0)],
      [ui.Offset(60, 0), ui.Offset(70, 0)],
      [ui.Offset(20, 0), ui.Offset(30, 0)],
      [ui.Offset(40, 0), ui.Offset(50, 0)],
    ];

    final before = RouteOptimizer.travelLength(strokes);
    final optimized = RouteOptimizer.optimize(strokes);
    final after = RouteOptimizer.travelLength(optimized);

    expect(after, lessThan(before));
    // Em fila, o deslocamento ideal é 10 mm entre cada par: 30 mm no total.
    expect(after, closeTo(30, .001));
    expect(optimized, hasLength(strokes.length));
  });

  test('inverte um traço quando entrar pela outra ponta é mais perto', () {
    const strokes = [
      [ui.Offset(0, 0), ui.Offset(10, 0)],
      // Este está "de costas": sua ponta final é a mais próxima.
      [ui.Offset(30, 0), ui.Offset(11, 0)],
    ];

    final optimized = RouteOptimizer.optimize(strokes);

    expect(RouteOptimizer.travelLength(optimized), closeTo(1, .001));
    expect(optimized.last.first, const ui.Offset(11, 0));
    expect(optimized.last.last, const ui.Offset(30, 0));
  });

  test('respeita a posição inicial da ferramenta', () {
    const strokes = [
      [ui.Offset(100, 0), ui.Offset(110, 0)],
      [ui.Offset(5, 0), ui.Offset(15, 0)],
    ];

    final optimized = RouteOptimizer.optimize(
      strokes,
      origin: ui.Offset.zero,
    );

    // Começa pelo traço perto da origem.
    expect(optimized.first.first, const ui.Offset(5, 0));
  });

  test('preserva todos os pontos de cada traço', () {
    const strokes = [
      [ui.Offset(0, 0), ui.Offset(5, 5), ui.Offset(10, 0)],
      [ui.Offset(40, 0), ui.Offset(45, 5), ui.Offset(50, 0)],
    ];

    final optimized = RouteOptimizer.optimize(strokes);

    expect(optimized.expand((stroke) => stroke).length, 6);
    for (final stroke in optimized) {
      expect(stroke, hasLength(3));
    }
  });

  test('não quebra com rota vazia ou de um traço só', () {
    expect(RouteOptimizer.optimize(const []), isEmpty);
    const single = [
      [ui.Offset(0, 0), ui.Offset(1, 1)],
    ];
    expect(RouteOptimizer.optimize(single), hasLength(1));
  });

  test('encurta bastante um caso espalhado e embaralhado', () {
    // Grade 6x6 de traços curtos, em ordem pseudo-aleatória.
    final random = math.Random(7);
    final strokes = <List<ui.Offset>>[];
    for (var y = 0; y < 6; y++) {
      for (var x = 0; x < 6; x++) {
        strokes.add([
          ui.Offset(x * 20, y * 20),
          ui.Offset(x * 20 + 8, y * 20),
        ]);
      }
    }
    strokes.shuffle(random);

    final before = RouteOptimizer.travelLength(strokes);
    final after = RouteOptimizer.travelLength(
      RouteOptimizer.optimize(strokes),
    );

    expect(after, lessThan(before * .35));
  });
}
