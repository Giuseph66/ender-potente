import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path_parsing/path_parsing.dart';
import 'package:xml/xml.dart';

/// Como um SVG com formas preenchidas (traços desenhados como contorno,
/// não como linha) deve virar rota de plotter.
enum SvgTraceMode {
  /// Desenha o contorno da forma tal como está no SVG (padrão).
  outline,

  /// Reduz cada forma preenchida ao seu eixo central (esqueleto), como se
  /// fosse uma única linha no meio do traço.
  centerline,
}

class PlotDimensions {
  const PlotDimensions({required this.width, required this.height});

  final double width;
  final double height;
}

class PlotImportResult {
  const PlotImportResult({
    required this.label,
    required this.strokes,
    required this.traceIds,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  final String label;
  final List<List<ui.Offset>> strokes;

  /// Identifica a qual traço de origem (elemento SVG ou contorno detectado
  /// na imagem) cada entrada de [strokes] pertence, na mesma ordem.
  final List<int> traceIds;
  final int sourceWidth;
  final int sourceHeight;

  int get segmentCount => strokes.fold<int>(
    0,
    (total, stroke) => total + math.max(0, stroke.length - 1),
  );

  int get traceCount => traceIds.toSet().length;
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
    double maxX = _bedSize,
    double maxY = _bedSize,
  }) => resizeRotateAndCenter(
    strokes,
    width: width,
    height: height,
    rotationDegrees: 0,
    maxX: maxX,
    maxY: maxY,
  );

