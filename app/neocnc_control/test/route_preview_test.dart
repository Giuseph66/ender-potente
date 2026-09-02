import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/drawing/application/route_preview.dart';

void main() {
  test('separa o que é desenho do que é deslocamento entre traços', () {
    final preview = RoutePreview.fromStrokes(
      const [
        [ui.Offset(0, 0), ui.Offset(10, 0)],
        [ui.Offset(10, 10), ui.Offset(20, 10)],
      ],
    );

    expect(preview.strokeCount, 2);
    expect(preview.drawLength, closeTo(20, .001));
    // Um pulo de (10,0) até (10,10) com a caneta levantada.
    expect(preview.travelLength, closeTo(10, .001));
    expect(preview.penLifts, 1);
    expect(preview.moves.where((move) => !move.drawing), hasLength(1));
  });

  test('conta o deslocamento inicial a partir da posição da ferramenta', () {
    final preview = RoutePreview.fromStrokes(
      const [
        [ui.Offset(10, 0), ui.Offset(20, 0)],
      ],
      origin: ui.Offset.zero,
    );

    expect(preview.travelLength, closeTo(10, .001));
    expect(preview.moves.first.drawing, isFalse);
    expect(preview.moves.first.from, const ui.Offset(0, 0));
  });

  test('ignora traços com menos de dois pontos', () {
    final preview = RoutePreview.fromStrokes(
      const [
        [ui.Offset(0, 0)],
        [ui.Offset(0, 0), ui.Offset(5, 0)],
      ],
    );

    expect(preview.strokeCount, 1);
    expect(preview.penLifts, 0);
    expect(preview.drawLength, closeTo(5, .001));
  });

  test('amostra a posição ao longo do percurso', () {
    final preview = RoutePreview.fromStrokes(
      const [
        [ui.Offset(0, 0), ui.Offset(10, 0)],
        [ui.Offset(10, 10), ui.Offset(20, 10)],
      ],
    );

    expect(preview.sampleAt(0).position, const ui.Offset(0, 0));
    expect(preview.sampleAt(5).position, const ui.Offset(5, 0));
    expect(preview.sampleAt(5).drawing, isTrue);
    // Dentro do pulo entre os dois traços.
    expect(preview.sampleAt(15).position, const ui.Offset(10, 5));
    expect(preview.sampleAt(15).drawing, isFalse);
    // Além do fim fica no último ponto.
    expect(preview.sampleAt(9999).position, const ui.Offset(20, 10));
  });

  test('estima a duração somando percurso e subidas de caneta', () {
    final preview = RoutePreview.fromStrokes(
      const [
        [ui.Offset(0, 0), ui.Offset(40, 0)],
        [ui.Offset(40, 40), ui.Offset(80, 40)],
      ],
    );

    // 80 mm desenhando + 40 mm de pulo, a 40 mm/s = 3 s.
    // Z: 5 mm x 2 x (1 subida + 1) = 20 mm a 20 mm/s = 1 s.
    final estimate = preview.estimate(
      feedrateMmPerSecond: 40,
      penLiftMm: 5,
    );

    expect(estimate.inMilliseconds, closeTo(4000, 50));
  });

  test('rota vazia não estima tempo', () {
    final preview = RoutePreview.fromStrokes(const []);

    expect(preview.isEmpty, isTrue);
    expect(
      preview.estimate(feedrateMmPerSecond: 40, penLiftMm: 5),
      Duration.zero,
    );
  });
}
