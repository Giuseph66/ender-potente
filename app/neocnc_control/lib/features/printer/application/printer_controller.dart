import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../job/data/marlin_binary_protocol.dart';
import '../../job/data/marlin_file_transfer.dart';
import '../data/printer_transport.dart';
import '../data/usb_serial_transport.dart';
import '../domain/drawing_point.dart';
import '../domain/printer_snapshot.dart';

enum CompletionSound { none, discreet, melody }

class PrinterController extends ChangeNotifier {
  PrinterController({PrinterTransport? transport})
    : _transport = transport ?? UsbSerialTransport() {
    _lineSubscription = _transport.lines.listen(
      _onLine,
      onError: _onTransportError,
    );
  }

  final PrinterTransport _transport;
  final List<String> _log = [];
  late final StreamSubscription<String> _lineSubscription;

  PrinterSnapshot _snapshot = const PrinterSnapshot();
  List<String> _ports = const [];
  Future<void> _commandTail = Future<void>.value();
  _PendingCommand? _pendingCommand;
  Timer? _refreshTimer;
  bool _refreshInFlight = false;
  bool _xyReferenced = false;
  bool _zReferenced = false;
  bool _isDrawing = false;
  int _drawingCompletedSegments = 0;
  int _drawingSegmentCount = 0;
  bool _disposed = false;
  bool _uploading = false;
  double _uploadProgress = 0;
  bool _binaryModeActive = false;
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);
  String? _sdJobName;

  PrinterSnapshot get snapshot => _snapshot;
  List<String> get ports => List.unmodifiable(_ports);
  List<String> get log => List.unmodifiable(_log);
  bool get isConnected => _snapshot.isConnected;
  bool get isXyReferenced => _xyReferenced;
  bool get isZReferenced => _zReferenced;
  bool get isFullyReferenced => _xyReferenced && _zReferenced;
  bool get isDrawing => _isDrawing;
  int get drawingCompletedSegments => _drawingCompletedSegments;
  int get drawingSegmentCount => _drawingSegmentCount;
  bool get isUploading => _uploading;
  double get uploadProgress => _uploadProgress;

  /// Arquivo selecionado por `M23`, ou `null` quando nenhum trabalho roda.
  String? get sdJobName => _sdJobName;
  bool get isRunningSdJob => _sdJobName != null;
  bool get isBusy => _isDrawing || _uploading || isRunningSdJob;

  Future<void> refreshPorts() async {
    try {
      _ports = await _transport.listPorts();
      _notify();
    } catch (error) {
      _recordError('Não foi possível listar portas: $error');
      rethrow;
    }
  }

  Future<void> connect(
    String portName, {
    int baudRate = UsbSerialTransport.defaultBaudRate,
  }) async {
    if (portName.isEmpty) {
      throw ArgumentError.value(portName, 'portName', 'Selecione uma porta.');
    }
    await disconnect();

    try {
      await _transport.connect(portName, baudRate: baudRate);
      _snapshot = _snapshot.copyWith(
        isConnected: true,
        portName: portName,
        machineName: 'IDENTIFICANDO MÁQUINA',
        firmware: 'Consultando Marlin…',
        clearLastError: true,
      );
      _addLog('SYS > conectado em $portName');
      _notify();

      await _waitForFirmware();
      await refreshStatus(includeFirmwareInfo: false);
      _startStatusTimer();
      await _enqueue(() => _setLcdMessage('NeoCNC conectado'));
    } catch (error) {
      await disconnect();
      _recordError('Falha ao conectar: $error');
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _pendingCommand?.fail(StateError('Conexão encerrada.'));
    _pendingCommand = null;
    _xyReferenced = false;
    _zReferenced = false;
    _isDrawing = false;
    _drawingCompletedSegments = 0;
    _drawingSegmentCount = 0;
    _uploading = false;
    _uploadProgress = 0;
    _binaryModeActive = false;
    _sdJobName = null;

    await _transport.disconnect();
    _snapshot = _snapshot.copyWith(
      isConnected: false,
      clearPortName: true,
      machineName: 'AGUARDANDO CONEXÃO',
      firmware: '—',
    );
    _addLog('SYS > conexão encerrada');
    _notify();
  }

  Future<void> refreshStatus({bool includeFirmwareInfo = true}) async {
    if (!isConnected || _refreshInFlight) {
      return;
    }
    _refreshInFlight = true;
    try {
      await _enqueue(() async {
        if (includeFirmwareInfo) {
          await _sendAndAwait('M115', timeout: const Duration(seconds: 4));
        }
        await _sendAndAwait('M105');
        await _sendAndAwait('M114');
        await _sendAndAwait('M119');
        await _sendAndAwait('M27');
      });
    } finally {
      _refreshInFlight = false;
    }
  }

  Future<void> jog({
    required String axis,
    required double millimeters,
    required double feedrateMmPerSecond,
  }) async {
    final normalizedAxis = axis.toUpperCase();
    if (!const {'X', 'Y', 'Z'}.contains(normalizedAxis)) {
      throw ArgumentError.value(axis, 'axis', 'Eixo não suportado.');
    }
    if (millimeters == 0 || millimeters.abs() > 100) {
      throw ArgumentError.value(
        millimeters,
        'millimeters',
        'Movimento inválido.',
      );
    }
    if (feedrateMmPerSecond <= 0 || feedrateMmPerSecond > 300) {
      throw ArgumentError.value(
        feedrateMmPerSecond,
        'feedrate',
        'Velocidade inválida.',
      );
    }

    await _enqueue(() async {
      final direction = millimeters > 0 ? '+' : '-';
      final distance = _formatNumber(millimeters.abs());
      await _setLcdMessage('NeoCNC: Jog $normalizedAxis$direction$distance mm');
      await _sendAndAwait('G91');
      try {
        final value = _formatNumber(millimeters);
        final feedrate = (feedrateMmPerSecond * 60).round();
        await _sendAndAwait(
          'G1 $normalizedAxis$value F$feedrate',
          timeout: const Duration(seconds: 15),
        );
      } finally {
        await _sendAndAwait('G90');
      }
      await _sendAndAwait('M114');
      await _setLcdMessage('NeoCNC: $normalizedAxis pronto');
    });
  }

  Future<void> home([String? axis]) async {
    final suffix = axis == null ? '' : ' ${axis.toUpperCase()}';
    await _enqueue(() async {
      final label = _homeLabel(axis);
      await _setLcdMessage('NeoCNC: Home $label...');
      try {
        await _sendAndAwait('G28$suffix', timeout: const Duration(minutes: 3));
        await _sendAndAwait('M114');
        await _setLcdMessage('NeoCNC: Home $label OK');
      } catch (_) {
        await _setLcdMessage('NeoCNC: Home $label ERRO');
        rethrow;
      }
    });
    if (axis == null || _homesXy(axis)) {
      _xyReferenced = true;
    }
    if (axis == null || _homesZ(axis)) {
      _zReferenced = true;
    }
    if (axis == null || _homesXy(axis) || _homesZ(axis)) {
      _notify();
    }
  }

  Future<void> moveTo({
    required double x,
    required double y,
    required double feedrateMmPerSecond,
  }) async {
    if (!_xyReferenced) {
      throw StateError('Faça HOME XY antes de usar o mapa.');
    }
    if (x < 0 || x > 220 || y < 0 || y > 220) {
      throw ArgumentError('O destino precisa estar dentro de X0–220 e Y0–220.');
    }
    if (feedrateMmPerSecond <= 0 || feedrateMmPerSecond > 300) {
      throw ArgumentError.value(
        feedrateMmPerSecond,
        'feedrate',
        'Velocidade inválida.',
      );
    }

    await _enqueue(() async {
      final feedrate = (feedrateMmPerSecond * 60).round();
      final destination = 'X${_formatNumber(x)} Y${_formatNumber(y)}';
      await _setLcdMessage('NeoCNC: Indo $destination');
      try {
        await _sendAndAwait('G90');
        await _sendAndAwait(
          'G0 $destination F$feedrate',
          timeout: const Duration(seconds: 45),
        );
        await _sendAndAwait('M114');
        await _setLcdMessage('NeoCNC: $destination OK');
      } catch (_) {
        await _setLcdMessage('NeoCNC: Movimento ERRO');
        rethrow;
      }
    });
  }

  Future<void> draw({
    required List<List<DrawingPoint>> strokes,
    required double penLiftMm,
    required double drawingZ,
    required double feedrateMmPerSecond,
    required CompletionSound completionSound,
  }) async {
    if (!isFullyReferenced) {
      throw StateError('Faça HOME XY e HOME Z antes de desenhar.');
    }
    if (penLiftMm <= 0 || penLiftMm > 250 || drawingZ < 0 || drawingZ > 250) {
      throw ArgumentError(
        'Configure a elevação e o Z de traço dentro do curso.',
      );
    }
    final travelZ = drawingZ + penLiftMm;
    if (travelZ > 250) {
      throw ArgumentError('Z de traço + elevação não pode ultrapassar 250 mm.');
    }
    if (feedrateMmPerSecond <= 0 || feedrateMmPerSecond > 300) {
      throw ArgumentError.value(
        feedrateMmPerSecond,
        'feedrate',
        'Velocidade inválida.',
      );
    }

    final validStrokes = strokes
        .where((stroke) => stroke.length >= 2)
        .map(List<DrawingPoint>.unmodifiable)
        .toList(growable: false);
    if (validStrokes.isEmpty) {
      throw ArgumentError('Desenhe ao menos um traço com dois pontos.');
    }
    for (final stroke in validStrokes) {
      for (final point in stroke) {
        if (point.x < 0 || point.x > 220 || point.y < 0 || point.y > 220) {
          throw ArgumentError(
            'O desenho precisa ficar dentro de X0–220 e Y0–220.',
          );
        }
      }
    }

    _isDrawing = true;
    _drawingCompletedSegments = 0;
    _drawingSegmentCount = validStrokes.fold(
      0,
      (total, stroke) => total + stroke.length - 1,
    );
    _notify();

    try {
      await _enqueue(() async {
        final xyFeedrate = (feedrateMmPerSecond * 60).round();
        final zFeedrate = (feedrateMmPerSecond.clamp(5, 20) * 60).round();
        await _sendAndAwait('G90');
        await _setLcdMessage('NeoCNC: Desenhando');
        await _sendAndAwait(
          'G0 Z${_formatNumber(travelZ)} F$zFeedrate',
          timeout: const Duration(seconds: 30),
        );
        try {
          for (final stroke in validStrokes) {
            final start = stroke.first;
            await _sendAndAwait(
              'G0 X${_formatNumber(start.x)} Y${_formatNumber(start.y)} F$xyFeedrate',
              timeout: const Duration(seconds: 45),
            );
            await _sendAndAwait(
              'G1 Z${_formatNumber(drawingZ)} F$zFeedrate',
              timeout: const Duration(seconds: 30),
            );
            for (final point in stroke.skip(1)) {
              await _sendAndAwait(
                'G1 X${_formatNumber(point.x)} Y${_formatNumber(point.y)} F$xyFeedrate',
                timeout: const Duration(seconds: 45),
              );
              _drawingCompletedSegments += 1;
              _notify();
            }
            await _sendAndAwait(
              'G0 Z${_formatNumber(travelZ)} F$zFeedrate',
              timeout: const Duration(seconds: 30),
            );
          }
          await _sendAndAwait('M400', timeout: const Duration(minutes: 10));
          await _sendAndAwait('M114');
          await _setLcdMessage('NeoCNC: Desenho OK');
          await _playCompletionSound(completionSound);
        } catch (_) {
          await _setLcdMessage('NeoCNC: Desenho ERRO');
          rethrow;
        }
      });
    } finally {
      _isDrawing = false;
      _notify();
    }
  }

  /// Grava o trabalho no cartão da máquina pelo protocolo binário do Marlin
  /// (`M28 B1` + BFT) em vez de transmitir G-code linha a linha.
  ///
  /// Streaming linha a linha custa um round-trip serial por segmento: numa
  /// isolação de PCB com milhares de segmentos curtos o planner esvazia entre
  /// os movimentos e a fresa marca o cobre a cada parada. Rodando do cartão a
  /// máquina lê no próprio ritmo e o trabalho sobrevive a uma desconexão USB.
  Future<void> uploadJob({
    required String gcode,
    required String remoteName,
    void Function(double progress)? onProgress,
  }) async {
    if (!isConnected) {
      throw StateError('Impressora não está conectada.');
    }
    if (isBusy) {
      throw StateError('Já existe uma operação em andamento.');
    }
    final name = _normalizeSdName(remoteName);
    final bytes = Uint8List.fromList(utf8.encode(gcode));
    if (bytes.isEmpty) {
      throw ArgumentError('O trabalho está vazio.');
    }

    await _enqueue(() async {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      _uploading = true;
      _uploadProgress = 0;
      _notify();

      final protocol = MarlinBinaryProtocol(_transport);
      final transfer = MarlinFileTransfer(protocol);
      try {
        await _setLcdMessage('NeoCNC: Enviando');
        await _sendAndAwait('M21', timeout: const Duration(seconds: 15));
        try {
          await _sendAndAwait(
            'M30 /$name',
            timeout: const Duration(seconds: 15),
          );
        } catch (error) {
          _addLog('WARN > $name não existia no cartão: $error');
        }

        _binaryModeActive = true;
        var binarySessionMayBeOpen = false;
        try {
          binarySessionMayBeOpen = true;
          await protocol.connect();
          await transfer.copy(
            bytes,
            name,
            onProgress: (progress) {
              _uploadProgress = progress;
              onProgress?.call(progress);
              _notifyProgress();
            },
          );
        } finally {
          if (binarySessionMayBeOpen) {
            try {
              // Mesmo se o envio falhar, feche M28 B1 antes de voltar ao
              // ASCII. Sem isso a máquina fica presa em binário até reiniciar.
              await protocol.disconnect();
            } catch (error) {
              _addLog('WARN > não foi possível fechar BFT: $error');
            }
          }
          await protocol.shutdown();
          _binaryModeActive = false;
        }

        await _sendAndAwait('M21', timeout: const Duration(seconds: 15));
        _addLog('SYS > $name gravado no cartão (${bytes.length} bytes)');
        await _setLcdMessage('NeoCNC: Arquivo OK');
      } catch (error) {
        _binaryModeActive = false;
        await _setLcdMessage('NeoCNC: Envio ERRO');
        _recordError('Falha ao enviar $name: $error');
        rethrow;
      } finally {
        _uploading = false;
        _uploadProgress = 0;
        if (isConnected) {
          _startStatusTimer();
        }
        _notify();
      }
    });
  }

  /// Seleciona e inicia um arquivo já gravado no cartão.
  Future<void> startSdJob(String remoteName) async {
    if (!isFullyReferenced) {
      throw StateError('Faça HOME XY e HOME Z antes de iniciar um trabalho.');
    }
    if (isBusy) {
      throw StateError('Já existe uma operação em andamento.');
    }
    final name = _normalizeSdName(remoteName);
    await _enqueue(() async {
      await _sendAndAwait('M21', timeout: const Duration(seconds: 15));
      await _sendAndAwait('M23 $name', timeout: const Duration(seconds: 15));
      await _sendAndAwait('M24', timeout: const Duration(seconds: 15));
      await _setLcdMessage('NeoCNC: $name');
    });
    _sdJobName = name;
    _notify();
  }

  Future<void> pauseSdJob() => _enqueue(() async {
    await _sendAndAwait('M25', timeout: const Duration(seconds: 15));
    await _setLcdMessage('NeoCNC: Pausado');
  });

  Future<void> resumeSdJob() => _enqueue(() async {
    await _sendAndAwait('M24', timeout: const Duration(seconds: 15));
    await _setLcdMessage('NeoCNC: Retomado');
  });

  /// Aborta o trabalho e desliga a ferramenta.
  Future<void> abortSdJob() async {
    await _enqueue(() async {
      await _sendAndAwait('M524', timeout: const Duration(seconds: 15));
      await _sendAndAwait('M5', timeout: const Duration(seconds: 20));
      await _setLcdMessage('NeoCNC: Abortado');
    });
    _sdJobName = null;
    _notify();
  }

  /// Liga a microrretífica. `M3` espera `SPINDLE_LASER_POWERUP_DELAY` antes de
  /// devolver o `ok`, por isso o timeout é folgado.
  Future<void> spindleOn({int power = 255}) {
    if (power < 0 || power > 255) {
      throw ArgumentError.value(power, 'power', 'Use um valor entre 0 e 255.');
    }
    return _enqueue(
      () => _sendAndAwait('M3 S$power', timeout: const Duration(seconds: 30)),
    );
  }

  Future<void> spindleOff() =>
      _enqueue(() => _sendAndAwait('M5', timeout: const Duration(seconds: 30)));

  static final RegExp _sdNamePattern = RegExp(
    r'^[A-Z0-9_~-]{1,8}\.[A-Z0-9]{1,3}$',
  );

  static String _normalizeSdName(String name) {
    final normalized = name.trim().toUpperCase();
    if (!_sdNamePattern.hasMatch(normalized)) {
      throw ArgumentError.value(
        name,
        'remoteName',
        'O cartão só aceita nomes 8.3 (ex.: ISOLA01.GCO).',
      );
    }
    return normalized;
  }

  void _notifyProgress() {
    final now = DateTime.now();
    if (now.difference(_lastProgressNotify) <
        const Duration(milliseconds: 150)) {
      return;
    }
    _lastProgressNotify = now;
    _notify();
  }

  Future<void> enableSteppers() => _enqueue(() => _sendAndAwait('M17'));

  Future<void> disableSteppers() => _enqueue(() => _sendAndAwait('M18'));

  Future<void> emergencyStop() async {
    if (!isConnected) {
      throw StateError('Impressora não está conectada.');
    }
    _addLog('TX  > M112  [PARADA DE EMERGÊNCIA]');
    await _transport.writeLine('M112');
    _recordError(
      'PARADA DE EMERGÊNCIA enviada. Reinicie a impressora para liberar.',
    );
  }

  Future<void> sendManualCommand(String command) async {
    final normalized = command.trim();
    if (normalized.isEmpty || normalized.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError('Informe um único comando G-code.');
    }
    await _enqueue(() => _sendAndAwait(normalized));
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _commandTail.then((_) => action());
    _commandTail = next.then<void>((_) {}, onError: (error, stackTrace) {});
    return next;
  }

  Future<void> _waitForFirmware() async {
    Object? lastError;

    // Abrir a CH340 pode reiniciar a placa. Aguarde e repita a identificação
    // em vez de tratar o primeiro M115 perdido durante o boot como desconexão.
    for (var attempt = 1; attempt <= 6; attempt++) {
      try {
        await _sendAndAwait('M115', timeout: const Duration(seconds: 3));
        return;
      } catch (error) {
        lastError = error;
        if (attempt == 6) {
          break;
        }
        _addLog('SYS > aguardando Marlin iniciar ($attempt/6)');
        _notify();
        await Future<void>.delayed(const Duration(milliseconds: 750));
      }
    }

    throw StateError('Marlin não respondeu ao M115: $lastError');
  }

  Future<void> _sendAndAwait(
    String command, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!isConnected) {
      throw StateError('Impressora não está conectada.');
    }
    final pending = _PendingCommand(command);
    _pendingCommand = pending;
    _addLog('TX  > $command');
    try {
      await _transport.writeLine(command);
      await pending.completer.future.timeout(timeout);
    } on TimeoutException {
      throw TimeoutException('Sem resposta para $command.', timeout);
    } finally {
      if (identical(_pendingCommand, pending)) {
        _pendingCommand = null;
      }
    }
  }

  Future<void> _setLcdMessage(String message) async {
    try {
      await _sendAndAwait('M117 $message', timeout: const Duration(seconds: 3));
    } catch (error) {
      _addLog('WARN > LCD sem M117: $error');
      _notify();
    }
  }

  Future<void> _playCompletionSound(CompletionSound sound) async {
    final tune = switch (sound) {
      CompletionSound.none => const <({int frequency, int duration})>[],
      CompletionSound.discreet => const <({int frequency, int duration})>[
        (frequency: 880, duration: 100),
      ],
      CompletionSound.melody => const <({int frequency, int duration})>[
        (frequency: 523, duration: 300),
        (frequency: 659, duration: 300),
        (frequency: 784, duration: 300),
        (frequency: 1047, duration: 900),
      ],
    };
    if (tune.isEmpty) {
      return;
    }
    try {
      for (final tone in tune) {
        await _sendAndAwait(
          'M300 S${tone.frequency} P${tone.duration}',
          timeout: const Duration(seconds: 5),
        );
      }
    } catch (error) {
      _addLog('WARN > Não foi possível tocar a melodia: $error');
      _notify();
    }
  }

  void _onLine(String line) {
    if (_binaryModeActive) {
      return;
    }
    _addLog('RX  < $line');
    _parseLine(line);
    _pendingCommand?.consume(line);
    _notify();
  }

  void _onTransportError(Object error, StackTrace stackTrace) {
    _recordError('Erro na porta serial: $error');
  }

  void _parseLine(String line) {
    final temperature = RegExp(
      r'T:\s*([+-]?\d+(?:\.\d+)?)\s*/\s*([+-]?\d+(?:\.\d+)?).*?B:\s*([+-]?\d+(?:\.\d+)?)\s*/\s*([+-]?\d+(?:\.\d+)?)',
    ).firstMatch(line);
    if (temperature != null) {
      _snapshot = _snapshot.copyWith(
        hotendActual: double.parse(temperature.group(1)!),
        hotendTarget: double.parse(temperature.group(2)!),
        bedActual: double.parse(temperature.group(3)!),
        bedTarget: double.parse(temperature.group(4)!),
      );
    }

    if (line.contains('X:') && line.contains('Y:') && line.contains('Z:')) {
      final coordinates = <String, double>{};
      final reportedPosition = line.split('Count').first;
      for (final match in RegExp(
        r'([XYZE]):\s*([+-]?\d+(?:\.\d+)?)',
      ).allMatches(reportedPosition)) {
        coordinates[match.group(1)!] = double.parse(match.group(2)!);
      }
      if (coordinates.containsKey('X') &&
          coordinates.containsKey('Y') &&
          coordinates.containsKey('Z')) {
        _snapshot = _snapshot.copyWith(
          x: coordinates['X'],
          y: coordinates['Y'],
          z: coordinates['Z'],
        );
      }
    }

    final endstop = RegExp(
      r'^\s*([a-z0-9_]+):\s*(open|triggered)',
      caseSensitive: false,
    ).firstMatch(line);
    if (endstop != null) {
      final values = Map<String, String>.from(_snapshot.endstops);
      values[endstop.group(1)!.toUpperCase()] = endstop.group(2)!.toUpperCase();
      _snapshot = _snapshot.copyWith(endstops: values);
    }

    if (line.startsWith('SD printing')) {
      final progress = RegExp(r'(\d+)\s*/\s*(\d+)').firstMatch(line);
      _snapshot = _snapshot.copyWith(
        sdStatus: line,
        sdBytesDone: progress == null ? null : int.parse(progress.group(1)!),
        sdBytesTotal: progress == null ? null : int.parse(progress.group(2)!),
      );
    } else if (line.startsWith('Not SD printing')) {
      _snapshot = _snapshot.copyWith(
        sdStatus: line,
        sdBytesDone: 0,
        sdBytesTotal: 0,
      );
    }

    if (line.startsWith('Done printing file')) {
      _sdJobName = null;
      _snapshot = _snapshot.copyWith(sdBytesDone: 0, sdBytesTotal: 0);
      _addLog('SYS > trabalho concluído');
    }

    if (line.contains('FIRMWARE_NAME:')) {
      final firmware = RegExp(r'FIRMWARE_NAME:([^\s]+)').firstMatch(line);
      final machine = RegExp(r'MACHINE_TYPE:([^\s]+)').firstMatch(line);
      _snapshot = _snapshot.copyWith(
        firmware: firmware?.group(1) ?? _snapshot.firmware,
        machineName: machine?.group(1) ?? 'MARLIN / NEOCNC',
      );
    }
  }

  void _startStatusTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshFromTimer());
    });
  }

  Future<void> _refreshFromTimer() async {
    try {
      await refreshStatus(includeFirmwareInfo: false);
    } catch (error) {
      _addLog('WARN > telemetria indisponível: $error');
      _notify();
    }
  }

  void _recordError(String message) {
    _snapshot = _snapshot.copyWith(lastError: message);
    _addLog('ERR > $message');
    _notify();
  }

  void _addLog(String entry) {
    _log.add(entry);
    if (_log.length > 80) {
      _log.removeRange(0, _log.length - 80);
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  String _formatNumber(double value) {
    return value
        .toStringAsFixed(3)
        .replaceFirst(RegExp(r'\.0+$'), '')
        .replaceFirst(RegExp(r'(\.\d*?)0+$'), r'$1');
  }

  bool _homesXy(String axis) {
    final axes = axis.toUpperCase();
    return axes.contains('X') && axes.contains('Y');
  }

  bool _homesZ(String axis) => axis.toUpperCase().contains('Z');

  String _homeLabel(String? axis) {
    if (axis == null) {
      return 'Todos';
    }
    return axis.toUpperCase().replaceAll(' ', '');
  }

  @override
  void dispose() {
    _disposed = true;
    _refreshTimer?.cancel();
    unawaited(_lineSubscription.cancel());
    unawaited(_transport.dispose());
    super.dispose();
  }
}

class _PendingCommand {
  _PendingCommand(this.command);

  final String command;
  final Completer<void> completer = Completer<void>();

  void consume(String line) {
    final lower = line.toLowerCase();
    if (lower == 'ok' || lower.startsWith('ok ')) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      return;
    }
    if (lower.startsWith('error:') ||
        lower.startsWith('echo:unknown command')) {
      fail(StateError('$command: $line'));
    }
  }

  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
  }
}
