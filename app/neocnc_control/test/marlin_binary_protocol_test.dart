import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/job/data/marlin_binary_protocol.dart';
import 'package:neocnc_control/features/job/data/marlin_file_transfer.dart';
import 'package:neocnc_control/features/printer/data/printer_transport.dart';

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('quadro binário', () {
    // Vetores gerados com a implementação de referência do próprio Marlin,
    // firmware/marlin/buildroot/share/scripts/MarlinBinaryProtocol.py.
    test('reproduz os pacotes da implementação de referência', () {
      expect(
        _hex(
          MarlinBinaryProtocol.buildPacket(0, 1, 0, Uint8List(0)),
        ),
        'adb5000100000103',
      );
      expect(
        _hex(
          MarlinBinaryProtocol.buildPacket(
            1,
            1,
            1,
            Uint8List.fromList([0, 0, ...utf8.encode('TEST.GCO'), 0]),
          ),
        ),
        'adb501110b001d4d0000544553542e47434f00d0b0',
      );
      expect(
        _hex(
          MarlinBinaryProtocol.buildPacket(
            1,
            3,
            7,
            Uint8List.fromList(utf8.encode('G1 X10 Y10 F600\n')),
          ),
        ),
        'adb5071310002a754731205831302059313020463630300afd59',
      );
      expect(
        _hex(MarlinBinaryProtocol.buildPacket(1, 2, 255, Uint8List(0))),
        'adb5ff1200001236',
      );
    });

    test('usa o Fletcher-16 módulo 255 do Marlin', () {
      expect(
        MarlinBinaryProtocol.buildChecksum(utf8.encode('NeoCNC')),
        14583,
      );
    });
  });

  test('transfere um arquivo inteiro para a máquina', () async {
    final machine = _FakeMarlin();
    addTearDown(machine.dispose);

    await machine.connect('/dev/mock');
    final protocol = MarlinBinaryProtocol(machine);
    final transfer = MarlinFileTransfer(protocol);

    // Bloco pequeno para forçar várias escritas sem gerar um teste lento.
    machine.maxBlockSize = 64;

    final payload = Uint8List.fromList(
      utf8.encode(
        List<String>.generate(40, (i) => 'G1 X$i Y${i * 2} F600').join('\n'),
      ),
    );

    final progress = <double>[];
    await protocol.connect();
    await transfer.copy(payload, 'ISOLA01.GCO', onProgress: progress.add);
    await protocol.disconnect();
    await protocol.shutdown();

    expect(machine.enteredBinaryMode, isTrue);
    expect(machine.openedFile, 'ISOLA01.GCO');
    expect(machine.closed, isTrue);
    expect(machine.written, payload);
    expect(progress.last, 1.0);
    expect(progress.length, greaterThan(1));
    expect(protocol.errors, 0);
  });
}

/// Marlin de mentira: decodifica os pacotes de verdade (token, checksums,
/// numeração de sync) e responde como o firmware responderia.
class _FakeMarlin implements PrinterTransport {
  final StreamController<String> _lines = StreamController<String>.broadcast();
  final BytesBuilder _incoming = BytesBuilder();
  final BytesBuilder _file = BytesBuilder();

  bool _connected = false;
  int _sync = 0;
  int maxBlockSize = 512;
  bool enteredBinaryMode = false;
  bool binaryMode = false;
  String? openedFile;
  bool closed = false;

  Uint8List get written => _file.toBytes();

  @override
  String? get activePort => _connected ? '/dev/mock' : null;

  @override
  int? get activeBaudRate => _connected ? 250000 : null;

  @override
  bool get isConnected => _connected;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<List<String>> listPorts() async => const ['/dev/mock'];

  @override
  Future<void> connect(String portName, {int baudRate = 250000}) async {
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<void> dispose() => _lines.close();

  void _reply(String line) => scheduleMicrotask(() {
    if (!_lines.isClosed) {
      _lines.add(line);
    }
  });

  @override
  Future<void> writeLine(String command) async {
    if (command.replaceAll(' ', '').toUpperCase() == 'M28B1') {
      enteredBinaryMode = true;
      binaryMode = true;
    }
    _reply('ok');
  }

  @override
  Future<void> writeBytes(Uint8List payload) async {
    _incoming.add(payload);
    _drain();
  }

  void _drain() {
    var bytes = _incoming.toBytes();
    var offset = 0;

    while (bytes.length - offset >= 8) {
      if (bytes[offset] != 0xAD || bytes[offset + 1] != 0xB5) {
        offset += 1;
        continue;
      }
      final header = bytes.sublist(offset + 2, offset + 6);
      final headerChecksum = bytes[offset + 6] | (bytes[offset + 7] << 8);
      if (MarlinBinaryProtocol.buildChecksum(header) != headerChecksum) {
        _reply('rs $_sync');
        offset += 2;
        continue;
      }

      final sync = header[0];
      final protocolId = (header[1] >> 4) & 0xF;
      final packetType = header[1] & 0xF;
      final length = header[2] | (header[3] << 8);

      final total = 8 + (length > 0 ? length + 2 : 0);
      if (bytes.length - offset < total) {
        break; // pacote incompleto, espera mais bytes
      }

      Uint8List data = Uint8List(0);
      if (length > 0) {
        data = bytes.sublist(offset + 8, offset + 8 + length);
        final payloadChecksum =
            bytes[offset + 8 + length] | (bytes[offset + 9 + length] << 8);
        final expected = MarlinBinaryProtocol.buildChecksum(
          bytes.sublist(offset + 2, offset + 8 + length),
        );
        if (expected != payloadChecksum) {
          _reply('rs $sync');
          offset += total;
          continue;
        }
      }

      offset += total;
      _handlePacket(protocolId, packetType, sync, data);
    }

    final remainder = bytes.sublist(offset);
    _incoming
      ..clear()
      ..add(remainder);
    bytes = remainder;
  }

  void _handlePacket(
    int protocolId,
    int packetType,
    int sync,
    Uint8List data,
  ) {
    if (protocolId == MarlinBinaryProtocol.connectionProtocolId) {
      switch (packetType) {
        case MarlinBinaryProtocol.connectionSync:
          _sync = 0;
          _reply('ss $_sync,$maxBlockSize,0.1.0');
          return;
        case MarlinBinaryProtocol.connectionClose:
          binaryMode = false;
          _reply('ok $sync');
          _sync = (sync + 1) & 0xFF;
          return;
      }
      return;
    }

    _reply('ok $sync');
    _sync = (sync + 1) & 0xFF;

    switch (packetType) {
      case MarlinFileTransfer.packetQuery:
        _reply('PFT:version:0.1.0:compression:none');
      case MarlinFileTransfer.packetOpen:
        final terminator = data.indexOf(0, 2);
        openedFile = utf8.decode(data.sublist(2, terminator));
        _file.clear();
        closed = false;
        _reply('PFT:success');
      case MarlinFileTransfer.packetWrite:
        _file.add(data);
      case MarlinFileTransfer.packetClose:
        closed = true;
        _reply('PFT:success');
      case MarlinFileTransfer.packetAbort:
        _reply('PFT:success');
    }
  }
}
