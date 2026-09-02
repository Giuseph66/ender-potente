import 'dart:typed_data';

abstract interface class PrinterTransport {
  Stream<String> get lines;

  bool get isConnected;

  String? get activePort;

  /// Velocidade da porta aberta, ou `null` quando não há conexão.
  int? get activeBaudRate;

  Future<List<String>> listPorts();

  Future<void> connect(String portName, {int baudRate});

  Future<void> disconnect();

  Future<void> writeLine(String command);

  /// Escreve bytes crus, sem terminador. Usado pelo protocolo binário do
  /// Marlin (`M28 B1`), que não é orientado a linhas.
  Future<void> writeBytes(Uint8List payload);

  Future<void> dispose();
}
