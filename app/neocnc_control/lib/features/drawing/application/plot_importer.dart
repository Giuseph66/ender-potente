import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

class PlotDimensions {
  const PlotDimensions({required this.width, required this.height});

  final double width;
  final double height;
}

class PlotImportResult {
  const PlotImportResult({
    required this.label,
    required this.strokes,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final String label;
  final List<List<ui.Offset>> strokes;
  final int sourceWidth;
  final int sourceHeight;

  int get segmentCount => strokes.fold<int>(
    0,
    (total, stroke) => total + math.max(0, stroke.length - 1),
  );
}

abstract final class PlotImporter {
  static const _bedSize = 220.0;
  static const _margin = 10.0;
  static const _rasterWidth = 160;
  static const _maxSegments = 6000;

  static PlotDimensions measure(List<List<ui.Offset>> strokes) {
    final bounds = _boundsOf(strokes);
    return PlotDimensions(
      width: math.max(.1, bounds.width),
      height: math.max(.1, bounds.height),
    );
  }

  static List<List<ui.Offset>> resizeAndCenter(
    List<List<ui.Offset>> strokes, {
    required double width,
    required double height,
  }) => resizeRotateAndCenter(
    strokes,
    width: width,
    height: height,
    rotationDegrees: 0,
  );

  static List<List<ui.Offset>> resizeRotateAndCenter(
    List<List<ui.Offset>> strokes, {
    required double width,
    required double height,
    required double rotationDegrees,
    ui.Offset? center,
  }) {
    if (width <= 0 || height <= 0 || width > _bedSize || height > _bedSize) {
      throw ArgumentError('O tamanho da rota deve ficar entre 0 e 220 mm.');
    }
    if (!rotationDegrees.isFinite) {
      throw ArgumentError.value(
        rotationDegrees,
        'rotationDegrees',
        'A rotação deve ser um número válido.',
      );
    }
    final targetCenter = center ?? const ui.Offset(110, 110);
    if (!targetCenter.dx.isFinite || !targetCenter.dy.isFinite) {
      throw ArgumentError.value(
        center,
        'center',
        'A posição deve ter coordenadas válidas.',
      );
    }
    final bounds = _boundsOf(strokes);
    final sourceWidth = math.max(.1, bounds.width);
    final sourceHeight = math.max(.1, bounds.height);
    final sourceCenter = ui.Offset(
      (bounds.minX + bounds.maxX) / 2,
      (bounds.minY + bounds.maxY) / 2,
    );
    final radians = rotationDegrees * math.pi / 180;
    final cosine = math.cos(radians);
    final sine = math.sin(radians);
    final rotated = strokes
        .map(
          (stroke) => stroke
              .map((point) {
                final x = (point.dx - sourceCenter.dx) * width / sourceWidth;
                final y = (point.dy - sourceCenter.dy) * height / sourceHeight;
                return ui.Offset(x * cosine - y * sine, x * sine + y * cosine);
              })
              .toList(growable: false),
        )
        .toList(growable: false);
    final rotatedBounds = _boundsOf(rotated);
    final fit = math.min(
      1.0,
      math.min(
        _bedSize / math.max(.1, rotatedBounds.width),
        _bedSize / math.max(.1, rotatedBounds.height),
      ),
    );
    final rotatedCenter = ui.Offset(
      (rotatedBounds.minX + rotatedBounds.maxX) / 2,
      (rotatedBounds.minY + rotatedBounds.maxY) / 2,
    );
    return rotated
        .map(
          (stroke) => stroke
              .map(
                (point) => ui.Offset(
                  targetCenter.dx + (point.dx - rotatedCenter.dx) * fit,
                  targetCenter.dy + (point.dy - rotatedCenter.dy) * fit,
                ),
              )
              .toList(growable: false),
        )
        .toList(growable: false);
  }

  static Future<PlotImportResult> fromMonochromeImage(
    Uint8List bytes, {
    required String label,
    required double threshold,
  }) async {
    if (threshold <= 0 || threshold >= 1) {
      throw ArgumentError.value(
        threshold,
        'threshold',
        'Use um limiar entre 0 e 1.',
      );
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _rasterWidth,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw StateError('Não foi possível ler os pixels da imagem.');
      }
      final width = image.width;
      final height = image.height;
      final pixels = data.buffer.asUint8List();
      final mask = List<List<bool>>.generate(
        height,
        (y) => List<bool>.generate(width, (x) {
          final index = (y * width + x) * 4;
          final alpha = pixels[index + 3];
          if (alpha < 80) {
            return false;
          }
          final luminance =
              (.2126 * pixels[index] +
                  .7152 * pixels[index + 1] +
                  .0722 * pixels[index + 2]) /
              255;
          return luminance < threshold;
        }),
      );
      final paths = _fitIntoBed(_traceRaster(mask));
      _validateComplexity(paths);
      return PlotImportResult(
        label: 'P/B $label',
        strokes: paths,
        sourceWidth: width,
        sourceHeight: height,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  static PlotImportResult fromSvg(String source, {required String label}) {
    final document = XmlDocument.parse(source);
    final strokes = <List<ui.Offset>>[];
    for (final element in document.descendants.whereType<XmlElement>()) {
      final elementStrokes = <List<ui.Offset>>[];
      switch (element.name.local.toLowerCase()) {
        case 'path':
          final data = element.getAttribute('d');
          if (data != null) {
            final collector = _SvgPathCollector();
            writeSvgPathDataToPath(data, collector);
            elementStrokes.addAll(collector.strokes);
          }
          break;
        case 'polyline':
        case 'polygon':
          final points = _coordinatePairs(element.getAttribute('points'));
          if (points.length >= 2) {
            if (element.name.local.toLowerCase() == 'polygon') {
              points.add(points.first);
            }
            elementStrokes.add(points);
          }
          break;
        case 'line':
          final x1 = _number(element.getAttribute('x1'));
          final y1 = _number(element.getAttribute('y1'));
          final x2 = _number(element.getAttribute('x2'));
          final y2 = _number(element.getAttribute('y2'));
          elementStrokes.add([ui.Offset(x1, y1), ui.Offset(x2, y2)]);
          break;
        case 'rect':
          final x = _number(element.getAttribute('x'));
          final y = _number(element.getAttribute('y'));
          final width = _number(element.getAttribute('width'));
          final height = _number(element.getAttribute('height'));
          if (width > 0 && height > 0) {
            elementStrokes.add([
              ui.Offset(x, y),
              ui.Offset(x + width, y),
              ui.Offset(x + width, y + height),
              ui.Offset(x, y + height),
              ui.Offset(x, y),
            ]);
          }
          break;
        case 'circle':
          final radius = _number(element.getAttribute('r'));
          if (radius > 0) {
            elementStrokes.add(
              _ellipse(
                _number(element.getAttribute('cx')),
                _number(element.getAttribute('cy')),
                radius,
                radius,
              ),
            );
          }
          break;
        case 'ellipse':
          final rx = _number(element.getAttribute('rx'));
          final ry = _number(element.getAttribute('ry'));
          if (rx > 0 && ry > 0) {
            elementStrokes.add(
              _ellipse(
                _number(element.getAttribute('cx')),
                _number(element.getAttribute('cy')),
                rx,
                ry,
              ),
            );
          }
          break;
      }
      final transform = _transformForElement(element);
      strokes.addAll(
        elementStrokes.map(
          (stroke) => stroke
              .map(transform.apply)
              .toList(growable: false),
        ),
      );
    }
    final paths = _fitIntoBed(strokes);
    if (paths.isEmpty) {
      throw FormatException('Nenhum traço suportado foi encontrado no SVG.');
    }
    _validateComplexity(paths);
    return PlotImportResult(
      label: 'SVG $label',
      strokes: paths,
      sourceWidth: 0,
      sourceHeight: 0,
    );
  }

  static List<List<ui.Offset>> _traceRaster(List<List<bool>> mask) {
    if (mask.isEmpty || mask.first.isEmpty) {
      return const [];
    }
    final height = mask.length;
    final width = mask.first.length;
    final edges = <_RasterPoint, List<_RasterPoint>>{};
    void addEdge(_RasterPoint from, _RasterPoint to) {
      (edges[from] ??= []).add(to);
    }

    bool blackAt(int x, int y) =>
        x >= 0 && x < width && y >= 0 && y < height && mask[y][x];

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (!mask[y][x]) {
          continue;
        }
        if (!blackAt(x, y - 1)) {
          addEdge(_RasterPoint(x, y), _RasterPoint(x + 1, y));
        }
        if (!blackAt(x + 1, y)) {
          addEdge(_RasterPoint(x + 1, y), _RasterPoint(x + 1, y + 1));
        }
        if (!blackAt(x, y + 1)) {
          addEdge(_RasterPoint(x + 1, y + 1), _RasterPoint(x, y + 1));
        }
        if (!blackAt(x - 1, y)) {
          addEdge(_RasterPoint(x, y + 1), _RasterPoint(x, y));
        }
      }
    }

    final result = <List<ui.Offset>>[];
    while (true) {
      _RasterPoint? start;
      for (final entry in edges.entries) {
        if (entry.value.isNotEmpty) {
          start = entry.key;
          break;
        }
      }
      if (start == null) {
        break;
      }
      final route = <ui.Offset>[
        ui.Offset(start.x.toDouble(), start.y.toDouble()),
      ];
      var current = start;
      while (true) {
        final next = edges[current];
        if (next == null || next.isEmpty) {
          break;
        }
        final target = next.removeLast();
        current = target;
        route.add(ui.Offset(current.x.toDouble(), current.y.toDouble()));
        if (current == start || route.length > _maxSegments) {
          break;
        }
      }
      final simplified = _simplify(route, .45);
      if (simplified.length >= 3) {
        result.add(simplified);
      }
    }
    return result;
  }

  static List<List<ui.Offset>> _fitIntoBed(List<List<ui.Offset>> raw) {
    final valid = raw
        .map((stroke) => _simplify(stroke, .25))
        .where((stroke) => stroke.length >= 2)
        .toList(growable: false);
    if (valid.isEmpty) {
      return const [];
    }
    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final stroke in valid) {
      for (final point in stroke) {
        minX = math.min(minX, point.dx);
        maxX = math.max(maxX, point.dx);
        minY = math.min(minY, point.dy);
        maxY = math.max(maxY, point.dy);
      }
    }
    final width = math.max(1.0, maxX - minX);
    final height = math.max(1.0, maxY - minY);
    final available = _bedSize - _margin * 2;
    final scale = math.min(available / width, available / height);
    final offsetX = _margin + (available - width * scale) / 2;
    final offsetY = _margin + (available - height * scale) / 2;
    return valid
        .map(
          (stroke) => stroke
              .map(
                (point) => ui.Offset(
                  offsetX + (point.dx - minX) * scale,
                  offsetY + (maxY - point.dy) * scale,
                ),
              )
              .toList(growable: false),
        )
        .toList(growable: false);
  }

  static _PlotBounds _boundsOf(List<List<ui.Offset>> strokes) {
    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final stroke in strokes) {
      for (final point in stroke) {
        minX = math.min(minX, point.dx);
        maxX = math.max(maxX, point.dx);
        minY = math.min(minY, point.dy);
        maxY = math.max(maxY, point.dy);
      }
    }
    if (!minX.isFinite) {
      throw ArgumentError.value(strokes, 'strokes', 'A rota está vazia.');
    }
    return _PlotBounds(minX, maxX, minY, maxY);
  }

