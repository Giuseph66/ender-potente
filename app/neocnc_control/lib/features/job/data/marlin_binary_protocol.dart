import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../../printer/data/printer_transport.dart';

/// Porta Dart do `buildroot/share/scripts/MarlinBinaryProtocol.py`, usada para
/// gravar arquivos no cartão da máquina pelo mesmo link serial de G-code.
///
/// O firmware entra em modo binário com `M28 B1` e a partir daí só entende
/// pacotes com o token `0xB5AD`. As respostas continuam sendo linhas ASCII
/// (`ok <n>`, `rs <n>`, `ss <sync>,<bloco>,<versão>`, `fe`, `PFT:*`).
class MarlinProtocolException implements Exception {
  const MarlinProtocolException(this.message);

  final String message;

  @override
  String toString() => 'MarlinProtocolException: $message';
}

class MarlinSyncException extends MarlinProtocolException {
  const MarlinSyncException(super.message);
}

class MarlinFatalException extends MarlinProtocolException {
  const MarlinFatalException(super.message);
}

class ProtocolResponse {
  const ProtocolResponse(this.token, this.payload);

  final String token;
  final String payload;

  @override
  String toString() => '$token$payload';
}

class _ResponseChannel {
  final Queue<ProtocolResponse> _queue = Queue<ProtocolResponse>();
  Completer<void>? _waiter;

  bool get isEmpty => _queue.isEmpty;

  void add(ProtocolResponse response) {
    _queue.add(response);
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  ProtocolResponse removeFirst() => _queue.removeFirst();

  void clear() {
    _queue.clear();
    _waiter = null;
  }

  Future<ProtocolResponse> next(Duration timeout) async {
    if (_queue.isNotEmpty) {
      return _queue.removeFirst();
    }
    final waiter = Completer<void>();
    _waiter = waiter;
    try {
      await waiter.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_waiter, waiter)) {
        _waiter = null;
      }
      rethrow;
    }
    return _queue.removeFirst();
  }
}

class MarlinBinaryProtocol {
  MarlinBinaryProtocol(
    this._transport, {
    this.responseTimeout = const Duration(seconds: 1),
    int blockSize = 512,
  }) {
    _blockSize = blockSize;
  }

  static const int startToken = 0xB5AD;
  static const int connectionProtocolId = 0;
  static const int fileTransferProtocolId = 1;

  static const int connectionSync = 1;
  static const int connectionClose = 2;

  static const List<String> _connectionTokens = ['ok', 'rs', 'ss', 'fe'];
  static const List<String> _transferTokens = [
    'PFT:success',
    'PFT:version:',
    'PFT:fail',
    'PFT:busy',
    'PFT:ioerror',
    'PFT:invalid',
    // O firmware responde com esta grafia trocada no caso `default`.
    'PTF:invalid',
  ];

  final PrinterTransport _transport;
  final Duration responseTimeout;

  final _ResponseChannel _connection = _ResponseChannel();
  final _ResponseChannel _transfer = _ResponseChannel();

  StreamSubscription<String>? _subscription;
  int _blockSize = 512;
  int _maxBlockSize = 0;
  int _sync = 0;
  bool _synchronized = false;
  int _errors = 0;
  String protocolVersion = '';

  int get blockSize => _blockSize;
  int get maxBlockSize => _maxBlockSize;
  int get errors => _errors;
  bool get isSynchronized => _synchronized;

  /// Fletcher-16 na variante usada pelo Marlin (módulo 255, não 65535).
  static int checksumStep(int checksum, int value) {
    final low = ((checksum & 0xFF) + value) % 255;
    final high = (((checksum >> 8) + low) % 255);
    return (high << 8) | low;
  }

  static int buildChecksum(List<int> bytes) {
    var checksum = 0;
    for (final byte in bytes) {
      checksum = checksumStep(checksum, byte);
    }
    return checksum;
  }

  /// Monta um pacote completo, incluindo token inicial e checksums.
  ///
  /// O checksum do payload cobre o cabeçalho *e* o checksum do cabeçalho,
  /// exatamente como a implementação de referência em Python.
  static Uint8List buildPacket(
    int protocolId,
    int packetType,
    int sync,
    Uint8List data,
  ) {
    final body = BytesBuilder();
    body.addByte(sync & 0xFF);
    body.addByte(((protocolId & 0xF) << 4) | (packetType & 0xF));
    body.add(_uint16(data.length));
    body.add(_uint16(buildChecksum(body.toBytes())));
    if (data.isNotEmpty) {
      body.add(data);
      body.add(_uint16(buildChecksum(body.toBytes())));
    }

    final packet = BytesBuilder();
    packet.add(_uint16(startToken));
    packet.add(body.toBytes());
    return packet.toBytes();
  }

  static Uint8List _uint16(int value) =>
      Uint8List.fromList([value & 0xFF, (value >> 8) & 0xFF]);

