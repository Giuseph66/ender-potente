import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/drawing/application/plot_importer.dart';

void main() {
  test('converte caminhos e formas SVG em uma rota dentro da mesa', () {
    final result = PlotImporter.fromSvg('''
        <svg viewBox="0 0 100 80">
          <path d="M 0 0 L 100 0 L 100 80 Z" />
          <circle cx="50" cy="40" r="12" />
        </svg>
      ''', label: 'teste.svg');

    expect(result.strokes, hasLength(2));
    expect(result.segmentCount, greaterThan(6));
    for (final stroke in result.strokes) {
      for (final point in stroke) {
        expect(point.dx, inInclusiveRange(10.0, 210.0));
        expect(point.dy, inInclusiveRange(10.0, 210.0));
      }
    }
  });

  test('redimensiona uma rota importada e a mantém centralizada', () {
    final source = PlotImporter.fromSvg('''
        <svg viewBox="0 0 100 80">
          <path d="M 0 0 L 100 0 L 100 80 Z" />
        </svg>
      ''', label: 'teste.svg');

    final resized = PlotImporter.resizeAndCenter(
      source.strokes,
      width: 80,
      height: 64,
    );
    final dimensions = PlotImporter.measure(resized);

    expect(dimensions.width, closeTo(80, .001));
    expect(dimensions.height, closeTo(64, .001));
    for (final stroke in resized) {
      for (final point in stroke) {
        expect(point.dx, inInclusiveRange(70.0, 150.0));
        expect(point.dy, inInclusiveRange(78.0, 142.0));
      }
    }
  });

  test('extrai o contorno de uma área preta da imagem', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder)
      ..drawColor(const ui.Color(0xFFFFFFFF), ui.BlendMode.src)
      ..drawRect(
        const ui.Rect.fromLTWH(8, 8, 16, 16),
        ui.Paint()..color = const ui.Color(0xFF000000),
      );
    final image = await recorder.endRecording().toImage(32, 32);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();

    final result = await PlotImporter.fromMonochromeImage(
      data!.buffer.asUint8List(),
      label: 'quadrado.png',
      threshold: .5,
    );

    expect(result.strokes, isNotEmpty);
    expect(result.segmentCount, greaterThanOrEqualTo(4));
  });
}
