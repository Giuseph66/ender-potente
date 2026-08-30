class PrinterSnapshot {
  const PrinterSnapshot({
    this.isConnected = false,
    this.portName,
    this.machineName = 'AGUARDANDO CONEXÃO',
    this.firmware = '—',
    this.x = 0,
    this.y = 0,
    this.z = 0,
    this.hotendActual,
    this.hotendTarget,
    this.bedActual,
    this.bedTarget,
    this.endstops = const {},
    this.sdStatus = 'Não consultado',
    this.lastError,
  });

  final bool isConnected;
  final String? portName;
  final String machineName;
  final String firmware;
  final double x;
  final double y;
  final double z;
  final double? hotendActual;
  final double? hotendTarget;
  final double? bedActual;
  final double? bedTarget;
  final Map<String, String> endstops;
  final String sdStatus;
  final String? lastError;

  PrinterSnapshot copyWith({
    bool? isConnected,
    String? portName,
    String? machineName,
    String? firmware,
    double? x,
    double? y,
    double? z,
    double? hotendActual,
    double? hotendTarget,
    double? bedActual,
    double? bedTarget,
    Map<String, String>? endstops,
    String? sdStatus,
    String? lastError,
    bool clearPortName = false,
    bool clearLastError = false,
  }) {
    return PrinterSnapshot(
      isConnected: isConnected ?? this.isConnected,
      portName: clearPortName ? null : portName ?? this.portName,
      machineName: machineName ?? this.machineName,
      firmware: firmware ?? this.firmware,
      x: x ?? this.x,
      y: y ?? this.y,
      z: z ?? this.z,
      hotendActual: hotendActual ?? this.hotendActual,
      hotendTarget: hotendTarget ?? this.hotendTarget,
      bedActual: bedActual ?? this.bedActual,
      bedTarget: bedTarget ?? this.bedTarget,
      endstops: endstops ?? this.endstops,
      sdStatus: sdStatus ?? this.sdStatus,
      lastError: clearLastError ? null : lastError ?? this.lastError,
    );
  }
}