  static void _validateComplexity(List<List<ui.Offset>> strokes) {
    final segments = strokes.fold<int>(
      0,
      (total, stroke) => total + math.max(0, stroke.length - 1),
    );
    if (segments == 0) {
      throw FormatException('A imagem não contém áreas pretas para traçar.');
    }
    if (segments > _maxSegments) {
      throw FormatException(
        'O arquivo gerou $segments segmentos. Use uma imagem mais simples ou com menos detalhe.',
      );
    }
  }

  static List<ui.Offset> _coordinatePairs(String? value) {
    final numbers = RegExp(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?')
        .allMatches(value ?? '')
        .map((match) => double.parse(match.group(0)!))
        .toList();
    return [
      for (var index = 0; index + 1 < numbers.length; index += 2)
        ui.Offset(numbers[index], numbers[index + 1]),
    ];
  }

  static List<ui.Offset> _ellipse(double cx, double cy, double rx, double ry) {
    return [
      for (var index = 0; index <= 32; index++)
        ui.Offset(
          cx + rx * math.cos(index / 32 * math.pi * 2),
          cy + ry * math.sin(index / 32 * math.pi * 2),
        ),
    ];
  }

  static double _number(String? value) {
    final match = RegExp(
      r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?',
    ).firstMatch(value ?? '');
    return match == null ? 0 : double.parse(match.group(0)!);
  }

  static _SvgTransform _transformForElement(XmlElement element) {
    final lineage = <XmlElement>[];
    XmlNode? current = element;
    while (current != null) {
      if (current is XmlElement) {
        lineage.add(current);
      }
      current = current.parent;
    }
    var transform = _SvgTransform.identity;
    for (final ancestor in lineage.reversed) {
      transform = transform.multiply(
        _SvgTransform.parse(ancestor.getAttribute('transform')),
      );
    }
    return transform;
  }

  static List<ui.Offset> _simplify(List<ui.Offset> points, double tolerance) {
    if (points.length < 3) {
      return points;
    }
    final closed = points.first == points.last;
    final source = closed ? points.sublist(0, points.length - 1) : points;
    if (source.length < 3) {
      return points;
    }
    final keep = List<bool>.filled(source.length, false)
      ..first = true
      ..last = true;
    void reduce(int first, int last) {
      var maxDistance = 0.0;
      var index = 0;
      for (var current = first + 1; current < last; current++) {
        final distance = _distanceToSegment(
          source[current],
          source[first],
          source[last],
        );
        if (distance > maxDistance) {
          maxDistance = distance;
          index = current;
        }
      }
      if (maxDistance > tolerance) {
        keep[index] = true;
        reduce(first, index);
        reduce(index, last);
      }
    }

    reduce(0, source.length - 1);
    final result = <ui.Offset>[
      for (var index = 0; index < source.length; index++)
        if (keep[index]) source[index],
    ];
    if (closed && result.length > 2) {
      result.add(result.first);
    }
    return result;
  }

  static double _distanceToSegment(
    ui.Offset point,
    ui.Offset start,
    ui.Offset end,
  ) {
    final delta = end - start;
    final lengthSquared = delta.dx * delta.dx + delta.dy * delta.dy;
    if (lengthSquared == 0) {
      return (point - start).distance;
    }
    final ratio =
        ((point - start).dx * delta.dx + (point - start).dy * delta.dy) /
        lengthSquared;
    final closest = start + delta * ratio.clamp(0.0, 1.0);
    return (point - closest).distance;
  }
}

class _SvgTransform {
  const _SvgTransform(this.a, this.b, this.c, this.d, this.e, this.f);

