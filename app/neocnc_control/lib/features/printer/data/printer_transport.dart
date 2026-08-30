abstract interface class PrinterTransport {
  Stream<String> get lines;

  bool get isConnected;

  String? get activePort;

  Future<List<String>> listPorts();

  Future<void> connect(String portName);

  Future<void> disconnect();

  Future<void> writeLine(String command);

  Future<void> dispose();
}
