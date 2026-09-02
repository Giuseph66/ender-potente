import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/printer/application/printer_controller.dart';
import 'package:neocnc_control/features/printer/data/printer_transport.dart';
import 'package:neocnc_control/features/printer/domain/drawing_point.dart';

void main() {
  test('repete o M115 enquanto o Marlin inicia', () async {
    final transport = _AutoAckTransport(m115Failures: 1);
    final controller = PrinterController(transport: transport);
    addTearDown(controller.dispose);

    await controller.connect('/dev/mock');

    expect(
      transport.commands.where((command) => command == 'M115'),
      hasLength(2),
    );
    expect(controller.isConnected, isTrue);
  });

  test('eleva a caneta entre traços e toca a melodia ao concluir', () async {
    final transport = _AutoAckTransport();
    final controller = PrinterController(transport: transport);
    addTearDown(controller.dispose);

    await controller.connect('/dev/mock');
    await controller.home();
    await controller.draw(
      strokes: const [
        [DrawingPoint(x: 10, y: 10), DrawingPoint(x: 20, y: 10)],
      ],
      penLiftMm: 3,
      drawingZ: 2,
      feedrateMmPerSecond: 40,
      completionSound: CompletionSound.melody,
    );

    expect(
      transport.commands,
      containsAllInOrder([
        'G28',
        'G90',
        'M117 NeoCNC: Desenhando',
        'G0 Z5 F1200',
        'G0 X10 Y10 F2400',
        'G1 Z2 F1200',
        'G1 X20 Y10 F2400',
        'G0 Z5 F1200',
        'M400',
        'M117 NeoCNC: Desenho OK',
        'M300 S523 P300',
        'M300 S659 P300',
        'M300 S784 P300',
        'M300 S1047 P900',
      ]),
    );
  });
}

class _AutoAckTransport implements PrinterTransport {
  _AutoAckTransport({this.m115Failures = 0});

  final StreamController<String> _lines = StreamController<String>.broadcast();
  final List<String> commands = [];
  final BytesBuilder rawWrites = BytesBuilder();
  int m115Failures;
  bool _connected = false;
  int? _baudRate;

  @override
  String? get activePort => _connected ? '/dev/mock' : null;

  @override
  int? get activeBaudRate => _baudRate;

  @override
  bool get isConnected => _connected;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> connect(String portName, {int baudRate = 250000}) async {
    _connected = true;
    _baudRate = baudRate;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _baudRate = null;
  }

  @override
  Future<void> dispose() => _lines.close();

  @override
  Future<List<String>> listPorts() async => const ['/dev/mock'];

  @override
  Future<void> writeLine(String command) async {
    commands.add(command);
    if (command == 'M115' && m115Failures > 0) {
      m115Failures -= 1;
      scheduleMicrotask(() => _lines.add('Error: initializing'));
      return;
    }
    scheduleMicrotask(() => _lines.add('ok'));
  }

  @override
  Future<void> writeBytes(Uint8List payload) async {
    rawWrites.add(payload);
  }
}