  static const identity = _SvgTransform(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  ui.Offset apply(ui.Offset point) => ui.Offset(
    a * point.dx + c * point.dy + e,
    b * point.dx + d * point.dy + f,
  );

  _SvgTransform multiply(_SvgTransform other) => _SvgTransform(
    a * other.a + c * other.b,
    b * other.a + d * other.b,
    a * other.c + c * other.d,
    b * other.c + d * other.d,
    a * other.e + c * other.f + e,
    b * other.e + d * other.f + f,
  );

  static _SvgTransform parse(String? source) {
    var result = identity;
    for (final match in RegExp(
      r'([a-zA-Z]+)\s*\(([^)]*)\)',
    ).allMatches(source ?? '')) {
      final values = RegExp(
        r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?',
      )
          .allMatches(match.group(2)!)
          .map((number) => double.parse(number.group(0)!))
          .toList(growable: false);
      final transform = switch (match.group(1)!.toLowerCase()) {
        'matrix' when values.length >= 6 => _SvgTransform(
          values[0],
          values[1],
          values[2],
          values[3],
          values[4],
          values[5],
        ),
        'translate' when values.isNotEmpty => _SvgTransform(
          1,
          0,
          0,
          1,
          values[0],
          values.length >= 2 ? values[1] : 0,
        ),
        'scale' when values.isNotEmpty => _SvgTransform(
          values[0],
          0,
          0,
          values.length >= 2 ? values[1] : values[0],
          0,
          0,
        ),
        'rotate' when values.isNotEmpty => _rotation(
          values[0],
          centerX: values.length >= 3 ? values[1] : 0,
          centerY: values.length >= 3 ? values[2] : 0,
        ),
        'skewx' when values.isNotEmpty => _SvgTransform(
          1,
          0,
          math.tan(values[0] * math.pi / 180),
          1,
          0,
          0,
        ),
        'skewy' when values.isNotEmpty => _SvgTransform(
          1,
          math.tan(values[0] * math.pi / 180),
          0,
          1,
          0,
          0,
        ),
        _ => identity,
      };
      result = result.multiply(transform);
    }
    return result;
  }

  static _SvgTransform _rotation(
    double degrees, {
    required double centerX,
    required double centerY,
  }) {
    final radians = degrees * math.pi / 180;
    final rotation = _SvgTransform(
      math.cos(radians),
      math.sin(radians),
      -math.sin(radians),
      math.cos(radians),
      0,
      0,
    );
    return _SvgTransform(1, 0, 0, 1, centerX, centerY)
        .multiply(rotation)
        .multiply(_SvgTransform(1, 0, 0, 1, -centerX, -centerY));
  }
}

class _SvgPathCollector implements PathProxy {
  final List<List<ui.Offset>> strokes = [];
  ui.Offset _current = ui.Offset.zero;
  ui.Offset? _start;