  static List<List<ui.Offset>> resizeRotateAndCenter(
    List<List<ui.Offset>> strokes, {
    required double width,
    required double height,
    required double rotationDegrees,
    ui.Offset? center,
    double maxX = _bedSize,
    double maxY = _bedSize,
  }) {
    if (width <= 0 || height <= 0 || width > maxX || height > maxY) {
      throw ArgumentError(
        'O tamanho da rota deve ficar entre 0 e '
        '${maxX.toStringAsFixed(0)} × ${maxY.toStringAsFixed(0)} mm.',
      );
    }
    if (!rotationDegrees.isFinite) {
      throw ArgumentError.value(
        rotationDegrees,
        'rotationDegrees',
        'A rotação deve ser um número válido.',
      );
    }
    final targetCenter = center ?? ui.Offset(maxX / 2, maxY / 2);
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
        maxX / math.max(.1, rotatedBounds.width),
        maxY / math.max(.1, rotatedBounds.height),
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
      final rawStrokes = _traceRaster(mask);
      final rawIds = List<int>.generate(rawStrokes.length, (index) => index);
      final (paths, pathIds) = _fitIntoBed(rawStrokes, rawIds);
      _validateComplexity(paths);
      return PlotImportResult(
        label: 'P/B $label',
        strokes: paths,
        traceIds: pathIds,
        sourceWidth: width,
        sourceHeight: height,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }

  static PlotImportResult fromSvg(
    String source, {
    required String label,
    SvgTraceMode mode = SvgTraceMode.outline,
  }) {
    final document = XmlDocument.parse(source);
    final strokes = <List<ui.Offset>>[];
    final ids = <int>[];
    var traceCounter = 0;
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
      if (elementStrokes.isEmpty) {
        continue;
      }
      final transform = _transformForElement(element);
      final traceId = traceCounter++;
      for (final stroke in elementStrokes) {
        strokes.add(stroke.map(transform.apply).toList(growable: false));
        ids.add(traceId);
      }
    }
    final (rawStrokes, rawIds) = mode == SvgTraceMode.centerline
        ? _centerlinesOf(strokes, ids)
        : (strokes, ids);
    final (paths, pathIds) = _fitIntoBed(rawStrokes, rawIds);
    if (paths.isEmpty) {
      throw FormatException('Nenhum traço suportado foi encontrado no SVG.');
    }
    _validateComplexity(paths);
    return PlotImportResult(
      label: 'SVG $label',
      strokes: paths,
      traceIds: pathIds,
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

  /// Reduz cada grupo de traços (mesmo [ids]) ao seu eixo central,
  /// via rasterização + afinamento (thinning) do preenchimento da forma.
  /// Grupos que não formam área (ex.: uma `<line>`, já fina) ou que falham
  /// ao afinar caem de volta no contorno original.
  static (List<List<ui.Offset>>, List<int>) _centerlinesOf(
    List<List<ui.Offset>> strokes,
    List<int> ids,
  ) {
    final indicesByTrace = <int, List<int>>{};
    for (var index = 0; index < ids.length; index++) {
      (indicesByTrace[ids[index]] ??= []).add(index);
    }
    final outStrokes = <List<ui.Offset>>[];
    final outIds = <int>[];
    indicesByTrace.forEach((traceId, indices) {
      final polygons = [for (final index in indices) strokes[index]];
      final skeleton = _skeletonize(polygons);
      final resolved = skeleton.isEmpty ? polygons : skeleton;
      for (final line in resolved) {
        outStrokes.add(line);
        outIds.add(traceId);
      }
    });
    return (outStrokes, outIds);
  }

  /// Quantos pixels a espessura do traço deve ocupar no raster: abaixo de
  /// ~6 px o afinamento deixa degraus; acima disso só custa tempo.
  static const _skeletonStrokePixels = 6.0;
  static const _skeletonMinStrokePixels = 3.5;
  static const _skeletonMaxCells = 150000;

  /// Espessura média do traço de uma forma preenchida, por área e perímetro:
  /// numa fita de largura w e comprimento L, área ≈ w·L e perímetro ≈ 2L.
  static double _estimateStrokeWidth(List<List<ui.Offset>> polygons) {
    var area = 0.0;
    var perimeter = 0.0;
    for (final polygon in polygons) {
      if (polygon.length < 3) {
        continue;
      }
      for (var i = 0; i < polygon.length; i++) {
        final p1 = polygon[i];
        final p2 = polygon[(i + 1) % polygon.length];
        area += p1.dx * p2.dy - p2.dx * p1.dy;
        perimeter += (p2 - p1).distance;
      }
    }
    area = area.abs() / 2;
    if (area <= 0 || perimeter <= 0) {
      return 0;
    }
    return 2 * area / perimeter;
  }

  static List<List<ui.Offset>> _skeletonize(List<List<ui.Offset>> polygons) {
    var minX = double.infinity;
    var maxX = -double.infinity;
    var minY = double.infinity;
    var maxY = -double.infinity;
    for (final polygon in polygons) {
      for (final point in polygon) {
        minX = math.min(minX, point.dx);
        maxX = math.max(maxX, point.dx);
        minY = math.min(minY, point.dy);
        maxY = math.max(maxY, point.dy);
      }
    }
    if (!minX.isFinite) {
      return const [];
    }
    final width = math.max(.05, maxX - minX);
    final height = math.max(.05, maxY - minY);
    // A resolução tem que sair da espessura do traço, não do bounding box:
    // numa letra cursiva o bbox é a altura da letra, mas o traço é fino, e
    // rasterizar pelo bbox achataria tudo em 1 px (o esqueleto viraria lixo).
    // Para uma fita de largura w e comprimento L: área ≈ w·L e perímetro ≈ 2L,
    // logo w ≈ 2·área/perímetro.
    final strokeWidth = _estimateStrokeWidth(polygons);
    if (strokeWidth <= 0) {
      return const [];
    }
    var scale = _skeletonStrokePixels / strokeWidth;
    var gridWidth = (width * scale).ceil() + 2;
    var gridHeight = (height * scale).ceil() + 2;
    if (gridWidth * gridHeight > _skeletonMaxCells) {
      scale *= math.sqrt(_skeletonMaxCells / (gridWidth * gridHeight));
      gridWidth = (width * scale).ceil() + 2;
      gridHeight = (height * scale).ceil() + 2;
    }
    // Sem pixels suficientes na largura do traço o afinamento não converge
    // para o eixo central: melhor devolver vazio e deixar cair no contorno.
    if (strokeWidth * scale < _skeletonMinStrokePixels) {
      return const [];
    }
    gridWidth = gridWidth.clamp(3, 4000).toInt();
    gridHeight = gridHeight.clamp(3, 4000).toInt();

    final mask = Uint8List(gridWidth * gridHeight);
    // A moldura de 1 px fica sempre vazia: o afinamento não processa a borda
    // do raster, então nada de conteúdo pode encostar nela.
    for (var row = 1; row < gridHeight - 1; row++) {
      final y = minY + (row - 1 + .5) / scale;
      final crossings = <_Crossing>[];
      for (final polygon in polygons) {
        if (polygon.length < 2) {
          continue;
        }
        for (var i = 0; i < polygon.length; i++) {
          final p1 = polygon[i];
          final p2 = polygon[(i + 1) % polygon.length];
          if (p1.dy == p2.dy) {
            continue;
          }
          final within = (p1.dy <= y && p2.dy > y) || (p2.dy <= y && p1.dy > y);
          if (!within) {
            continue;
          }
          final t = (y - p1.dy) / (p2.dy - p1.dy);
          final x = p1.dx + t * (p2.dx - p1.dx);
          crossings.add(_Crossing(x, p2.dy > p1.dy ? 1 : -1));
        }
      }
      if (crossings.length < 2) {
        continue;
      }
      crossings.sort((a, b) => a.x.compareTo(b.x));
      var winding = 0;
      for (var i = 0; i < crossings.length - 1; i++) {
        winding += crossings[i].direction;
        if (winding == 0) {
          continue;
        }
        var colStart = ((crossings[i].x - minX) * scale).floor() + 1;
        var colEnd = ((crossings[i + 1].x - minX) * scale).ceil() + 1;
        colStart = colStart.clamp(1, gridWidth - 2);
        colEnd = colEnd.clamp(1, gridWidth - 2);
        final rowOffset = row * gridWidth;
        for (var col = colStart; col <= colEnd; col++) {
          mask[rowOffset + col] = 1;
        }
      }
    }

    _thin(mask, gridWidth, gridHeight);
    // Pontas de afinamento crescem com a espessura: podar por um comprimento
    // proporcional evita que cada curva feche um "galho" e parta a linha.
    final pruneLength = (strokeWidth * scale * 1.6).round().clamp(4, 40);
    final pixelLines = _joinLines(
      _vectorizeSkeleton(
        mask,
        gridWidth,
        gridHeight,
        pruneLength: pruneLength,
      ),
      tolerance: 1.5,
      redundantLimit: pruneLength.toDouble(),
      coverageTolerance: strokeWidth * scale * .5,
    );
    if (pixelLines.isEmpty) {
      return const [];
    }
    return pixelLines
        .map(
          (line) => _smooth(
            line
                .map(
                  (point) => ui.Offset(
                    minX + (point.dx - 1) / scale,
                    minY + (point.dy - 1) / scale,
                  ),
                )
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  /// Emenda polilinhas cujas pontas se encontram (numa bifurcação, ou
  /// separadas por um "degrau" de 1 px que o afinamento deixa): cada emenda é
  /// uma subida de caneta a menos. Começa pelas linhas mais longas para o
  /// traço principal ter prioridade, e descarta os cacos que sobram.
  static List<List<ui.Offset>> _joinLines(
    List<List<ui.Offset>> lines, {
    required double tolerance,
    required double redundantLimit,
    required double coverageTolerance,
  }) {
    final pending = [
      for (final line in lines)
        if (line.length >= 2) List<ui.Offset>.from(line),
    ]..sort((a, b) => _lengthOf(a).compareTo(_lengthOf(b)));
    final joined = <List<ui.Offset>>[];
    bool near(ui.Offset a, ui.Offset b) => (a - b).distance <= tolerance;

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      var extended = true;
      while (extended) {
        extended = false;
        for (var i = pending.length - 1; i >= 0; i--) {
          final other = pending[i];
          if (near(other.last, current.first)) {
            current.insertAll(0, other.sublist(0, other.length - 1));
          } else if (near(other.first, current.first)) {
            current.insertAll(0, other.reversed.skip(1).toList());
          } else if (near(other.first, current.last)) {
            current.addAll(other.skip(1));
          } else if (near(other.last, current.last)) {
            current.addAll(other.reversed.skip(1));
          } else {
            continue;
          }
          pending.removeAt(i);
          extended = true;
          break;
        }
      }
      joined.add(current);
    }
    // Sobram os ramos paralelos das "bolhas" do afinamento: trechos curtos
    // cujas duas pontas encostam num traço já mantido, ou seja, geometria
    // duplicada. Mantém sempre a linha mais longa.
    joined.sort((a, b) => _lengthOf(b).compareTo(_lengthOf(a)));
    final kept = <List<ui.Offset>>[];
    for (final line in joined) {
      final length = _lengthOf(line);
      if (kept.isNotEmpty && length <= redundantLimit) {
        final startCovered = kept.any(
          (other) =>
              other.any((p) => (p - line.first).distance <= coverageTolerance),
        );
        final endCovered = kept.any(
          (other) =>
              other.any((p) => (p - line.last).distance <= coverageTolerance),
        );
        if (startCovered && endCovered) {
          continue;
        }
      }
      if (length > tolerance || kept.isEmpty) {
        kept.add(line);
      }
    }
    return kept.isEmpty ? joined : kept;
  }

  static double _lengthOf(List<ui.Offset> line) {
    var total = 0.0;
    for (var i = 0; i + 1 < line.length; i++) {
      total += (line[i + 1] - line[i]).distance;
    }
    return total;
  }

  /// Média móvel de 3 pontos (mantendo as pontas) para tirar o serrilhado que
  /// o esqueleto herda do raster.
  static List<ui.Offset> _smooth(List<ui.Offset> line) {
    if (line.length < 3) {
      return line;
    }
    var current = line;
    for (var pass = 0; pass < 2; pass++) {
      final next = List<ui.Offset>.from(current);
      for (var i = 1; i < current.length - 1; i++) {
        next[i] = (current[i - 1] + current[i] * 2 + current[i + 1]) / 4;
      }
      current = next;
    }
    return current;
  }

  /// Afinamento morfológico de Zhang-Suen: reduz uma área preenchida a um
  /// esqueleto de 1 pixel de largura, preservando a conectividade.
  static void _thin(Uint8List mask, int width, int height) {
    // Percorre só os pixels preenchidos (a lista encolhe a cada passada), em
    // vez do raster inteiro: numa fita fina dentro de um bbox grande a maior
    // parte das células está vazia.
    var active = <int>[];
    for (var y = 1; y < height - 1; y++) {
      final rowOffset = y * width;
      for (var x = 1; x < width - 1; x++) {
        if (mask[rowOffset + x] != 0) {
          active.add(rowOffset + x);
        }
      }
    }
    final toRemove = <int>[];
    var changed = true;
    var guard = 0;
    while (changed && guard < 300) {
      changed = false;
      guard++;
      for (var step = 0; step < 2; step++) {
        toRemove.clear();
        final survivors = <int>[];
        {
          for (final index in active) {
            if (mask[index] == 0) {
              continue;
            }
            survivors.add(index);
            final p2 = mask[index - width];
            final p3 = mask[index - width + 1];
            final p4 = mask[index + 1];
            final p5 = mask[index + width + 1];
            final p6 = mask[index + width];
            final p7 = mask[index + width - 1];
            final p8 = mask[index - 1];
            final p9 = mask[index - width - 1];
            final blackNeighbors = p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9;
            if (blackNeighbors < 2 || blackNeighbors > 6) {
              continue;
            }
            var transitions = 0;
            if (p2 == 0 && p3 == 1) transitions++;
            if (p3 == 0 && p4 == 1) transitions++;
            if (p4 == 0 && p5 == 1) transitions++;
            if (p5 == 0 && p6 == 1) transitions++;
            if (p6 == 0 && p7 == 1) transitions++;
            if (p7 == 0 && p8 == 1) transitions++;
            if (p8 == 0 && p9 == 1) transitions++;
            if (p9 == 0 && p2 == 1) transitions++;
            if (transitions != 1) {
              continue;
            }
            if (step == 0) {
              if (p2 * p4 * p6 != 0 || p4 * p6 * p8 != 0) {
                continue;
              }
            } else {
              if (p2 * p4 * p8 != 0 || p2 * p6 * p8 != 0) {
                continue;
              }
            }
            toRemove.add(index);
          }
        }
        active = survivors;
        if (toRemove.isNotEmpty) {
          changed = true;
          for (final cell in toRemove) {
            mask[cell] = 0;
          }
        }
      }
    }
  }

  /// Remove pontas curtas penduradas em bifurcações: ruído típico do
  /// afinamento (cantos e pontas arredondadas geram um "graveto" curto que,
  /// sem isso, viraria um traço minúsculo e desconexo na rota final.
  static void _pruneSkeletonSpurs(
    List<int> points,
    Map<int, List<int>> neighborsOf,
    int pruneLength,
  ) {
    for (var pass = 0; pass < 4; pass++) {
      final endpoints = [
        for (final key in points)
          if (neighborsOf[key]?.length == 1) key,
      ];
      var prunedAny = false;
      for (final start in endpoints) {
        final startNeighbors = neighborsOf[start];
        if (startNeighbors == null || startNeighbors.length != 1) {
          continue;
        }
        final chain = <int>[start];
        var previous = start;
        var current = startNeighbors.first;
        while (true) {
          final currentNeighbors = neighborsOf[current];
          if (currentNeighbors == null || currentNeighbors.length != 2) {
            break;
          }
          chain.add(current);
          if (chain.length > pruneLength) {
            break;
          }
          final forward = currentNeighbors.where((c) => c != previous);
          if (forward.isEmpty) {
            break;
          }
          previous = current;
          current = forward.first;
        }
        final endNeighbors = neighborsOf[current];
        final isSpur =
            chain.length <= pruneLength &&
            endNeighbors != null &&
            endNeighbors.length >= 3;
        if (!isSpur) {
          continue;
        }
        for (final pixel in chain) {
          final pixelNeighbors = neighborsOf.remove(pixel);
          if (pixelNeighbors == null) {
            continue;
          }
          for (final neighbor in pixelNeighbors) {
            neighborsOf[neighbor]?.remove(pixel);
          }
        }
        prunedAny = true;
      }
      if (!prunedAny) {
        break;
      }
    }
  }

  /// Percorre um esqueleto de 1 pixel e monta polilinhas entre pontas e
  /// bifurcações (e laços fechados isolados que sobrarem).
  static List<List<ui.Offset>> _vectorizeSkeleton(
    Uint8List mask,
    int width,
    int height, {
    required int pruneLength,
  }) {
    const orthogonal = [
      [0, -1],
      [1, 0],
      [0, 1],
      [-1, 0],
    ];
    const diagonal = [
      [1, -1],
      [1, 1],
      [-1, 1],
      [-1, -1],
    ];
    bool at(int x, int y) =>
        x >= 0 && x < width && y >= 0 && y < height && mask[y * width + x] != 0;
    int keyOf(int x, int y) => y * width + x;
    ui.Offset pointFor(int key) =>
        ui.Offset((key % width).toDouble(), (key ~/ width).toDouble());

    final neighborsOf = <int, List<int>>{};
    final points = <int>[];
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (mask[y * width + x] == 0) {
          continue;
        }
        final key = keyOf(x, y);
        points.add(key);
        final neighbors = <int>[];
        for (final d in orthogonal) {
          if (at(x + d[0], y + d[1])) {
            neighbors.add(keyOf(x + d[0], y + d[1]));
          }
        }
        // Uma diagonal só conta se nenhum dos dois vizinhos ortogonais que a
        // "cruzam" já estiver presente: senão ela é uma ponte redundante que
        // fecha um triângulo e cria uma bifurcação falsa (artefato de
        // serrilhado da rasterização), fragmentando a linha em pedaços.
        for (final d in diagonal) {
          if (!at(x + d[0], y + d[1])) {
            continue;
          }
          if (at(x + d[0], y) || at(x, y + d[1])) {
            continue;
          }
          neighbors.add(keyOf(x + d[0], y + d[1]));
        }
        neighborsOf[key] = neighbors;
      }
    }
    if (points.isEmpty) {
      return const [];
    }
    _pruneSkeletonSpurs(points, neighborsOf, pruneLength);

    final consumed = <int>{};
    int edgeKey(int a, int b) => a < b ? a * 1000000 + b : b * 1000000 + a;

    List<int> walk(int start, int next) {
      final path = <int>[start, next];
      consumed.add(edgeKey(start, next));
      var previous = start;
      var current = next;
      while (neighborsOf[current]!.length == 2) {
        final forward = neighborsOf[current]!
            .where((candidate) => candidate != previous)
            .toList();
        if (forward.isEmpty) {
          break;
        }
        final target = forward.first;
        if (consumed.contains(edgeKey(current, target))) {
          break;
        }
        consumed.add(edgeKey(current, target));
        path.add(target);
        previous = current;
        current = target;
      }
      return path;
    }

    final lines = <List<ui.Offset>>[];
    // Primeiro as pontas e bifurcações (as cadeias abertas), depois o que
    // sobrar de laço fechado. Pixels podados saíram de [neighborsOf].
    for (final key in points) {
      final neighbors = neighborsOf[key];
      if (neighbors == null || neighbors.length == 2) {
        continue;
      }
      for (final neighbor in neighbors) {
        if (consumed.contains(edgeKey(key, neighbor))) {
          continue;
        }
        final path = walk(key, neighbor);
        if (path.length >= 2) {
          lines.add(path.map(pointFor).toList(growable: false));
        }
      }
    }
    for (final key in points) {
      final neighbors = neighborsOf[key];
      if (neighbors == null || neighbors.length != 2) {
        continue;
      }
      for (final neighbor in neighbors) {
        if (consumed.contains(edgeKey(key, neighbor))) {
          continue;
        }
        final path = walk(key, neighbor);
        if (path.length >= 3) {
          lines.add(path.map(pointFor).toList(growable: false));
        }
      }
    }
    return lines;
  }

  static (List<List<ui.Offset>>, List<int>) _fitIntoBed(
    List<List<ui.Offset>> raw,
    List<int> ids,
  ) {
    final valid = <List<ui.Offset>>[];
    final validIds = <int>[];
    for (var index = 0; index < raw.length; index++) {
      final simplified = _simplify(raw[index], .25);
      if (simplified.length >= 2) {
        valid.add(simplified);
        validIds.add(ids[index]);
      }
    }
    if (valid.isEmpty) {
      return (const [], const []);
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
    final fitted = valid
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
    return (fitted, validIds);
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
      final values = RegExp(r'[-+]?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?')
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

class _Crossing {
  const _Crossing(this.x, this.direction);

  final double x;
  final int direction;
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