  void _onLine(String line) {
    for (final token in _transferTokens) {
      if (line.startsWith(token)) {
        _transfer.add(ProtocolResponse(token, line.substring(token.length)));
        return;
      }
    }
    for (final token in _connectionTokens) {
      if (line.startsWith(token)) {
        _connection.add(ProtocolResponse(token, line.substring(token.length)));
        return;
      }
    }
  }

  Future<ProtocolResponse> awaitTransferResponse([Duration? timeout]) =>
      _transfer.next(timeout ?? responseTimeout);

  /// Coloca o firmware em modo binário e sincroniza o contador de pacotes.
  Future<void> connect() async {
    _subscription ??= _transport.lines.listen(_onLine);
    _connection.clear();
    _transfer.clear();
    _synchronized = false;
    _errors = 0;
    await sendAscii('M28B1');
    await send(connectionProtocolId, connectionSync);
  }

  /// Devolve o firmware ao modo ASCII.
  Future<void> disconnect() async {
    await send(connectionProtocolId, connectionClose);
    _synchronized = false;
  }

  Future<void> shutdown() async {
    await _subscription?.cancel();
    _subscription = null;
    _connection.clear();
    _transfer.clear();
  }

  Future<void> sendAscii(String command, {bool sendAndForget = false}) async {
    final deadline = DateTime.now().add(responseTimeout * 20);
    while (true) {
      await _transport.writeLine(command);
      if (sendAndForget) {
        return;
      }
      try {
        await _connection.next(responseTimeout);
        return;
      } on TimeoutException {
        _errors += 1;
        if (DateTime.now().isAfter(deadline)) {
          throw MarlinProtocolException('Sem resposta para $command.');
        }
      }
    }
  }

  Future<void> send(
    int protocolId,
    int packetType, [
    Uint8List? data,
  ]) async {
    final payload = data ?? Uint8List(0);
    if (payload.length > _maxBlockSize) {
      throw MarlinProtocolException(
        'Payload de ${payload.length} bytes excede o bloco de $_maxBlockSize '
        'aceito pelo firmware.',
      );
    }

    final packet = buildPacket(protocolId, packetType, _sync, payload);
    final deadline = DateTime.now().add(responseTimeout * 20);
    while (true) {
      await _transport.writeBytes(packet);
      try {
        if (await _drainConnectionResponses()) {
          return;
        }
      } on TimeoutException {
        _errors += 1;
      }
      if (DateTime.now().isAfter(deadline)) {
        throw MarlinProtocolException(
          'A máquina parou de confirmar pacotes binários (sync $_sync).',
        );
      }
    }
  }

  Future<bool> _drainConnectionResponses() async {
    var acknowledged = false;
    var response = await _connection.next(responseTimeout);
    while (true) {
      switch (response.token) {
        case 'ok':
          if (_handleOk(response.payload)) {
            acknowledged = true;
          }
        case 'rs':
          _handleResend(response.payload);
        case 'ss':
          _handleStreamSync(response.payload);
          acknowledged = true;
        case 'fe':
          throw MarlinFatalException(
            'Erro fatal do firmware:${response.payload}',
          );
      }
      if (_connection.isEmpty) {
        return acknowledged;
      }
      response = _connection.removeFirst();
    }
  }

  bool _handleOk(String payload) {
    // Com ADVANCED_OK ligado, um `ok N12 P8 B7` de G-code também cai aqui.
    // Só o `ok <sync>` do modo binário é numérico puro.
    final id = int.tryParse(payload.trim());
    if (id == null) {
      return false;
    }
    if (id != _sync) {
      throw MarlinSyncException(
        'Pacote fora de ordem: esperado $_sync, recebido $id.',
      );
    }
    _sync = (_sync + 1) & 0xFF;
    return true;
  }

  void _handleResend(String payload) {
    _errors += 1;
    if (!_synchronized) {
      return;
    }
    final id = int.tryParse(payload.trim());
    if (id != null && id != _sync) {
      throw MarlinSyncException(
        'Reenvio fora de ordem: esperado $_sync, recebido $id.',
      );
    }
  }

  void _handleStreamSync(String payload) {
    final parts = payload.trim().split(',');
    if (parts.length < 3) {
      throw MarlinProtocolException('Resposta de sincronismo inválida: $payload');
    }
    final sync = int.tryParse(parts[0]);
    final maxBlockSize = int.tryParse(parts[1]);
    if (sync == null || maxBlockSize == null || maxBlockSize <= 0) {
      throw MarlinProtocolException('Resposta de sincronismo inválida: $payload');
    }
    _sync = sync;
    _maxBlockSize = maxBlockSize;
    if (_maxBlockSize < _blockSize) {
      _blockSize = _maxBlockSize;
    }
    protocolVersion = parts[2];
    _synchronized = true;
  }
}
