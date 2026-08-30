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

  @override
  Stream<String> get lines => _lineController.stream;

  @override
  bool get isConnected => _port?.isOpen() ?? false;

  @override
  String? get activePort => _activePort;

  @override
  Future<List<String>> listPorts() async {
    final ports = SerialPort.getAvailablePorts();
    ports.sort();
    return ports;
  }

  @override
  Future<void> connect(String portName) async {
    await disconnect();

    final port = SerialPort(portName);
    try {
      port.open();
      port.setConfig(
        const SerialPortConfig(
          baudRate: 115200,
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

    final payload = Uint8List.fromList(utf8.encode('${command.trim()}\n'));
    final written = port.write(payload, timeout: 1500);
    if (written != payload.length) {
      throw StateError('A porta serial aceitou apenas $written bytes.');
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