  @override
  void moveTo(double x, double y) {
    _current = ui.Offset(x, y);
    _start = _current;
    strokes.add([_current]);
  }

  @override
  void lineTo(double x, double y) {
    final target = ui.Offset(x, y);
    if (strokes.isEmpty) {
      moveTo(x, y);
      return;
    }
    strokes.last.add(target);
    _current = target;
  }

  @override
  void cubicTo(
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
  ) {
    final start = _current;
    final control1 = ui.Offset(x1, y1);
    final control2 = ui.Offset(x2, y2);
    for (var step = 1; step <= 10; step++) {
      final t = step / 10;
      final inverse = 1 - t;
      final point =
          start * (inverse * inverse * inverse) +
          control1 * (3 * inverse * inverse * t) +
          control2 * (3 * inverse * t * t) +
          ui.Offset(x3, y3) * (t * t * t);
      lineTo(point.dx, point.dy);
    }
  }

  @override
  void close() {
    final start = _start;
    if (start != null && _current != start) {
      lineTo(start.dx, start.dy);
    }
  }
}

class _PlotBounds {
  const _PlotBounds(this.minX, this.maxX, this.minY, this.maxY);

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;

  double get width => maxX - minX;
  double get height => maxY - minY;
}

class _RasterPoint {
  const _RasterPoint(this.x, this.y);

  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _RasterPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);
}
