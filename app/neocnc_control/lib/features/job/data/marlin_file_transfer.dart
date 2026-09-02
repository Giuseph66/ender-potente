import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'marlin_binary_protocol.dart';

/// Camada de arquivo do protocolo binário (`protocol id` 1).
class MarlinFileTransfer {
  MarlinFileTransfer(this._protocol, {this.maxProtocolErrors = 0});

  static const int packetQuery = 0;
  static const int packetOpen = 1;
  static const int packetClose = 2;
  static const int packetWrite = 3;
  static const int packetAbort = 4;

  final MarlinBinaryProtocol _protocol;

  /// Quantos erros de protocolo tolerar antes de abortar a transferência.
  /// Zero reproduz o comportamento do cliente oficial: qualquer retransmissão
  /// derruba a cópia, porque um bloco perdido corrompe o arquivo em silêncio.
  final int maxProtocolErrors;

  String version = '';
  String compressionAlgorithm = 'none';

  Future<void> negotiate() async {
    await _protocol.send(
      MarlinBinaryProtocol.fileTransferProtocolId,
      packetQuery,
    );
    final response = await _protocol.awaitTransferResponse(
      const Duration(seconds: 2),
    );
    if (response.token != 'PFT:version:') {
      throw MarlinProtocolException(
        'A máquina não respondeu a versão do transporte de arquivos: '
        '${response.token}',
      );
    }
    // Formato: "<maj>.<min>.<patch>:compression:<algoritmo>[,janela,lookahead]"
    final parts = response.payload.split(':');
    version = parts.first;
    compressionAlgorithm = parts.length >= 3
        ? parts[2].split(',').first
        : 'none';
  }

  Future<void> openFile(
    String filename, {
    bool compression = false,
    bool dummy = false,
  }) async {
    final payload = BytesBuilder()
      ..addByte(dummy ? 1 : 0)
      ..addByte(compression ? 1 : 0)
      ..add(utf8.encode(filename))
      ..addByte(0);
    final data = payload.toBytes();

    var deadline = DateTime.now().add(const Duration(seconds: 5));
    await _protocol.send(
      MarlinBinaryProtocol.fileTransferProtocolId,
      packetOpen,
      data,
    );

    while (DateTime.now().isBefore(deadline)) {
      try {
        final response = await _protocol.awaitTransferResponse(
          const Duration(seconds: 1),
        );
        switch (response.token) {
          case 'PFT:success':
            return;
          case 'PFT:busy':
            // Transferência anterior ficou pendurada; limpa e tenta de novo.
            await abort();
            await Future<void>.delayed(const Duration(milliseconds: 100));
            await _protocol.send(
              MarlinBinaryProtocol.fileTransferProtocolId,
              packetOpen,
              data,
            );
            deadline = DateTime.now().add(const Duration(seconds: 5));
          case 'PFT:fail':
            throw MarlinProtocolException(
              'A máquina não conseguiu criar "$filename" no cartão.',
            );
        }
      } on TimeoutException {
        // Segue tentando até o prazo total.
      }
    }
    throw MarlinProtocolException(
      'A máquina não confirmou a abertura de "$filename".',
    );
  }

  Future<void> writeBlock(Uint8List data) => _protocol.send(
    MarlinBinaryProtocol.fileTransferProtocolId,
    packetWrite,
    data,
  );

  Future<void> closeFile() async {
    await _protocol.send(
      MarlinBinaryProtocol.fileTransferProtocolId,
      packetClose,
    );
    final response = await _protocol.awaitTransferResponse(
      const Duration(seconds: 5),
    );
    switch (response.token) {
      case 'PFT:success':
        return;
      case 'PFT:ioerror':
        throw const MarlinProtocolException(
          'Erro de escrita no cartão ao fechar o arquivo.',
        );
      default:
        throw MarlinProtocolException(
          'Fechamento recusado pela máquina: ${response.token}',
        );
    }
  }

  Future<void> abort() async {
    await _protocol.send(
      MarlinBinaryProtocol.fileTransferProtocolId,
      packetAbort,
    );
    try {
      await _protocol.awaitTransferResponse(const Duration(seconds: 2));
    } on TimeoutException {
      // Abortar é best-effort.
    }
  }

  /// Copia [data] para `destination` no cartão da máquina.
  Future<void> copy(
    Uint8List data,
    String destination, {
    void Function(double progress)? onProgress,
  }) async {
    await negotiate();
    await openFile(destination);

    final blockSize = _protocol.blockSize;
    if (blockSize <= 0) {
      throw const MarlinProtocolException(
        'A máquina informou bloco de transferência inválido.',
      );
    }
    final blocks = (data.length + blockSize - 1) ~/ blockSize;
    final errorsAtStart = _protocol.errors;

    for (var index = 0; index < blocks; index += 1) {
      final start = index * blockSize;
      final end = math.min(start + blockSize, data.length);
      await writeBlock(Uint8List.sublistView(data, start, end));
      onProgress?.call((index + 1) / blocks);

      if (_protocol.errors - errorsAtStart > maxProtocolErrors) {
        await closeFile().catchError((_) {});
        throw MarlinProtocolException(
          'Transferência abortada com ${_protocol.errors - errorsAtStart} '
          'erro(s) de protocolo. O arquivo no cartão não é confiável.',
        );
      }
    }

    await closeFile();
  }
}
