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

  test('preserva transformações dos caminhos e grupos SVG', () {
    final result = PlotImporter.fromSvg('''
        <svg width="500" height="300">
          <g transform="translate(100, 40)">
            <path d="M 0 0 L 10 0" />
          </g>
          <path d="M 0 0 L 10 0" transform="translate(400, 200)" />
        </svg>
      ''', label: 'transformado.svg');

    expect(result.strokes, hasLength(2));
    expect(
      (result.strokes.first.first - result.strokes.last.first).distance,
      greaterThan(100),
    );
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

  test('rotaciona uma rota importada e a mantém dentro da mesa', () {
    const route = [
      [ui.Offset(0, 0), ui.Offset(100, 0), ui.Offset(100, 50)],
    ];

    final rotated = PlotImporter.resizeRotateAndCenter(
      route,
      width: 200,
      height: 100,
      rotationDegrees: 90,
    );
    final dimensions = PlotImporter.measure(rotated);

    expect(dimensions.width, closeTo(100, .001));
    expect(dimensions.height, closeTo(200, .001));
    for (final stroke in rotated) {
      for (final point in stroke) {
        expect(point.dx, inInclusiveRange(60.0, 160.0));
        expect(point.dy, inInclusiveRange(10.0, 210.0));
      }
    }
  });

  test('posiciona uma rota importada pelo centro definido', () {
    const route = [
      [ui.Offset(0, 0), ui.Offset(100, 0), ui.Offset(100, 50)],
    ];

    final positioned = PlotImporter.resizeRotateAndCenter(
      route,
      width: 80,
      height: 50,
      rotationDegrees: 0,
      center: ui.Offset(160, 60),
    );

    for (final stroke in positioned) {
      for (final point in stroke) {
        expect(point.dx, inInclusiveRange(120.0, 200.0));
        expect(point.dy, inInclusiveRange(35.0, 85.0));
      }
    }
  });

  test('modo centro reduz uma forma preenchida a uma linha central', () {
    final outline = PlotImporter.fromSvg('''
        <svg viewBox="0 0 200 20">
          <rect x="0" y="5" width="200" height="10" />
        </svg>
      ''', label: 'capsula.svg');
    final centerline = PlotImporter.fromSvg('''
        <svg viewBox="0 0 200 20">
          <rect x="0" y="5" width="200" height="10" />
        </svg>
      ''', label: 'capsula.svg', mode: SvgTraceMode.centerline);

    expect(centerline.strokes, isNotEmpty);
    final centerHeight = PlotImporter.measure(centerline.strokes).height;
    final outlineHeight = PlotImporter.measure(outline.strokes).height;
    expect(centerHeight, lessThan(outlineHeight));
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
