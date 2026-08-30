import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/printer/application/printer_controller.dart';
import 'package:neocnc_control/features/printer/data/printer_transport.dart';
import 'package:neocnc_control/features/printer/domain/drawing_point.dart';

void main() {
  test('envia um traço com Z seguro e movimentos G1', () async {
    final transport = _AutoAckTransport();
    final controller = PrinterController(transport: transport);
    addTearDown(controller.dispose);

    await controller.connect('/dev/mock');
    await controller.home();
    await controller.draw(
      strokes: const [
        [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 20, y: 10)],
      ],
      safeZ: 5,
      drawingZ: 0,
      feedrateMmPerSecond: 40,
    );

    expect(
      transport.commands,
      containsAllInOrder([
        'G28',
        'G90',
        'M117 NeoCNC: Desenhando',
        'G0 Z5 F1200',
        'G0 X10 Y10 F2400',
        'G1 Z0 F1200',
        'G1 X20 Y10 F2400',
        'G0 Z5 F1200',
        'M117 NeoCNC: Desenho OK',
      ]),
    );
  });
}

class _AutoAckTransport implements PrinterTransport {
  final StreamController<String> _lines = StreamController<String>.broadcast();
  final List<String> commands = [];
  bool _connected = false;

  @override
  String? get activePort => _connected ? '/dev/mock' : null;

  @override
  bool get isConnected => _connected;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> connect(String portName) async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> dispose() => _lines.close();

  @override
  Future<List<String>> listPorts() async => const ['/dev/mock'];

  @override
  Future<void> writeLine(String command) async {
    commands.add(command);
    scheduleMicrotask(() => _lines.add('ok'));
  }
}
