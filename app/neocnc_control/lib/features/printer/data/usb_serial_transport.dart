import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:libserialport_plus/libserialport_plus.dart';

import 'printer_transport.dart';

class UsbSerialTransport implements PrinterTransport {
  final StreamController<String> _lineController =
      StreamController<String>.broadcast();
  final StringBuffer _receivedBuffer = StringBuffer();

  SerialPort? _port;
  SerialPortReader? _reader;
  StreamSubscription<Uint8List>? _readerSubscription;
  String? _activePort;
  int? _activeBaudRate;

  /// A combinação Ender-3 V4.2.2 GD32 + CH340 é estável em 115200 baud.
  /// Taxas maiores continuam disponíveis para equipamentos que as suportem.
  static const int defaultBaudRate = 115200;
  static const List<int> supportedBaudRates = [115200, 250000, 500000];

  @override
  Stream<String> get lines => _lineController.stream;

  @override
  bool get isConnected => _port?.isOpen() ?? false;

  @override
  String? get activePort => _activePort;

  @override
  int? get activeBaudRate => _activeBaudRate;

  @override
  Future<List<String>> listPorts() async {
    final ports = SerialPort.getAvailablePorts();
    ports.sort();
    return ports;
  }

  @override
  Future<void> connect(
    String portName, {
    int baudRate = defaultBaudRate,
  }) async {
    if (!supportedBaudRates.contains(baudRate)) {
      throw ArgumentError.value(
        baudRate,
        'baudRate',
        'Velocidade não suportada.',
      );
    }
    await disconnect();

    final port = SerialPort(portName);
    try {
      port.open();
      port.setConfig(
        SerialPortConfig(
          baudRate: baudRate,
          bits: 8,
          parity: SerialPortParity.none,
          stopBits: 1,
          rts: SerialPortRts.off,
          dtr: SerialPortDtr.off,
          xonXoff: SerialPortXonXoff.disabled,
        ),
      );

      final reader = SerialPortReader(port);
      _readerSubscription = reader.stream.listen(
        _receiveChunk,
        onError: _lineController.addError,
      );
      _port = port;
      _reader = reader;
      _activePort = portName;
      _activeBaudRate = baudRate;
    } catch (_) {
      if (port.isOpen()) {
        port.close();
      }
      port.dispose();
      rethrow;
    }
  }

  void _receiveChunk(Uint8List bytes) {
    _receivedBuffer.write(utf8.decode(bytes, allowMalformed: true));
    final received = _receivedBuffer.toString();
    final lines = received.split(RegExp(r'\r?\n'));
    _receivedBuffer
      ..clear()
      ..write(lines.removeLast());

    for (final line in lines) {
      final normalized = line.trim();
      if (normalized.isNotEmpty && !_lineController.isClosed) {
        _lineController.add(normalized);
      }
    }
  }

  @override
  Future<void> writeLine(String command) async {
    final port = _port;
    if (port == null || !port.isOpen()) {
      throw StateError('Impressora não está conectada.');
    }

    await writeBytes(Uint8List.fromList(utf8.encode('${command.trim()}\n')));
  }

  @override
  Future<void> writeBytes(Uint8List payload) async {
    final port = _port;
    if (port == null || !port.isOpen()) {
      throw StateError('Impressora não está conectada.');
    }

    var offset = 0;
    while (offset < payload.length) {
      final chunk = Uint8List.sublistView(payload, offset);
      final written = port.write(chunk, timeout: 3000);
      if (written <= 0) {
        throw StateError(
          'A porta serial parou de aceitar dados após $offset de '
          '${payload.length} bytes.',
        );
      }
      offset += written;
    }
  }

  @override
  Future<void> disconnect() async {
    final reader = _reader;
    final subscription = _readerSubscription;
    final port = _port;

    _reader = null;
    _readerSubscription = null;
    _port = null;
    _activePort = null;
    _activeBaudRate = null;
    _receivedBuffer.clear();

    if (reader != null) {
      await reader.close();
    }
    await subscription?.cancel();
    if (port != null) {
      if (port.isOpen()) {
        port.close();
      }
      port.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await _lineController.close();
  }
}
