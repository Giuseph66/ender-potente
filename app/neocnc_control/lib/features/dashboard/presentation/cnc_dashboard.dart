import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/neocnc_theme.dart';
import '../../drawing/application/plot_importer.dart';
import '../../drawing/application/route_optimizer.dart';
import '../../drawing/application/route_preview.dart';
import '../../job/application/gcode_importer.dart';
import '../../job/domain/gcode_job.dart';
import '../../job/presentation/job_panel.dart';
import '../../printer/application/printer_controller.dart';
import '../../printer/data/usb_serial_transport.dart';
import '../../printer/domain/drawing_point.dart';
import '../../printer/domain/printer_snapshot.dart';

enum _ControlTab { map, drawing, job, relativeMotion, logs }

String _completionSoundLabel(CompletionSound sound) => switch (sound) {
  CompletionSound.none => 'SEM SOM',
  CompletionSound.discreet => 'BIP CURTO',
  CompletionSound.melody => 'MELODIA',
};

class CncDashboard extends StatefulWidget {
  const CncDashboard({super.key});

  @override
  State<CncDashboard> createState() => _CncDashboardState();
}

class _CncDashboardState extends State<CncDashboard>
    with SingleTickerProviderStateMixin {
  static const _initialImportLongestSideMm = 100.0;
  static const _previewMinDuration = Duration(seconds: 3);
  static const _previewMaxDuration = Duration(seconds: 20);

  late final PrinterController _controller;
  late final AnimationController _previewController;
  bool _showRoutePreview = false;
  final TextEditingController _commandController = TextEditingController();
  String? _selectedPort;
  int _baudRate = UsbSerialTransport.defaultBaudRate;
  double _step = 1;
  double _feedrate = 40;
  bool _mapArmed = false;
  Offset? _mapTarget;
  final List<List<Offset>> _drawingStrokes = [];
  double _penLiftMm = 5;
  double _drawingZ = 0;
  CompletionSound _completionSound = CompletionSound.discreet;
  double _imageThreshold = .5;
  SvgTraceMode _svgTraceMode = SvgTraceMode.outline;
  bool _importingDrawing = false;
  String? _importedDrawingLabel;
  List<List<Offset>>? _importedBaseStrokes;
  String? _importedSvgSource;
  String? _importedSvgFileName;
  double? _routeWidthMm;
  double? _routeHeightMm;
  double _routeRotationDegrees = 0;
  double _routeCenterX = 110;
  double _routeCenterY = 110;
  bool _lockRouteProportions = true;
  MachineLimits _machineLimits = MachineLimits.neoCnc;
  _ControlTab _selectedTab = _ControlTab.map;
  String _printerModel = 'Ender-3 Neo / NeoCNC';
  bool _compactControls = false;
  String? _jobSource;
  GcodeJob? _job;
  double _jobZOffsetMm = 0;
  bool _importingJob = false;
  String? _jobRemoteName;
  String? _jobUploadedName;

  @override
  void initState() {
    super.initState();
    _controller = PrinterController();
    _previewController = AnimationController(vsync: this)
      ..addListener(() => setState(() {}));
    unawaited(_refreshPorts());
  }

  @override
  void dispose() {
    _previewController.dispose();
    _commandController.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Percurso que a máquina vai fazer na rota atual, incluindo os
  /// deslocamentos com a caneta levantada.
  RoutePreview get _routePreview => RoutePreview.fromStrokes(
    _drawingStrokes,
    origin: _controller.isFullyReferenced
        ? Offset(_controller.snapshot.x, _controller.snapshot.y)
        : null,
  );

  /// Toda rota importada entra já com a ordem dos traços otimizada: o arquivo
  /// guarda as formas na ordem em que foram criadas, que costuma fazer a
  /// caneta cruzar a mesa à toa entre um traço e outro.
  List<List<Offset>> _asBaseStrokes(List<List<Offset>> strokes) {
    return List<List<Offset>>.unmodifiable(
      RouteOptimizer.optimize(strokes)
          .map((stroke) => List<Offset>.unmodifiable(stroke))
          .toList(growable: false),
    );
  }

  /// Reordena a rota que já está na mesa (útil depois de desenhar à mão, ou
  /// para reotimizar depois de mover/girar a rota importada).
  void _optimizeCurrentRoute() {
    if (_controller.isDrawing || _drawingStrokes.length < 2) {
      return;
    }
    final origin = _controller.isFullyReferenced
        ? Offset(_controller.snapshot.x, _controller.snapshot.y)
        : null;
    final before = RouteOptimizer.travelLength(_drawingStrokes, origin: origin);

    final base = _importedBaseStrokes;
    if (base != null) {
      // Reordena a base para que redimensionar e girar continuem valendo.
      setState(() {
        _importedBaseStrokes = _asBaseStrokes(base);
        _previewController.value = 0;
      });
      _transformImportedRoute();
    } else {
      setState(() {
        _drawingStrokes
          ..clear()
          ..addAll(RouteOptimizer.optimize(_drawingStrokes, origin: origin));
        _previewController.value = 0;
      });
    }

    final after = RouteOptimizer.travelLength(_drawingStrokes, origin: origin);
    _showMessage(
      after < before
          ? 'Deslocamento: ${before.round()} mm → ${after.round()} mm.'
          : 'A rota já estava na melhor ordem encontrada '
                '(${after.round()} mm de deslocamento).',
    );
  }

  void _setRoutePreviewVisible(bool visible) {
    setState(() {
      _showRoutePreview = visible;
      _previewController.value = 0;
    });
    if (!visible) {
      _previewController.stop();
    }
  }

  void _toggleRoutePreviewPlayback() {
    if (_previewController.isAnimating) {
      _previewController.stop();
      setState(() {});
      return;
    }
    final preview = _routePreview;
    if (preview.isEmpty) {
      return;
    }
    // A prévia roda numa escala de tempo confortável de assistir, não em
    // tempo real: um desenho de 40 minutos não pode levar 40 minutos aqui.
    final real = preview.estimate(
      feedrateMmPerSecond: _feedrate,
      penLiftMm: _penLiftMm,
    );
    final scaled = Duration(milliseconds: real.inMilliseconds ~/ 12);
    _previewController.duration = Duration(
      milliseconds: scaled.inMilliseconds.clamp(
        _previewMinDuration.inMilliseconds,
        _previewMaxDuration.inMilliseconds,
      ),
    );
    if (_previewController.value >= 1) {
      _previewController.value = 0;
    }
    unawaited(_previewController.forward());
  }

  void _seekRoutePreview(double value) {
    _previewController.stop();
    setState(() => _previewController.value = value.clamp(0.0, 1.0));
  }

  Future<void> _refreshPorts() async {
    try {
      await _controller.refreshPorts();
      if (!mounted) {
        return;
      }
      final ports = _controller.ports;
      if (!ports.contains(_selectedPort)) {
        setState(() => _selectedPort = _preferredPort(ports));
      }
    } catch (_) {
      _showMessage('Não foi possível acessar as portas seriais.');
    }
  }

  String? _preferredPort(List<String> ports) {
    if (ports.isEmpty) {
      return null;
    }
    return ports.firstWhere(
      (port) => port.contains('ttyUSB') || port.contains('ttyACM'),
      orElse: () => ports.first,
    );
  }

  Future<void> _connectOrDisconnect() async {
    if (_controller.isConnected) {
      await _perform(_controller.disconnect);
      return;
    }
    final port = _selectedPort;
    if (port == null) {
      _showMessage('Selecione uma porta, por exemplo /dev/ttyUSB0.');
      return;
    }
    await _perform(() => _controller.connect(port, baudRate: _baudRate));
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _showMessage('$error');
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    String accept = 'CONFIRMAR',
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: NeoCncColors.danger)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(accept),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _home(String? axis) async {
    final target = axis == null
        ? 'TODOS OS EIXOS'
        : axis == 'X Y'
        ? 'EIXOS X E Y'
        : 'EIXO $axis';
    final proceed = await _confirm(
      title: 'Referenciar $target?',
      body:
          'A máquina se movimentará até os fins de curso. Garanta que o '
          'curso esteja livre e que os limites estejam corretamente ligados.',
      accept: 'INICIAR HOMING',
    );
    if (proceed && mounted) {
      await _perform(() => _controller.home(axis));
      if (mounted) {
        setState(() => _mapArmed = false);
      }
    }
  }

  Future<void> _moveFromMap(Offset target) async {
    if (!_controller.isXyReferenced) {
      _showMessage('Faça HOME XY antes de usar o mapa.');
      return;
    }
    if (!_mapArmed) {
      _showMessage('Arme o mapa antes de enviar um destino.');
      return;
    }
    setState(() => _mapTarget = target);
    await _perform(
      () => _controller.moveTo(
        x: target.dx,
        y: target.dy,
        feedrateMmPerSecond: _feedrate,
      ),
    );
  }

  void _startDrawingStroke(Offset point) {
    if (_controller.isDrawing) {
      return;
    }
    setState(() {
      _importedBaseStrokes = null;
      _importedSvgSource = null;
      _importedSvgFileName = null;
      _routeWidthMm = null;
      _routeHeightMm = null;
      _routeRotationDegrees = 0;
      _routeCenterX = _machineLimits.maxX / 2;
      _routeCenterY = _machineLimits.maxY / 2;
      _importedDrawingLabel = null;
      _drawingStrokes.add([point]);
    });
  }

  void _extendDrawingStroke(Offset point) {
    if (_controller.isDrawing || _drawingStrokes.isEmpty) {
      return;
    }
    final stroke = _drawingStrokes.last;
    if ((stroke.last - point).distance < .55) {
      return;
    }
    setState(() => stroke.add(point));
  }

  void _finishDrawingStroke() {
    if (_drawingStrokes.isNotEmpty && _drawingStrokes.last.length < 2) {
      setState(() => _drawingStrokes.removeLast());
    }
  }

  void _clearDrawing() {
    if (_controller.isDrawing) {
      return;
    }
    setState(() {
      _drawingStrokes.clear();
      _importedDrawingLabel = null;
      _importedBaseStrokes = null;
      _importedSvgSource = null;
      _importedSvgFileName = null;
      _routeWidthMm = null;
      _routeHeightMm = null;
      _routeRotationDegrees = 0;
      _routeCenterX = _machineLimits.maxX / 2;
      _routeCenterY = _machineLimits.maxY / 2;
    });
  }

  Future<void> _setSvgTraceMode(SvgTraceMode mode) async {
    final source = _importedSvgSource;
    setState(() {
      _svgTraceMode = mode;
      if (source != null) {
        _importingDrawing = true;
      }
    });
    if (source == null) {
      return;
    }
    // Deixa o quadro com "CONVERTENDO ROTA…" ser pintado antes de segurar a
    // thread: em SVG com centenas de formas o esqueleto leva alguns segundos.
    await Future<void>.delayed(Duration.zero);
    try {
      final result = PlotImporter.fromSvg(
        source,
        label: _importedSvgFileName ?? 'SVG',
        mode: mode,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _importedBaseStrokes = _asBaseStrokes(result.strokes);
        _importedDrawingLabel = result.label;
      });
      _transformImportedRoute();
    } catch (error) {
      if (mounted) {
        _showMessage('Falha ao trocar o modo do traço: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _importingDrawing = false);
      }
    }
  }

  void _transformImportedRoute({
    double? width,
    double? height,
    double? rotationDegrees,
    double? centerX,
    double? centerY,
  }) {
    final baseStrokes = _importedBaseStrokes;
    final currentWidth = _routeWidthMm;
    final currentHeight = _routeHeightMm;
    if (baseStrokes == null || currentWidth == null || currentHeight == null) {
      return;
    }

    final original = PlotImporter.measure(baseStrokes);
    var targetWidth = (width ?? currentWidth)
        .clamp(5.0, _machineLimits.maxX)
        .toDouble();
    var targetHeight = (height ?? currentHeight)
        .clamp(5.0, _machineLimits.maxY)
        .toDouble();
    final targetRotation = (rotationDegrees ?? _routeRotationDegrees)
        .clamp(0.0, 360.0)
        .toDouble();
    if (_lockRouteProportions) {
      if (width != null) {
        targetHeight = targetWidth * original.height / original.width;
      } else if (height != null) {
        targetWidth = targetHeight * original.width / original.height;
      }
    }
    final fit = math.min(
      1.0,
      math.min(
        _machineLimits.maxX / targetWidth,
        _machineLimits.maxY / targetHeight,
      ),
    );
    targetWidth *= fit;
    targetHeight *= fit;

    final centered = PlotImporter.resizeRotateAndCenter(
      baseStrokes,
      width: targetWidth,
      height: targetHeight,
      rotationDegrees: targetRotation,
      maxX: _machineLimits.maxX,
      maxY: _machineLimits.maxY,
    );
    final footprint = PlotImporter.measure(centered);
    final halfWidth = (footprint.width / 2)
        .clamp(0.0, _machineLimits.maxX / 2)
        .toDouble();
    final halfHeight = (footprint.height / 2)
        .clamp(0.0, _machineLimits.maxY / 2)
        .toDouble();
    final targetCenterX = (centerX ?? _routeCenterX)
        .clamp(halfWidth, _machineLimits.maxX - halfWidth)
        .toDouble();
    final targetCenterY = (centerY ?? _routeCenterY)
        .clamp(halfHeight, _machineLimits.maxY - halfHeight)
        .toDouble();
    final transformed = PlotImporter.resizeRotateAndCenter(
      baseStrokes,
      width: targetWidth,
      height: targetHeight,
      rotationDegrees: targetRotation,
      center: Offset(targetCenterX, targetCenterY),
      maxX: _machineLimits.maxX,
      maxY: _machineLimits.maxY,
    );
    setState(() {
      _drawingStrokes
        ..clear()
        ..addAll(transformed);
      _routeWidthMm = targetWidth;
      _routeHeightMm = targetHeight;
      _routeRotationDegrees = targetRotation;
      _routeCenterX = targetCenterX;
      _routeCenterY = targetCenterY;
    });
  }

  void _fitImportedRouteToBed() {
    final baseStrokes = _importedBaseStrokes;
    if (baseStrokes == null) {
      return;
    }
    final dimensions = PlotImporter.measure(baseStrokes);
    final scale = math.min(
      _machineLimits.maxX / dimensions.width,
      _machineLimits.maxY / dimensions.height,
    );
    _transformImportedRoute(
      width: dimensions.width * scale,
      height: dimensions.height * scale,
    );
  }

  Future<void> _importDrawing({required bool svg}) async {
    if (_controller.isDrawing || _importingDrawing) {
      return;
    }
    final file = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(
          label: svg ? 'SVG vetorial' : 'Imagem preto e branco',
          extensions: svg
              ? const ['svg']
              : const ['png', 'jpg', 'jpeg', 'bmp', 'webp'],
        ),
      ],
      confirmButtonText: 'IMPORTAR ROTA',
    );
    if (file == null || !mounted) {
      return;
    }
    setState(() => _importingDrawing = true);
    try {
      final bytes = await file.readAsBytes();
      final result = svg
          ? PlotImporter.fromSvg(
              utf8.decode(bytes),
              label: file.name,
              mode: _svgTraceMode,
            )
          : await PlotImporter.fromMonochromeImage(
              bytes,
              label: file.name,
              threshold: _imageThreshold,
            );
      if (!mounted) {
        return;
      }
      if (_drawingStrokes.isNotEmpty) {
        final replace = await _confirm(
          title: 'Substituir rota atual?',
          body:
              '${result.label} gerou ${result.strokes.length} traço(s) e '
              '${result.segmentCount} segmento(s).\n\nO desenho atual será substituído.',
          accept: 'SUBSTITUIR',
        );
        if (!replace || !mounted) {
          return;
        }
      }
      setState(() {
        final baseStrokes = _asBaseStrokes(result.strokes);
        final dimensions = PlotImporter.measure(baseStrokes);
        final initialScale =
            _initialImportLongestSideMm /
            math.max(dimensions.width, dimensions.height);
        final initialWidth = dimensions.width * initialScale;
        final initialHeight = dimensions.height * initialScale;
        final initialRoute = PlotImporter.resizeRotateAndCenter(
          baseStrokes,
          width: initialWidth,
          height: initialHeight,
          rotationDegrees: 0,
          maxX: _machineLimits.maxX,
          maxY: _machineLimits.maxY,
        );
        _drawingStrokes
          ..clear()
          ..addAll(initialRoute);
        _importedDrawingLabel = result.label;
        _importedBaseStrokes = baseStrokes;
        _importedSvgSource = svg ? utf8.decode(bytes) : null;
        _importedSvgFileName = svg ? file.name : null;
        _routeWidthMm = initialWidth;
        _routeHeightMm = initialHeight;
        _routeRotationDegrees = 0;
        _routeCenterX = _machineLimits.maxX / 2;
        _routeCenterY = _machineLimits.maxY / 2;
      });
      _showMessage(
        '${result.label} importado: ${result.segmentCount} segmentos.',
      );
    } catch (error) {
      if (mounted) {
        _showMessage('Falha ao importar: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _importingDrawing = false);
      }
    }
  }

  Future<void> _sendDrawing() async {
    final strokeCount = _drawingStrokes
        .where((stroke) => stroke.length >= 2)
        .length;
    final segmentCount = _drawingStrokes.fold<int>(
      0,
      (total, stroke) => total + math.max(0, stroke.length - 1),
    );
    if (!_controller.isFullyReferenced) {
      _showMessage('Faça HOME XY e HOME Z antes de enviar o desenho.');
      return;
    }
    if (strokeCount == 0) {
      _showMessage('Desenhe ao menos um traço antes de enviar.');
      return;
    }
    final isOutsideProfile = _drawingStrokes
        .expand((stroke) => stroke)
        .any(
          (point) =>
              point.dx < 0 ||
              point.dy < 0 ||
              point.dx > _machineLimits.maxX ||
              point.dy > _machineLimits.maxY,
        );
    if (isOutsideProfile) {
      _showMessage(
        'O desenho excede o perfil ${_machineLimits.label}. Ajuste a rota '
        'antes de enviar.',
      );
      return;
    }
    final proceed = await _confirm(
      title: 'Enviar desenho para a máquina?',
      body:
          '$strokeCount traço(s) • $segmentCount segmento(s)\n\n'
          'A caneta desenhará em Z${_drawingZ.toStringAsFixed(1)} mm e elevará '
          '${_penLiftMm.toStringAsFixed(1)} mm entre traços '
          '(Z${(_drawingZ + _penLiftMm).toStringAsFixed(1)} mm).\n\n'
          'Som ao concluir: ${_completionSoundLabel(_completionSound)}.\n\n'
          'Confirme que uma caneta/ferramenta está montada e que Z0 foi calibrado sobre o papel.',
      accept: 'INICIAR DESENHO',
    );
    if (!proceed || !mounted) {
      return;
    }
    await _perform(
      () => _controller.draw(
        strokes: _drawingStrokes
            .map(
              (stroke) => stroke
                  .map((point) => DrawingPoint(x: point.dx, y: point.dy))
                  .toList(growable: false),
            )
            .toList(growable: false),
        penLiftMm: _penLiftMm,
        drawingZ: _drawingZ,
        feedrateMmPerSecond: _feedrate,
        completionSound: _completionSound,
      ),
    );
  }

  Future<void> _importJob() async {
    if (_importingJob || _controller.isBusy) {
      return;
    }
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'G-code de CAM',
          extensions: ['nc', 'gcode', 'gco', 'ngc', 'tap', 'cnc'],
        ),
      ],
      confirmButtonText: 'IMPORTAR TRABALHO',
    );
    if (file == null || !mounted) {
      return;
    }
    setState(() => _importingJob = true);
    try {
      final source = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      final job = GcodeImporter.parse(
        source,
        name: file.name,
        zOffsetMm: _jobZOffsetMm,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _jobSource = source;
        _job = job;
        _jobRemoteName = GcodeJob.toShortFilename(file.name);
        _jobUploadedName = null;
      });
      _showMessage(
        '${job.commandCount} comandos, '
        '${job.cutLengthMm.toStringAsFixed(0)} mm de corte.',
      );
    } catch (error) {
      if (mounted) {
        _showMessage('Não foi possível ler o arquivo: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _importingJob = false);
      }
    }
  }

  void _setJobZOffset(double value) {
    final source = _jobSource;
    final job = _job;
    if (source == null || job == null) {
      return;
    }
    setState(() {
      _jobZOffsetMm = value;
      _job = GcodeImporter.parse(source, name: job.name, zOffsetMm: value);
      // O arquivo já gravado no cartão passa a não corresponder ao preview.
      _jobUploadedName = null;
    });
  }

  Future<void> _uploadJob() async {
    final job = _job;
    final remoteName = _jobRemoteName;
    if (job == null || remoteName == null) {
      return;
    }
    final violations = job.violationsFor(_machineLimits);
    if (violations.isNotEmpty) {
      _showMessage(violations.first);
      return;
    }
    final gcode = GcodeImporter.render(job.commands, name: job.name);
    await _perform(() async {
      await _controller.uploadJob(gcode: gcode, remoteName: remoteName);
      if (mounted) {
        setState(() => _jobUploadedName = remoteName);
      }
    });
  }

  Future<void> _startJob() async {
    final remoteName = _jobUploadedName;
    final job = _job;
    if (remoteName == null || job == null) {
      return;
    }
    final confirmed = await _confirm(
      title: 'Iniciar o corte?',
      body:
          'A máquina vai executar $remoteName direto do cartão, sem depender '
          'do computador.\n\nConfira antes: placa fixada, fresa firme, zero '
          'de Z na superfície do cobre e o caminho livre até '
          'X${job.bounds.maxX.toStringAsFixed(0)} '
          'Y${job.bounds.maxY.toStringAsFixed(0)}.',
      accept: 'INICIAR',
    );
    if (!confirmed) {
      return;
    }
    await _perform(() => _controller.startSdJob(remoteName));
  }

  Future<void> _abortJob() async {
    final confirmed = await _confirm(
      title: 'Abortar o corte?',
      body:
          'O trabalho para onde estiver e a ferramenta é desligada. A fresa '
          'fica dentro do material: suba o Z antes de retirar a placa.',
      accept: 'ABORTAR',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    await _perform(_controller.abortSdJob);
  }

  Future<void> _spindleOn() async {
    final confirmed = await _confirm(
      title: 'Ligar a ferramenta?',
      body:
          'A microrretífica parte imediatamente e leva alguns segundos até a '
          'rotação de trabalho. Afaste as mãos e confirme que a fresa está '
          'presa na pinça.',
      accept: 'LIGAR',
      destructive: true,
    );
    if (!confirmed) {
      return;
    }
    await _perform(_controller.spindleOn);
  }

  Future<void> _sendManual() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      return;
    }
    final proceed = await _confirm(
      title: 'Executar G-code manual?',
      body:
          'Comando: $command\n\nExecute somente comandos que você revisou. '
          'Este painel não limita comandos manuais.',
      accept: 'ENVIAR',
      destructive: true,
    );
    if (proceed && mounted) {
      await _perform(() => _controller.sendManualCommand(command));
      if (mounted) {
        _commandController.clear();
      }
    }
  }

  Future<void> _autoConnect() async {
    await _refreshPorts();
    final port = _preferredPort(_controller.ports);
    if (port == null) {
      _showMessage('Nenhuma porta serial foi encontrada.');
      return;
    }
    if (mounted) {
      setState(() => _selectedPort = port);
    }
    if (_controller.isConnected) {
      await _perform(_controller.disconnect);
    }
    await _perform(() => _controller.connect(port, baudRate: _baudRate));
  }

  Future<void> _openDeviceSettings() async {
    await _refreshPorts();
    if (!mounted) {
      return;
    }
    final selection = await showDialog<_DeviceSelection>(
      context: context,
      builder: (context) => _DeviceSettingsDialog(
        models: const [
          'Ender-3 Neo / NeoCNC',
          'Ender-3 V2',
          'Ender-3 (original)',
          'Outro equipamento Marlin',
        ],
        ports: _controller.ports,
        initialModel: _printerModel,
        initialPort: _selectedPort,
        initialBaudRate: _baudRate,
        initialLimits: _machineLimits,
      ),
    );
    if (selection == null || !mounted) {
      return;
    }

    final port = selection.autoPort
        ? _preferredPort(_controller.ports)
        : selection.port;
    setState(() {
      _printerModel = selection.model;
      _selectedPort = port;
      _baudRate = selection.baudRate;
      _machineLimits = selection.limits;
      _mapTarget = _mapTarget == null
          ? null
          : Offset(
              _mapTarget!.dx.clamp(0.0, selection.limits.maxX).toDouble(),
              _mapTarget!.dy.clamp(0.0, selection.limits.maxY).toDouble(),
            );
      _routeCenterX = _routeCenterX
          .clamp(0.0, selection.limits.maxX)
          .toDouble();
      _routeCenterY = _routeCenterY
          .clamp(0.0, selection.limits.maxY)
          .toDouble();
      _jobUploadedName = null;
    });
    if (selection.connectNow && port != null) {
      if (_controller.isConnected) {
        await _perform(_controller.disconnect);
      }
      await _perform(() => _controller.connect(port, baudRate: _baudRate));
    }
  }

  Future<void> _openInterfaceSettings() async {
    var compact = _compactControls;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('INTERFACE'),
          content: SwitchListTile(
            value: compact,
            onChanged: (value) => setDialogState(() => compact = value),
            title: const Text('CONTROLES COMPACTOS'),
            subtitle: const Text('Reduz espaços entre controles e painéis.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('CANCELAR'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('APLICAR'),
            ),
          ],
        ),
      ),
    );
    if (save == true && mounted) {
      setState(() => _compactControls = compact);
    }
  }

  void _selectTab(int index) {
    setState(() => _selectedTab = _ControlTab.values[index]);
    Navigator.of(context).pop();
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final snapshot = _controller.snapshot;
        return Scaffold(
          drawer: _ControlDrawer(
            selectedTab: _selectedTab,
            printerModel: _printerModel,
            port: _selectedPort,
            connected: snapshot.isConnected,
            onDestinationSelected: _selectTab,
            onDeviceSettings: _openDeviceSettings,
          ),
          appBar: AppBar(
            backgroundColor: NeoCncColors.surface,
            foregroundColor: NeoCncColors.ink,
            elevation: 0,
            centerTitle: false,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NEOCNC / CONTROL DESK',
                  style: TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                Text(
                  _printerModel,
                  style: const TextStyle(
                    color: NeoCncColors.muted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Dispositivo e porta USB',
                onPressed: _openDeviceSettings,
                icon: Icon(
                  snapshot.isConnected
                      ? Icons.usb_rounded
                      : Icons.usb_off_rounded,
                  color: snapshot.isConnected
                      ? NeoCncColors.cyan
                      : NeoCncColors.muted,
                ),
              ),
              IconButton(
                tooltip: 'Conexão automática USB',
                onPressed: _autoConnect,
                icon: const Icon(Icons.auto_mode_rounded),
              ),
              IconButton(
                tooltip: 'Configurações da interface',
                onPressed: _openInterfaceSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
              IconButton(
                tooltip: 'Parada de emergência',
                onPressed: snapshot.isConnected
                    ? () => _perform(_controller.emergencyStop)
                    : null,
                color: NeoCncColors.danger,
                icon: const Icon(Icons.emergency_rounded),
              ),
              IconButton(
                tooltip: snapshot.isConnected ? 'Desconectar' : 'Conectar',
                onPressed: _connectOrDisconnect,
                icon: Icon(
                  snapshot.isConnected
                      ? Icons.link_off_rounded
                      : Icons.link_rounded,
                ),
              ),
            ],
          ),
          body: Theme(
            data: Theme.of(context).copyWith(
              visualDensity: _compactControls
                  ? VisualDensity.compact
                  : VisualDensity.standard,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MachineControlStrip(
                      snapshot: snapshot,
                      feedrate: _feedrate,
                      onFeedrateChanged: (value) =>
                          setState(() => _feedrate = value),
                      onHome: _home,
                      onEnable: () => _perform(_controller.enableSteppers),
                      onDisable: () => _perform(_controller.disableSteppers),
                    ),
                    const SizedBox(height: 20),
                    _PageTitle(tab: _selectedTab),
                    const SizedBox(height: 10),
                    _buildPage(snapshot, constraints),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPage(PrinterSnapshot snapshot, BoxConstraints constraints) {
    final secondaryWidth = constraints.maxWidth >= 1050
        ? (constraints.maxWidth - 12) / 3
        : constraints.maxWidth;
    return switch (_selectedTab) {
      _ControlTab.map => _WorkMapPanel(
        snapshot: snapshot,
        armed: _mapArmed,
        xyReferenced: _controller.isXyReferenced,
        target: _mapTarget,
        limits: _machineLimits,
        onArmedChanged: (armed) {
          if (!_controller.isXyReferenced && armed) {
            _showMessage('Faça HOME XY antes de armar o mapa.');
            return;
          }
          setState(() => _mapArmed = armed);
        },
        onTarget: _moveFromMap,
      ),
      _ControlTab.drawing => _DrawingPanel(
        snapshot: snapshot,
        strokes: _drawingStrokes,
        limits: _machineLimits,
        penLiftMm: _penLiftMm,
        drawingZ: _drawingZ,
        feedrate: _feedrate,
        fullyReferenced: _controller.isFullyReferenced,
        running: _controller.isDrawing,
        completedSegments: _controller.drawingCompletedSegments,
        segmentCount: _controller.drawingSegmentCount,
        importing: _importingDrawing,
        importedLabel: _importedDrawingLabel,
        imageThreshold: _imageThreshold,
        svgTraceMode: _svgTraceMode,
        routePreview: _routePreview,
        showRoutePreview: _showRoutePreview,
        previewProgress: _previewController.value,
        previewPlaying: _previewController.isAnimating,
        onShowRoutePreviewChanged: _setRoutePreviewVisible,
        onTogglePreviewPlayback: _toggleRoutePreviewPlayback,
        onSeekPreview: _seekRoutePreview,
        onOptimizeRoute: _optimizeCurrentRoute,
        completionSound: _completionSound,
        routeWidthMm: _routeWidthMm,
        routeHeightMm: _routeHeightMm,
        routeRotationDegrees: _routeRotationDegrees,
        routeCenterX: _routeCenterX,
        routeCenterY: _routeCenterY,
        lockRouteProportions: _lockRouteProportions,
        onPenLiftChanged: (value) => setState(() => _penLiftMm = value),
        onDrawingZChanged: (value) => setState(() => _drawingZ = value),
        onCompletionSoundChanged: (sound) =>
            setState(() => _completionSound = sound),
        onStrokeStart: _startDrawingStroke,
        onStrokeExtend: _extendDrawingStroke,
        onStrokeEnd: _finishDrawingStroke,
        onClear: _clearDrawing,
        onImageThresholdChanged: (value) =>
            setState(() => _imageThreshold = value),
        onSvgTraceModeChanged: _setSvgTraceMode,
        onRouteWidthChanged: (value) => _transformImportedRoute(width: value),
        onRouteHeightChanged: (value) => _transformImportedRoute(height: value),
        onRouteRotationChanged: (value) =>
            _transformImportedRoute(rotationDegrees: value),
        onRouteCenterXChanged: (value) =>
            _transformImportedRoute(centerX: value),
        onRouteCenterYChanged: (value) =>
            _transformImportedRoute(centerY: value),
        onRouteMove: (delta) => _transformImportedRoute(
          centerX: _routeCenterX + delta.dx,
          centerY: _routeCenterY + delta.dy,
        ),
        onFitRouteToBed: _fitImportedRouteToBed,
        onRouteProportionsLockedChanged: (value) =>
            setState(() => _lockRouteProportions = value),
        onImportRaster: () => _importDrawing(svg: false),
        onImportSvg: () => _importDrawing(svg: true),
        onSend: _sendDrawing,
      ),
      _ControlTab.job => JobPanel(
        job: _job,
        limits: _machineLimits,
        violations: _job?.violationsFor(_machineLimits) ?? const [],
        remoteName: _jobRemoteName,
        zOffsetMm: _jobZOffsetMm,
        importing: _importingJob,
        uploading: _controller.isUploading,
        uploadProgress: _controller.uploadProgress,
        uploadedName: _jobUploadedName,
        connected: snapshot.isConnected,
        fullyReferenced: _controller.isFullyReferenced,
        sdJobName: _controller.sdJobName,
        sdStatus: snapshot.sdStatus,
        sdProgress: snapshot.sdProgress,
        onImport: _importJob,
        onZOffsetChanged: (value) => setState(() => _jobZOffsetMm = value),
        onZOffsetCommitted: _setJobZOffset,
        onUpload: _uploadJob,
        onStart: _startJob,
        onPause: () => _perform(_controller.pauseSdJob),
        onResume: () => _perform(_controller.resumeSdJob),
        onAbort: _abortJob,
        onSpindleOn: _spindleOn,
        onSpindleOff: () => _perform(_controller.spindleOff),
      ),
      _ControlTab.relativeMotion => _MotionPanel(
        enabled: snapshot.isConnected,
        step: _step,
        feedrate: _feedrate,
        onStepChanged: (step) => setState(() => _step = step),
        onJog: (axis, distance) => _perform(
          () => _controller.jog(
            axis: axis,
            millimeters: distance,
            feedrateMmPerSecond: _feedrate,
          ),
        ),
      ),
      _ControlTab.logs => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: secondaryWidth,
            child: _TemperaturePanel(snapshot: snapshot),
          ),
          SizedBox(
            width: secondaryWidth,
            child: _SensorsPanel(snapshot: snapshot),
          ),
          SizedBox(
            width: constraints.maxWidth,
            child: _ConsolePanel(log: _controller.log),
          ),
          SizedBox(
            width: constraints.maxWidth,
            child: _ManualCommandPanel(
              enabled: snapshot.isConnected,
              controller: _commandController,
              onSend: _sendManual,
            ),
          ),
        ],
      ),
    };
  }
}

class _ControlDrawer extends StatelessWidget {
  const _ControlDrawer({
    required this.selectedTab,
    required this.printerModel,
    required this.port,
    required this.connected,
    required this.onDestinationSelected,
    required this.onDeviceSettings,
  });

  final _ControlTab selectedTab;
  final String printerModel;
  final String? port;
  final bool connected;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onDeviceSettings;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: NeoCncColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: NeoCncColors.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MÁQUINA ATIVA',
                    style: TextStyle(
                      color: NeoCncColors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    printerModel,
                    style: const TextStyle(
                      color: NeoCncColors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    connected
                        ? '● ${port ?? 'SERIAL'} CONECTADA'
                        : '○ SEM CONEXÃO',
                    style: TextStyle(
                      color: connected ? NeoCncColors.cyan : NeoCncColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: NavigationDrawer(
                selectedIndex: selectedTab.index,
                onDestinationSelected: onDestinationSelected,
                children: const [
                  NavigationDrawerDestination(
                    icon: Icon(Icons.map_outlined),
                    selectedIcon: Icon(Icons.map_rounded),
                    label: Text('MAPA XY'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.gesture_outlined),
                    selectedIcon: Icon(Icons.gesture_rounded),
                    label: Text('DESENHO XY'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.precision_manufacturing_outlined),
                    selectedIcon: Icon(Icons.precision_manufacturing_rounded),
                    label: Text('CORTE / CAM'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.open_with_outlined),
                    selectedIcon: Icon(Icons.open_with_rounded),
                    label: Text('MOVIMENTO'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.terminal_outlined),
                    selectedIcon: Icon(Icons.terminal_rounded),
                    label: Text('LOGS E CONSOLE'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_input_component_rounded),
              title: const Text('DISPOSITIVO E USB'),
              subtitle: const Text(
                'Modelo, porta e conexão automática',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: onDeviceSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _MachineControlStrip extends StatelessWidget {
  const _MachineControlStrip({
    required this.snapshot,
    required this.feedrate,
    required this.onFeedrateChanged,
    required this.onHome,
    required this.onEnable,
    required this.onDisable,
  });

  final PrinterSnapshot snapshot;
  final double feedrate;
  final ValueChanged<double> onFeedrateChanged;
  final ValueChanged<String?> onHome;
  final VoidCallback onEnable;
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    final enabled = snapshot.isConnected;
    return _Panel(
      label: 'CONTROLE GLOBAL DA MÁQUINA',
      icon: Icons.precision_manufacturing_rounded,
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _GlobalCoordinate(axis: 'X', value: snapshot.x),
          _GlobalCoordinate(axis: 'Y', value: snapshot.y),
          _GlobalCoordinate(axis: 'Z', value: snapshot.z),
          SizedBox(
            width: 310,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VELOCIDADE GLOBAL  ${feedrate.round()} mm/s',
                  style: const TextStyle(
                    color: NeoCncColors.muted,
                    fontSize: 11,
                  ),
                ),
                Slider(
                  value: feedrate,
                  min: 5,
                  max: 300,
                  divisions: 295,
                  label: '${feedrate.round()} mm/s',
                  onChanged: enabled ? onFeedrateChanged : null,
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _HomeButton(
                label: 'X',
                enabled: enabled,
                onPressed: () => onHome('X'),
              ),
              _HomeButton(
                label: 'Y',
                enabled: enabled,
                onPressed: () => onHome('Y'),
              ),
              _HomeButton(
                label: 'Z',
                enabled: enabled,
                onPressed: () => onHome('Z'),
              ),
              _HomeButton(
                label: 'XY',
                enabled: enabled,
                onPressed: () => onHome('X Y'),
              ),
              FilledButton(
                onPressed: enabled ? () => onHome(null) : null,
                child: const Text('HOME ALL'),
              ),
              OutlinedButton(
                onPressed: enabled ? onEnable : null,
                child: const Text('M17'),
              ),
              OutlinedButton(
                onPressed: enabled ? onDisable : null,
                child: const Text('M18'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlobalCoordinate extends StatelessWidget {
  const _GlobalCoordinate({required this.axis, required this.value});

  final String axis;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 102,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: NeoCncColors.canvas,
        border: Border.all(color: NeoCncColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            axis,
            style: const TextStyle(
              color: NeoCncColors.amber,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const Text(
            'mm',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      child: Text('HOME $label'),
    );
  }
}

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.tab});

  final _ControlTab tab;

  @override
  Widget build(BuildContext context) {
    final (title, description) = switch (tab) {
      _ControlTab.map => (
        'MAPA XY',
        'Destino absoluto dentro da área de trabalho.',
      ),
      _ControlTab.drawing => (
        'DESENHO XY',
        'Trace no tapete; a máquina reproduz com a ferramenta em Z.',
      ),
      _ControlTab.job => (
        'TRABALHO DE CORTE',
        'Importa G-code de CAM, grava no cartão e executa da própria máquina.',
      ),
      _ControlTab.relativeMotion => (
        'MOVIMENTO RELATIVO',
        'Jog por passo configurável usando a velocidade global.',
      ),
      _ControlTab.logs => (
        'LOGS E CONSOLE',
        'Telemetria, sensores, mensagens Marlin e G-code manual.',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: NeoCncColors.amber,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          description,
          style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _DeviceSelection {
  const _DeviceSelection({
    required this.model,
    required this.port,
    required this.baudRate,
    required this.autoPort,
    required this.connectNow,
    required this.limits,
  });

  final String model;
  final String? port;
  final int baudRate;
  final bool autoPort;
  final bool connectNow;
  final MachineLimits limits;
}

class _DeviceSettingsDialog extends StatefulWidget {
  const _DeviceSettingsDialog({
    required this.models,
    required this.ports,
    required this.initialModel,
    required this.initialPort,
    required this.initialBaudRate,
    required this.initialLimits,
  });

  final List<String> models;
  final List<String> ports;
  final String initialModel;
  final String? initialPort;
  final int initialBaudRate;
  final MachineLimits initialLimits;

  @override
  State<_DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<_DeviceSettingsDialog> {
  late String _model = widget.initialModel;
  late String? _port = widget.initialPort;
  late int _baudRate = widget.initialBaudRate;
  late MachineLimits _limits = widget.initialLimits;
  bool _autoPort = true;
  bool _connectNow = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DISPOSITIVO E PORTA USB'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _model,
              decoration: const InputDecoration(labelText: 'MODELO DA MÁQUINA'),
              items: widget.models
                  .map(
                    (model) =>
                        DropdownMenuItem(value: model, child: Text(model)),
                  )
                  .toList(),
              onChanged: (model) {
                if (model != null) {
                  setState(() => _model = model);
                }
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ESCOLHER USB AUTOMATICAMENTE'),
              subtitle: const Text('Prioriza /dev/ttyUSB* e /dev/ttyACM*.'),
              value: _autoPort,
              onChanged: (value) => setState(() => _autoPort = value),
            ),
            if (!_autoPort) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: _port,
                decoration: const InputDecoration(labelText: 'PORTA SERIAL'),
                items: widget.ports
                    .map(
                      (port) =>
                          DropdownMenuItem(value: port, child: Text(port)),
                    )
                    .toList(),
                onChanged: (port) => setState(() => _port = port),
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _baudRate,
              decoration: const InputDecoration(
                labelText: 'VELOCIDADE DA SERIAL',
                helperText:
                    'Ender-3 V4.2.2/GD32 usa 115200. Use taxas maiores apenas em máquinas validadas.',
              ),
              items: UsbSerialTransport.supportedBaudRates
                  .map(
                    (baud) => DropdownMenuItem(
                      value: baud,
                      child: Text('$baud baud'),
                    ),
                  )
                  .toList(),
              onChanged: (baud) {
                if (baud != null) {
                  setState(() => _baudRate = baud);
                }
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<MachineLimits>(
              initialValue: _limits,
              decoration: const InputDecoration(
                labelText: 'ÁREA ÚTIL / LIMITE CAM',
                helperText:
                    'Selecione o mesmo perfil gravado no firmware da máquina.',
              ),
              items: MachineLimits.profiles
                  .map(
                    (limits) => DropdownMenuItem(
                      value: limits,
                      child: Text(limits.label),
                    ),
                  )
                  .toList(),
              onChanged: (limits) {
                if (limits != null) {
                  setState(() => _limits = limits);
                }
              },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('CONECTAR APÓS SALVAR'),
              value: _connectNow,
              onChanged: (value) => setState(() => _connectNow = value),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'A escolha de modelo identifica o equipamento no app; a comunicação continua Marlin serial.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCELAR'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _DeviceSelection(
              model: _model,
              port: _port,
              baudRate: _baudRate,
              autoPort: _autoPort,
              connectNow: _connectNow,
              limits: _limits,
            ),
          ),
          child: const Text('SALVAR'),
        ),
      ],
    );
  }
}

class _TemperaturePanel extends StatelessWidget {
  const _TemperaturePanel({required this.snapshot});

  final PrinterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'TEMPERATURAS',
      icon: Icons.thermostat_rounded,
      child: Column(
        children: [
          _TemperatureLine(
            label: 'BICO',
            actual: snapshot.hotendActual,
            target: snapshot.hotendTarget,
          ),
          const Divider(height: 22),
          _TemperatureLine(
            label: 'MESA',
            actual: snapshot.bedActual,
            target: snapshot.bedTarget,
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Somente telemetria nesta versão.',
              style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemperatureLine extends StatelessWidget {
  const _TemperatureLine({
    required this.label,
    required this.actual,
    required this.target,
  });

  final String label;
  final double? actual;
  final double? target;

  @override
  Widget build(BuildContext context) {
    final measured = actual == null ? '—' : actual!.toStringAsFixed(1);
    final setpoint = target == null ? '—' : target!.toStringAsFixed(1);
    return Row(
      children: [
        Text(label, style: const TextStyle(color: NeoCncColors.muted)),
        const Spacer(),
        Text(
          '$measured °C',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(' / $setpoint', style: const TextStyle(color: NeoCncColors.muted)),
      ],
    );
  }
}

class _WorkMapPanel extends StatelessWidget {
  const _WorkMapPanel({
    required this.snapshot,
    required this.armed,
    required this.xyReferenced,
    required this.target,
    required this.limits,
    required this.onArmedChanged,
    required this.onTarget,
  });

  final PrinterSnapshot snapshot;
  final bool armed;
  final bool xyReferenced;
  final Offset? target;
  final MachineLimits limits;
  final ValueChanged<bool> onArmedChanged;
  final Future<void> Function(Offset target) onTarget;

  @override
  Widget build(BuildContext context) {
    final canArm = snapshot.isConnected && xyReferenced;
    final targetLabel = target == null
        ? '—'
        : 'X${target!.dx.toStringAsFixed(1)}  Y${target!.dy.toStringAsFixed(1)} mm';

    return _Panel(
      label: 'MAPA XY / DESTINO ABSOLUTO',
      icon: Icons.map_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                xyReferenced
                    ? 'ÁREA ÚTIL  X0–${limits.maxX.round()} • '
                          'Y0–${limits.maxY.round()} mm'
                    : 'REFERENCIE XY PARA LIBERAR O MAPA',
                style: TextStyle(
                  color: xyReferenced ? NeoCncColors.cyan : NeoCncColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    armed ? 'MOVIMENTO ARMADO' : 'MAPA DESARMADO',
                    style: TextStyle(
                      color: armed ? NeoCncColors.amber : NeoCncColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Switch(
                    value: armed,
                    onChanged: canArm ? onArmedChanged : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(360.0, constraints.maxWidth);
              return Center(
                child: SizedBox.square(
                  dimension: side,
                  child: LayoutBuilder(
                    builder: (context, mapConstraints) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        final point = details.localPosition;
                        final x =
                            (point.dx / mapConstraints.maxWidth * limits.maxX)
                                .clamp(0.0, limits.maxX)
                                .toDouble();
                        final y =
                            (limits.maxY -
                                    point.dy /
                                        mapConstraints.maxHeight *
                                        limits.maxY)
                                .clamp(0.0, limits.maxY)
                                .toDouble();
                        unawaited(onTarget(Offset(x, y)));
                      },
                      child: CustomPaint(
                        painter: _WorkMapPainter(
                          current: xyReferenced
                              ? Offset(snapshot.x, snapshot.y)
                              : null,
                          target: target,
                          limits: limits,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              const Text(
                '◉ posição atual',
                style: TextStyle(color: NeoCncColors.cyan, fontSize: 11),
              ),
              const Text(
                '◎ destino',
                style: TextStyle(color: NeoCncColors.amber, fontSize: 11),
              ),
              Text(
                'DESTINO  $targetLabel',
                style: const TextStyle(color: NeoCncColors.ink, fontSize: 11),
              ),
              const Text(
                'MALHA 20 mm',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Com o mapa armado, cada clique envia um G0 absoluto na velocidade definida abaixo.',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WorkMapPainter extends CustomPainter {
  const _WorkMapPainter({
    required this.current,
    required this.target,
    required this.limits,
  });

  final Offset? current;
  final Offset? target;
  final MachineLimits limits;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final background = Paint()..color = NeoCncColors.canvas;
    final border = Paint()
      ..color = NeoCncColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .55)
      ..strokeWidth = 1;

    canvas.drawRect(area, background);
    for (var mm = 20.0; mm < limits.maxX || mm < limits.maxY; mm += 20) {
      if (mm < limits.maxX) {
        final x = mm / limits.maxX * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
      if (mm < limits.maxY) {
        final y = size.height - mm / limits.maxY * size.height;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
    }
    canvas.drawRect(area.deflate(.75), border);

    final machinePosition = current;
    if (machinePosition != null && _isWithin(machinePosition)) {
      _drawCurrent(canvas, _toCanvas(machinePosition, size));
    }
    final destination = target;
    if (destination != null && _isWithin(destination)) {
      _drawTarget(canvas, _toCanvas(destination, size));
    }
  }

  Offset _toCanvas(Offset point, Size size) {
    return Offset(
      point.dx / limits.maxX * size.width,
      size.height - point.dy / limits.maxY * size.height,
    );
  }

  bool _isWithin(Offset point) {
    return point.dx >= 0 &&
        point.dx <= limits.maxX &&
        point.dy >= 0 &&
        point.dy <= limits.maxY;
  }

  void _drawCurrent(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = NeoCncColors.cyan
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 8, paint);
    canvas.drawLine(point.translate(-13, 0), point.translate(13, 0), paint);
    canvas.drawLine(point.translate(0, -13), point.translate(0, 13), paint);
  }

  void _drawTarget(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = NeoCncColors.amber
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 10, paint);
    canvas.drawCircle(point, 3, Paint()..color = NeoCncColors.amber);
  }

  @override
  bool shouldRepaint(covariant _WorkMapPainter oldDelegate) {
    return oldDelegate.current != current ||
        oldDelegate.target != target ||
        oldDelegate.limits != limits;
  }
}

class _DrawingPanel extends StatelessWidget {
  const _DrawingPanel({
    required this.snapshot,
    required this.strokes,
    required this.limits,
    required this.penLiftMm,
    required this.drawingZ,
    required this.feedrate,
    required this.fullyReferenced,
    required this.running,
    required this.completedSegments,
    required this.segmentCount,
    required this.importing,
    required this.importedLabel,
    required this.imageThreshold,
    required this.svgTraceMode,
    required this.routePreview,
    required this.showRoutePreview,
    required this.previewProgress,
    required this.previewPlaying,
    required this.onShowRoutePreviewChanged,
    required this.onTogglePreviewPlayback,
    required this.onSeekPreview,
    required this.onOptimizeRoute,
    required this.completionSound,
    required this.routeWidthMm,
    required this.routeHeightMm,
    required this.routeRotationDegrees,
    required this.routeCenterX,
    required this.routeCenterY,
    required this.lockRouteProportions,
    required this.onPenLiftChanged,
    required this.onDrawingZChanged,
    required this.onCompletionSoundChanged,
    required this.onStrokeStart,
    required this.onStrokeExtend,
    required this.onStrokeEnd,
    required this.onClear,
    required this.onImageThresholdChanged,
    required this.onSvgTraceModeChanged,
    required this.onRouteWidthChanged,
    required this.onRouteHeightChanged,
    required this.onRouteRotationChanged,
    required this.onRouteCenterXChanged,
    required this.onRouteCenterYChanged,
    required this.onRouteMove,
    required this.onFitRouteToBed,
    required this.onRouteProportionsLockedChanged,
    required this.onImportRaster,
    required this.onImportSvg,
    required this.onSend,
  });

  final PrinterSnapshot snapshot;
  final List<List<Offset>> strokes;
  final MachineLimits limits;
  final double penLiftMm;
  final double drawingZ;
  final double feedrate;
  final bool fullyReferenced;
  final bool running;
  final int completedSegments;
  final int segmentCount;
  final bool importing;
  final String? importedLabel;
  final double imageThreshold;
  final SvgTraceMode svgTraceMode;
  final RoutePreview routePreview;
  final bool showRoutePreview;
  final double previewProgress;
  final bool previewPlaying;
  final ValueChanged<bool> onShowRoutePreviewChanged;
  final VoidCallback onTogglePreviewPlayback;
  final ValueChanged<double> onSeekPreview;
  final VoidCallback onOptimizeRoute;
  final CompletionSound completionSound;
  final double? routeWidthMm;
  final double? routeHeightMm;
  final double routeRotationDegrees;
  final double routeCenterX;
  final double routeCenterY;
  final bool lockRouteProportions;
  final ValueChanged<double> onPenLiftChanged;
  final ValueChanged<double> onDrawingZChanged;
  final ValueChanged<CompletionSound> onCompletionSoundChanged;
  final ValueChanged<Offset> onStrokeStart;
  final ValueChanged<Offset> onStrokeExtend;
  final VoidCallback onStrokeEnd;
  final VoidCallback onClear;
  final ValueChanged<double> onImageThresholdChanged;
  final ValueChanged<SvgTraceMode> onSvgTraceModeChanged;
  final ValueChanged<double> onRouteWidthChanged;
  final ValueChanged<double> onRouteHeightChanged;
  final ValueChanged<double> onRouteRotationChanged;
  final ValueChanged<double> onRouteCenterXChanged;
  final ValueChanged<double> onRouteCenterYChanged;
  final ValueChanged<Offset> onRouteMove;
  final VoidCallback onFitRouteToBed;
  final ValueChanged<bool> onRouteProportionsLockedChanged;
  final Future<void> Function() onImportRaster;
  final Future<void> Function() onImportSvg;
  final Future<void> Function() onSend;

  int get _strokeCount => strokes.where((stroke) => stroke.length >= 2).length;
  int get _segmentCount => strokes.fold<int>(
    0,
    (total, stroke) => total + math.max(0, stroke.length - 1),
  );

  bool get _canResizeRoute => routeWidthMm != null && routeHeightMm != null;

  double get _routeMaxWidthMm {
    if (!_canResizeRoute || !lockRouteProportions) {
      return limits.maxX;
    }
    return math.min(limits.maxX, limits.maxY * routeWidthMm! / routeHeightMm!);
  }

  double get _routeMaxHeightMm {
    if (!_canResizeRoute || !lockRouteProportions) {
      return limits.maxY;
    }
    return math.min(limits.maxY, limits.maxX * routeHeightMm! / routeWidthMm!);
  }

  double get _routeCenterMinX {
    final width = PlotImporter.measure(strokes).width;
    return (width / 2).clamp(0.0, limits.maxX / 2).toDouble();
  }

  double get _routeCenterMaxX => limits.maxX - _routeCenterMinX;

  double get _routeCenterMinY {
    final height = PlotImporter.measure(strokes).height;
    return (height / 2).clamp(0.0, limits.maxY / 2).toDouble();
  }

  double get _routeCenterMaxY => limits.maxY - _routeCenterMinY;

  @override
  Widget build(BuildContext context) {
    final drawingLocked = running || importing;
    final progress = segmentCount == 0
        ? 0.0
        : (completedSegments / segmentCount).clamp(0.0, 1.0);
    return _Panel(
      label: 'DESENHO LIVRE / PLOTTER XY',
      icon: Icons.gesture_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                fullyReferenced
                    ? 'HOME XY + Z CONFIRMADO'
                    : 'FAÇA HOME XY + HOME Z PARA ENVIAR',
                style: TextStyle(
                  color: fullyReferenced
                      ? NeoCncColors.cyan
                      : NeoCncColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '$_strokeCount TRAÇO(S) • $_segmentCount SEGMENTO(S)',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              if (running)
                const Text(
                  'MÁQUINA DESENHANDO',
                  style: TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (importing)
                const Text(
                  'CONVERTENDO ROTA…',
                  style: TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              if (importedLabel != null && !importing)
                Text(
                  importedLabel!,
                  style: const TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: drawingLocked
                    ? null
                    : () => unawaited(onImportRaster()),
                icon: const Icon(Icons.image_search_rounded),
                label: const Text('IMPORTAR IMAGEM P/B'),
              ),
              OutlinedButton.icon(
                onPressed: drawingLocked
                    ? null
                    : () => unawaited(onImportSvg()),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('IMPORTAR SVG'),
              ),
              SizedBox(
                width: 230,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TRAÇO DO SVG',
                      style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 4),
                    SegmentedButton<SvgTraceMode>(
                      segments: const [
                        ButtonSegment(
                          value: SvgTraceMode.outline,
                          label: Text('BORDA'),
                          tooltip:
                              'Desenha o contorno de cada forma preenchida do SVG.',
                        ),
                        ButtonSegment(
                          value: SvgTraceMode.centerline,
                          label: Text('CENTRO'),
                          tooltip:
                              'Reduz cada forma preenchida à linha central (esqueleto).',
                        ),
                      ],
                      selected: {svgTraceMode},
                      onSelectionChanged: drawingLocked
                          ? null
                          : (selection) =>
                                onSvgTraceModeChanged(selection.first),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 230,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'LIMIAR P/B  ${(imageThreshold * 100).round()}%',
                      style: const TextStyle(
                        color: NeoCncColors.muted,
                        fontSize: 11,
                      ),
                    ),
                    Slider(
                      value: imageThreshold,
                      min: .1,
                      max: .9,
                      divisions: 80,
                      label: '${(imageThreshold * 100).round()}%',
                      onChanged: drawingLocked ? null : onImageThresholdChanged,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          LayoutBuilder(
            builder: (context, constraints) {
              final maxHeight = MediaQuery.sizeOf(context).height * .8;
              final side = math.min(constraints.maxWidth, maxHeight);
              return Center(
                child: SizedBox.square(
                  dimension: side,
                  child: LayoutBuilder(
                    builder: (context, canvasConstraints) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: drawingLocked || _canResizeRoute
                          ? null
                          : (details) => onStrokeStart(
                              _toMachine(
                                details.localPosition,
                                canvasConstraints.biggest,
                              ),
                            ),
                      onPanUpdate: drawingLocked
                          ? null
                          : _canResizeRoute
                          ? (details) => onRouteMove(
                              _toMachineDelta(
                                details.delta,
                                canvasConstraints.biggest,
                              ),
                            )
                          : (details) => onStrokeExtend(
                              _toMachine(
                                details.localPosition,
                                canvasConstraints.biggest,
                              ),
                            ),
                      onPanEnd: drawingLocked || _canResizeRoute
                          ? null
                          : (_) => onStrokeEnd(),
                      onPanCancel: drawingLocked || _canResizeRoute
                          ? null
                          : onStrokeEnd,
                      child: CustomPaint(
                        painter: _DrawingPainter(
                          strokes: strokes,
                          current: fullyReferenced
                              ? Offset(snapshot.x, snapshot.y)
                              : null,
                          limits: limits,
                          preview: showRoutePreview ? routePreview : null,
                          previewProgress: previewProgress,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _RoutePreviewControls(
            preview: routePreview,
            visible: showRoutePreview,
            playing: previewPlaying,
            progress: previewProgress,
            feedrate: feedrate,
            penLiftMm: penLiftMm,
            enabled: !running,
            onVisibleChanged: onShowRoutePreviewChanged,
            onTogglePlayback: onTogglePreviewPlayback,
            onSeek: onSeekPreview,
            onOptimize: onOptimizeRoute,
          ),
          const SizedBox(height: 12),
          if (_canResizeRoute) ...[
            const Text(
              'ARRASTE A ROTA NA PRÉVIA OU AJUSTE OS CONTROLES ABAIXO.',
              style: TextStyle(
                color: NeoCncColors.cyan,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 18,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                SizedBox(
                  width: 250,
                  child: _DrawHeightControl(
                    label: 'LARGURA DA ROTA',
                    value: routeWidthMm!,
                    min: 5,
                    max: _routeMaxWidthMm,
                    divisions: ((_routeMaxWidthMm - 5) * 10)
                        .round()
                        .clamp(1, 2200)
                        .toInt(),
                    onChanged: drawingLocked ? null : onRouteWidthChanged,
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: _DrawHeightControl(
                    label: 'ALTURA DA ROTA',
                    value: routeHeightMm!,
                    min: 5,
                    max: _routeMaxHeightMm,
                    divisions: ((_routeMaxHeightMm - 5) * 10)
                        .round()
                        .clamp(1, 2200)
                        .toInt(),
                    onChanged: drawingLocked ? null : onRouteHeightChanged,
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ROTAÇÃO  ${routeRotationDegrees.round()}°',
                        style: const TextStyle(
                          color: NeoCncColors.muted,
                          fontSize: 11,
                        ),
                      ),
                      Slider(
                        value: routeRotationDegrees,
                        min: 0,
                        max: 360,
                        divisions: 360,
                        label: '${routeRotationDegrees.round()}°',
                        onChanged: drawingLocked
                            ? null
                            : onRouteRotationChanged,
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: _DrawHeightControl(
                    label: 'CENTRO X DA ROTA',
                    value: routeCenterX,
                    min: _routeCenterMinX,
                    max: _routeCenterMaxX,
                    onChanged: drawingLocked ? null : onRouteCenterXChanged,
                  ),
                ),
                SizedBox(
                  width: 250,
                  child: _DrawHeightControl(
                    label: 'CENTRO Y DA ROTA',
                    value: routeCenterY,
                    min: _routeCenterMinY,
                    max: _routeCenterMaxY,
                    onChanged: drawingLocked ? null : onRouteCenterYChanged,
                  ),
                ),
                Tooltip(
                  message: lockRouteProportions
                      ? 'Proporção travada'
                      : 'Proporção livre',
                  child: OutlinedButton.icon(
                    onPressed: drawingLocked
                        ? null
                        : () => onRouteProportionsLockedChanged(
                            !lockRouteProportions,
                          ),
                    icon: Icon(
                      lockRouteProportions
                          ? Icons.lock_outline_rounded
                          : Icons.lock_open_rounded,
                    ),
                    label: Text(
                      lockRouteProportions
                          ? 'PROPORÇÃO TRAVADA'
                          : 'PROPORÇÃO LIVRE',
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: drawingLocked ? null : onFitRouteToBed,
                  icon: const Icon(Icons.fit_screen_rounded),
                  label: const Text('OCUPAR A MESA'),
                ),
                Text(
                  '${routeWidthMm!.toStringAsFixed(1)} × '
                  '${routeHeightMm!.toStringAsFixed(1)} mm',
                  style: const TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (running) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(
              'EXECUTANDO $completedSegments / $segmentCount SEGMENTOS',
              style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 18,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 250,
                child: _DrawHeightControl(
                  label: 'ELEVAÇÃO ENTRE TRAÇOS',
                  value: penLiftMm,
                  min: .5,
                  max: 25,
                  onChanged: drawingLocked ? null : onPenLiftChanged,
                ),
              ),
              SizedBox(
                width: 250,
                child: _DrawHeightControl(
                  label: 'Z DO PAPEL / TRAÇO',
                  value: drawingZ,
                  min: 0,
                  max: 25,
                  onChanged: drawingLocked ? null : onDrawingZChanged,
                ),
              ),
              SizedBox(
                width: 210,
                child: DropdownButtonFormField<CompletionSound>(
                  value: completionSound,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'SOM AO CONCLUIR',
                  ),
                  items: CompletionSound.values
                      .map(
                        (sound) => DropdownMenuItem(
                          value: sound,
                          child: Text(_completionSoundLabel(sound)),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: drawingLocked
                      ? null
                      : (sound) {
                          if (sound != null) {
                            onCompletionSoundChanged(sound);
                          }
                        },
                ),
              ),
              Text(
                'XY  ${feedrate.round()} mm/s\nZ  até 20 mm/s',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
              OutlinedButton.icon(
                onPressed: drawingLocked || strokes.isEmpty ? null : onClear,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('LIMPAR'),
              ),
              FilledButton.icon(
                onPressed: drawingLocked || _strokeCount == 0
                    ? null
                    : () => unawaited(onSend()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('DESENHAR NA MÁQUINA'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Imagem P/B gera o contorno do preto; SVG aceita caminhos e formas. Ao importar, a rota inicia em 100 mm no lado maior, sem ocupar a mesa automaticamente. Ajuste largura, altura, rotação e centro X/Y, ou use OCUPAR A MESA quando decidir preencher o perfil ${limits.label}. Entre traços a caneta sobe a elevação configurada. O buzzer não tem volume por G-code: use BIP CURTO ou SEM SOM para reduzir o incômodo.',
            style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Offset _toMachine(Offset local, Size size) {
    return Offset(
      (local.dx / size.width * limits.maxX).clamp(0.0, limits.maxX).toDouble(),
      (limits.maxY - local.dy / size.height * limits.maxY)
          .clamp(0.0, limits.maxY)
          .toDouble(),
    );
  }

  Offset _toMachineDelta(Offset delta, Size size) {
    return Offset(
      delta.dx / size.width * limits.maxX,
      -delta.dy / size.height * limits.maxY,
    );
  }
}

class _DrawHeightControl extends StatelessWidget {
  const _DrawHeightControl({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.divisions,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;
  final int? divisions;

  @override
  Widget build(BuildContext context) {
    final effectiveMax = math.max(max, min + .1);
    final calculatedDivisions =
        divisions ?? ((effectiveMax - min) * 10).round().clamp(1, 250).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label  ${value.toStringAsFixed(1)} mm',
          style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
        ),
        Slider(
          value: value.clamp(min, effectiveMax),
          min: min,
          max: effectiveMax,
          divisions: calculatedDivisions,
          label: '${value.toStringAsFixed(1)} mm',
          onChanged: max > min ? onChanged : null,
        ),
      ],
    );
  }
}

/// Prévia do percurso: liga o desenho dos deslocamentos, roda a caneta
/// virtual e mostra quanto a máquina anda desenhando, quanto anda à toa e
/// quanto tempo a rota deve levar.
class _RoutePreviewControls extends StatelessWidget {
  const _RoutePreviewControls({
    required this.preview,
    required this.visible,
    required this.playing,
    required this.progress,
    required this.feedrate,
    required this.penLiftMm,
    required this.enabled,
    required this.onVisibleChanged,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onOptimize,
  });

  final RoutePreview preview;
  final bool visible;
  final bool playing;
  final double progress;
  final double feedrate;
  final double penLiftMm;
  final bool enabled;
  final ValueChanged<bool> onVisibleChanged;
  final VoidCallback onTogglePlayback;
  final ValueChanged<double> onSeek;
  final VoidCallback onOptimize;

  String _duration(Duration value) {
    if (value.inMinutes >= 60) {
      final hours = value.inHours;
      final minutes = value.inMinutes.remainder(60);
      return '${hours}h${minutes.toString().padLeft(2, '0')}';
    }
    if (value.inMinutes >= 1) {
      final minutes = value.inMinutes;
      final seconds = value.inSeconds.remainder(60);
      return '${minutes}min${seconds.toString().padLeft(2, '0')}';
    }
    return '${value.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final available = !preview.isEmpty && enabled;
    final estimate = preview.estimate(
      feedrateMmPerSecond: feedrate,
      penLiftMm: penLiftMm,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: available ? () => onVisibleChanged(!visible) : null,
              icon: Icon(
                visible
                    ? Icons.visibility_rounded
                    : Icons.visibility_outlined,
              ),
              label: Text(
                visible ? 'PERCURSO VISÍVEL' : 'VER O PERCURSO',
              ),
            ),
            if (visible && available)
              FilledButton.tonalIcon(
                onPressed: onTogglePlayback,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
                label: Text(playing ? 'PAUSAR' : 'SIMULAR'),
              ),
            OutlinedButton.icon(
              onPressed: available && preview.strokeCount > 1
                  ? onOptimize
                  : null,
              icon: const Icon(Icons.route_rounded),
              label: const Text('OTIMIZAR ORDEM'),
            ),
            if (!preview.isEmpty)
              Text(
                'DESENHO ${preview.drawLength.round()} mm  •  '
                'DESLOCAMENTO ${preview.travelLength.round()} mm  •  '
                '${preview.penLifts} SUBIDA(S)  •  ~${_duration(estimate)}',
                style: const TextStyle(
                  color: NeoCncColors.muted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
        if (visible && available) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: progress.clamp(0.0, 1.0),
                  onChanged: onSeek,
                ),
              ),
              SizedBox(
                width: 96,
                child: Text(
                  '${(progress.clamp(0.0, 1.0) * 100).round()}%  '
                  '${(preview.totalLength * progress.clamp(0.0, 1.0)).round()} mm',
                  style: const TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
          const Text(
            'Linha cheia é caneta baixa; tracejado é deslocamento com a caneta '
            'levantada. Arraste a barra para percorrer a rota.',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}

class _DrawingPainter extends CustomPainter {
  const _DrawingPainter({
    required this.strokes,
    required this.current,
    required this.limits,
    this.preview,
    this.previewProgress = 0,
  });

  final List<List<Offset>> strokes;
  final Offset? current;
  final MachineLimits limits;

  /// Quando presente, desenha o percurso da ferramenta em vez da rota crua:
  /// deslocamentos com a caneta levantada tracejados e o trecho já percorrido
  /// destacado até [previewProgress].
  final RoutePreview? preview;
  final double previewProgress;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final background = Paint()..color = NeoCncColors.canvas;
    final border = Paint()
      ..color = NeoCncColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .55)
      ..strokeWidth = 1;
    canvas.drawRect(area, background);
    for (var mm = 20.0; mm < limits.maxX || mm < limits.maxY; mm += 20) {
      if (mm < limits.maxX) {
        final x = mm / limits.maxX * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      }
      if (mm < limits.maxY) {
        final y = size.height - mm / limits.maxY * size.height;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      }
    }
    canvas.drawRect(area.deflate(.75), border);

    final route = Paint()
      ..color = NeoCncColors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final point = Paint()..color = NeoCncColors.cyan;
    final activePreview = preview;
    if (activePreview != null && !activePreview.isEmpty) {
      _paintPreview(canvas, size, activePreview);
    } else {
      for (final stroke in strokes) {
        if (stroke.isEmpty) {
          continue;
        }
        final path = Path()
          ..moveTo(
            _toCanvas(stroke.first, size).dx,
            _toCanvas(stroke.first, size).dy,
          );
        for (final value in stroke.skip(1)) {
          final canvasPoint = _toCanvas(value, size);
          path.lineTo(canvasPoint.dx, canvasPoint.dy);
        }
        canvas.drawPath(path, route);
        canvas.drawCircle(_toCanvas(stroke.first, size), 3.5, point);
      }
    }
    if (current != null && _isWithin(current!)) {
      final machinePoint = _toCanvas(current!, size);
      final machine = Paint()
        ..color = NeoCncColors.cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(machinePoint, 7, machine);
      canvas.drawLine(
        machinePoint.translate(-11, 0),
        machinePoint.translate(11, 0),
        machine,
      );
      canvas.drawLine(
        machinePoint.translate(0, -11),
        machinePoint.translate(0, 11),
        machine,
      );
    }
  }

  /// Desenha o percurso: o que já foi percorrido em destaque, o que falta
  /// apagado, e os deslocamentos com a caneta levantada tracejados.
  void _paintPreview(Canvas canvas, Size size, RoutePreview preview) {
    final doneDraw = Paint()
      ..color = NeoCncColors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pendingDraw = Paint()
      ..color = NeoCncColors.amber.withValues(alpha: .22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final doneTravel = Paint()
      ..color = NeoCncColors.cyan.withValues(alpha: .75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;
    final pendingTravel = Paint()
      ..color = NeoCncColors.cyan.withValues(alpha: .18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1;

    final target = preview.totalLength * previewProgress.clamp(0.0, 1.0);
    var walked = 0.0;
    for (final move in preview.moves) {
      final from = _toCanvas(move.from, size);
      final to = _toCanvas(move.to, size);
      final end = walked + move.length;
      final done = end <= target;
      final partial = !done && walked < target && move.length > 0;
      if (move.drawing) {
        canvas.drawLine(from, to, done ? doneDraw : pendingDraw);
        if (partial) {
          canvas.drawLine(
            from,
            Offset.lerp(from, to, (target - walked) / move.length)!,
            doneDraw,
          );
        }
      } else {
        _dashedLine(canvas, from, to, done ? doneTravel : pendingTravel);
        if (partial) {
          _dashedLine(
            canvas,
            from,
            Offset.lerp(from, to, (target - walked) / move.length)!,
            doneTravel,
          );
        }
      }
      walked = end;
    }

    // Onde cada traço começa, para dar noção da ordem.
    final startDot = Paint()..color = NeoCncColors.cyan.withValues(alpha: .8);
    for (final stroke in strokes) {
      if (stroke.length >= 2) {
        canvas.drawCircle(_toCanvas(stroke.first, size), 2.4, startDot);
      }
    }

    // A caneta virtual: cheia quando desenhando, vazada quando só se desloca.
    final sample = preview.sampleAt(target);
    final head = _toCanvas(sample.position, size);
    canvas.drawCircle(
      head,
      6,
      Paint()
        ..color = (sample.drawing ? NeoCncColors.amber : NeoCncColors.cyan)
            .withValues(alpha: .25),
    );
    canvas.drawCircle(
      head,
      3.4,
      Paint()
        ..color = sample.drawing ? NeoCncColors.amber : NeoCncColors.cyan
        ..style = sample.drawing ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (to - from).distance;
    if (total <= 0) {
      return;
    }
    final step = (to - from) / total;
    var walked = 0.0;
    while (walked < total) {
      final end = math.min(walked + dash, total);
      canvas.drawLine(from + step * walked, from + step * end, paint);
      walked = end + gap;
    }
  }

  Offset _toCanvas(Offset point, Size size) => Offset(
    point.dx / limits.maxX * size.width,
    size.height - point.dy / limits.maxY * size.height,
  );

  bool _isWithin(Offset point) =>
      point.dx >= 0 &&
      point.dx <= limits.maxX &&
      point.dy >= 0 &&
      point.dy <= limits.maxY;

  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) => true;
}

class _MotionPanel extends StatelessWidget {
  const _MotionPanel({
    required this.enabled,
    required this.step,
    required this.feedrate,
    required this.onStepChanged,
    required this.onJog,
  });

  final bool enabled;
  final double step;
  final double feedrate;
  final ValueChanged<double> onStepChanged;
  final void Function(String axis, double distance) onJog;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'JOG / MOVIMENTO RELATIVO',
      icon: Icons.open_with_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PASSO  ${_formatMeasure(step)} mm',
            style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
          ),
          Slider(
            value: step,
            min: 0.1,
            max: 100,
            divisions: 999,
            label: '${_formatMeasure(step)} mm',
            onChanged: enabled ? onStepChanged : null,
          ),
          const SizedBox(height: 15),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _JogButton(
                      label: 'Y+',
                      icon: Icons.keyboard_arrow_up_rounded,
                      enabled: enabled,
                      onPressed: () => onJog('Y', step),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _JogButton(
                          label: 'X−',
                          icon: Icons.keyboard_arrow_left_rounded,
                          enabled: enabled,
                          onPressed: () => onJog('X', -step),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: NeoCncColors.canvas,
                            border: Border.all(color: NeoCncColors.line),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('XY'),
                        ),
                        const SizedBox(width: 6),
                        _JogButton(
                          label: 'X+',
                          icon: Icons.keyboard_arrow_right_rounded,
                          enabled: enabled,
                          onPressed: () => onJog('X', step),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _JogButton(
                      label: 'Y−',
                      icon: Icons.keyboard_arrow_down_rounded,
                      enabled: enabled,
                      onPressed: () => onJog('Y', -step),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Column(
                children: [
                  const Text(
                    'EIXO Z',
                    style: TextStyle(color: NeoCncColors.muted),
                  ),
                  const SizedBox(height: 8),
                  _JogButton(
                    label: 'Z+',
                    icon: Icons.add_rounded,
                    enabled: enabled,
                    onPressed: () => onJog('Z', step),
                  ),
                  const SizedBox(height: 8),
                  _JogButton(
                    label: 'Z−',
                    icon: Icons.remove_rounded,
                    enabled: enabled,
                    onPressed: () => onJog('Z', -step),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Usando velocidade global: ${feedrate.round()} mm/s',
            style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _formatMeasure(double value) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
  }
}

class _JogButton extends StatelessWidget {
  const _JogButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _SensorsPanel extends StatelessWidget {
  const _SensorsPanel({required this.snapshot});

  final PrinterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final sensors = snapshot.endstops.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return _Panel(
      label: 'SENSORES E MÍDIA',
      icon: Icons.sensors_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FINS DE CURSO',
            style: TextStyle(color: NeoCncColors.muted),
          ),
          const SizedBox(height: 9),
          if (sensors.isEmpty)
            const Text('Conecte para consultar com M119.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: sensors
                  .map(
                    (sensor) =>
                        _SensorChip(name: sensor.key, value: sensor.value),
                  )
                  .toList(),
            ),
          const Divider(height: 28),
          const Text('MICROSD', style: TextStyle(color: NeoCncColors.muted)),
          const SizedBox(height: 6),
          Text(snapshot.sdStatus),
          if (snapshot.lastError != null) ...[
            const Divider(height: 28),
            const Text(
              'ÚLTIMO AVISO',
              style: TextStyle(color: NeoCncColors.danger, fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              snapshot.lastError!,
              style: const TextStyle(color: NeoCncColors.danger, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _SensorChip extends StatelessWidget {
  const _SensorChip({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final triggered = value == 'TRIGGERED';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (triggered ? NeoCncColors.amber : NeoCncColors.cyan).withValues(
          alpha: .10,
        ),
        border: Border.all(
          color: triggered ? NeoCncColors.amber : NeoCncColors.cyan,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$name  $value',
        style: TextStyle(
          color: triggered ? NeoCncColors.amber : NeoCncColors.cyan,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ConsolePanel extends StatelessWidget {
  const _ConsolePanel({required this.log});

  final List<String> log;

  @override
  Widget build(BuildContext context) {
    final visibleLog = log.reversed.take(11).toList().reversed;
    return _Panel(
      label: 'CONSOLE SERIAL',
      icon: Icons.terminal_rounded,
      child: Container(
        constraints: const BoxConstraints(minHeight: 170),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF070A0D),
          border: Border.all(color: NeoCncColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          visibleLog.isEmpty
              ? 'Aguardando tráfego serial…'
              : visibleLog.join('\n'),
          style: const TextStyle(fontSize: 12, height: 1.45),
        ),
      ),
    );
  }
}

class _ManualCommandPanel extends StatelessWidget {
  const _ManualCommandPanel({
    required this.enabled,
    required this.controller,
    required this.onSend,
  });

  final bool enabled;
  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'G-CODE MANUAL',
      icon: Icons.code_rounded,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              enabled: enabled,
              controller: controller,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Ex.: M503  |  G0 X10 F1200',
                prefixText: '> ',
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
            label: const Text('REVISAR E ENVIAR'),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.icon, required this.child});

  final String label;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NeoCncColors.panel,
        border: Border.all(color: NeoCncColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: NeoCncColors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .7,
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          child,
        ],
      ),
    );
  }
}
