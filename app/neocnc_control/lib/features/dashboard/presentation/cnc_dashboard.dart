import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/neocnc_theme.dart';
import '../../printer/application/printer_controller.dart';
import '../../printer/domain/drawing_point.dart';
import '../../printer/domain/printer_snapshot.dart';

enum _ControlTab { map, drawing, relativeMotion, logs }

class CncDashboard extends StatefulWidget {
  const CncDashboard({super.key});

  @override
  State<CncDashboard> createState() => _CncDashboardState();
}

class _CncDashboardState extends State<CncDashboard> {
  late final PrinterController _controller;
  final TextEditingController _commandController = TextEditingController();
  String? _selectedPort;
  double _step = 1;
  double _feedrate = 40;
  bool _mapArmed = false;
  Offset? _mapTarget;
  final List<List<Offset>> _drawingStrokes = [];
  double _safeZ = 5;
  double _drawingZ = 0;
  _ControlTab _selectedTab = _ControlTab.map;
  String _printerModel = 'Ender-3 Neo / NeoCNC';
  bool _compactControls = false;

  @override
  void initState() {
    super.initState();
    _controller = PrinterController();
    unawaited(_refreshPorts());
  }

  @override
  void dispose() {
    _commandController.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refreshPorts() async {
    try {
      await _controller.refreshPorts();
      if (!mounted) {
        return;
      }
      final ports = _controller.ports;
      if (!ports.contains(_selectedPort)) {
        setState(() => _selectedPort = _preferredPort(ports));
      }
    } catch (_) {
      _showMessage('Não foi possível acessar as portas seriais.');
    }
  }

  String? _preferredPort(List<String> ports) {
    if (ports.isEmpty) {
      return null;
    }
    return ports.firstWhere(
      (port) => port.contains('ttyUSB') || port.contains('ttyACM'),
      orElse: () => ports.first,
    );
  }

  Future<void> _connectOrDisconnect() async {
    if (_controller.isConnected) {
      await _perform(_controller.disconnect);
      return;
    }
    final port = _selectedPort;
    if (port == null) {
      _showMessage('Selecione uma porta, por exemplo /dev/ttyUSB0.');
      return;
    }
    await _perform(() => _controller.connect(port));
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted) {
        _showMessage('$error');
      }
    }
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    String accept = 'CONFIRMAR',
    bool destructive = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: NeoCncColors.danger)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(accept),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _home(String? axis) async {
    final target = axis == null
        ? 'TODOS OS EIXOS'
        : axis == 'X Y'
        ? 'EIXOS X E Y'
        : 'EIXO $axis';
    final proceed = await _confirm(
      title: 'Referenciar $target?',
      body:
          'A máquina se movimentará até os fins de curso. Garanta que o '
          'curso esteja livre e que os limites estejam corretamente ligados.',
      accept: 'INICIAR HOMING',
    );
    if (proceed && mounted) {
      await _perform(() => _controller.home(axis));
      if (mounted) {
        setState(() => _mapArmed = false);
      }
    }
  }

  Future<void> _moveFromMap(Offset target) async {
    if (!_controller.isXyReferenced) {
      _showMessage('Faça HOME XY antes de usar o mapa.');
      return;
    }
    if (!_mapArmed) {
      _showMessage('Arme o mapa antes de enviar um destino.');
      return;
    }
    setState(() => _mapTarget = target);
    await _perform(
      () => _controller.moveTo(
        x: target.dx,
        y: target.dy,
        feedrateMmPerSecond: _feedrate,
      ),
    );
  }

  void _startDrawingStroke(Offset point) {
    if (_controller.isDrawing) {
      return;
    }
    setState(() => _drawingStrokes.add([point]));
  }

  void _extendDrawingStroke(Offset point) {
    if (_controller.isDrawing || _drawingStrokes.isEmpty) {
      return;
    }
    final stroke = _drawingStrokes.last;
    if ((stroke.last - point).distance < .55) {
      return;
    }
    setState(() => stroke.add(point));
  }

  void _finishDrawingStroke() {
    if (_drawingStrokes.isNotEmpty && _drawingStrokes.last.length < 2) {
      setState(() => _drawingStrokes.removeLast());
    }
  }

  void _clearDrawing() {
    if (_controller.isDrawing) {
      return;
    }
    setState(_drawingStrokes.clear);
  }

  Future<void> _sendDrawing() async {
    final strokeCount = _drawingStrokes
        .where((stroke) => stroke.length >= 2)
        .length;
    final segmentCount = _drawingStrokes.fold<int>(
      0,
      (total, stroke) => total + math.max(0, stroke.length - 1),
    );
    if (!_controller.isFullyReferenced) {
      _showMessage('Faça HOME XY e HOME Z antes de enviar o desenho.');
      return;
    }
    if (strokeCount == 0) {
      _showMessage('Desenhe ao menos um traço antes de enviar.');
      return;
    }
    final proceed = await _confirm(
      title: 'Enviar desenho para a máquina?',
      body:
          '$strokeCount traço(s) • $segmentCount segmento(s)\n\n'
          'A ferramenta irá para Z${_safeZ.toStringAsFixed(1)} mm entre traços '
          'e para Z${_drawingZ.toStringAsFixed(1)} mm ao desenhar.\n\n'
          'Confirme que uma caneta/ferramenta está montada e que Z0 foi calibrado sobre o papel.',
      accept: 'INICIAR DESENHO',
    );
    if (!proceed || !mounted) {
      return;
    }
    await _perform(
      () => _controller.draw(
        strokes: _drawingStrokes
            .map(
              (stroke) => stroke
                  .map((point) => DrawingPoint(x: point.dx, y: point.dy))
                  .toList(growable: false),
            )
            .toList(growable: false),
        safeZ: _safeZ,
        drawingZ: _drawingZ,
        feedrateMmPerSecond: _feedrate,
      ),
    );
  }

  Future<void> _sendManual() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      return;
    }
    final proceed = await _confirm(
      title: 'Executar G-code manual?',
      body:
          'Comando: $command\n\nExecute somente comandos que você revisou. '
          'Este painel não limita comandos manuais.',
      accept: 'ENVIAR',
      destructive: true,
    );
    if (proceed && mounted) {
      await _perform(() => _controller.sendManualCommand(command));
      if (mounted) {
        _commandController.clear();
      }
    }
  }

  Future<void> _autoConnect() async {
    await _refreshPorts();
    final port = _preferredPort(_controller.ports);
    if (port == null) {
      _showMessage('Nenhuma porta serial foi encontrada.');
      return;
    }
    if (mounted) {
      setState(() => _selectedPort = port);
    }
    if (_controller.isConnected) {
      await _perform(_controller.disconnect);
    }
    await _perform(() => _controller.connect(port));
  }

  Future<void> _openDeviceSettings() async {
    await _refreshPorts();
    if (!mounted) {
      return;
    }
    final selection = await showDialog<_DeviceSelection>(
      context: context,
      builder: (context) => _DeviceSettingsDialog(
        models: const [
          'Ender-3 Neo / NeoCNC',
          'Ender-3 V2',
          'Ender-3 (original)',
          'Outro equipamento Marlin',
        ],
        ports: _controller.ports,
        initialModel: _printerModel,
        initialPort: _selectedPort,
      ),
    );
    if (selection == null || !mounted) {
      return;
    }

    final port = selection.autoPort
        ? _preferredPort(_controller.ports)
        : selection.port;
    setState(() {
      _printerModel = selection.model;
      _selectedPort = port;
    });
    if (selection.connectNow && port != null) {
      if (_controller.isConnected) {
        await _perform(_controller.disconnect);
      }
      await _perform(() => _controller.connect(port));
    }
  }

  Future<void> _openInterfaceSettings() async {
    var compact = _compactControls;
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('INTERFACE'),
          content: SwitchListTile(
            value: compact,
            onChanged: (value) => setDialogState(() => compact = value),
            title: const Text('CONTROLES COMPACTOS'),
            subtitle: const Text('Reduz espaços entre controles e painéis.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('CANCELAR'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('APLICAR'),
            ),
          ],
        ),
      ),
    );
    if (save == true && mounted) {
      setState(() => _compactControls = compact);
    }
  }

  void _selectTab(int index) {
    setState(() => _selectedTab = _ControlTab.values[index]);
    Navigator.of(context).pop();
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final snapshot = _controller.snapshot;
        return Scaffold(
          drawer: _ControlDrawer(
            selectedTab: _selectedTab,
            printerModel: _printerModel,
            port: _selectedPort,
            connected: snapshot.isConnected,
            onDestinationSelected: _selectTab,
            onDeviceSettings: _openDeviceSettings,
          ),
          appBar: AppBar(
            backgroundColor: NeoCncColors.surface,
            foregroundColor: NeoCncColors.ink,
            elevation: 0,
            centerTitle: false,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'NEOCNC / CONTROL DESK',
                  style: TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                Text(
                  _printerModel,
                  style: const TextStyle(
                    color: NeoCncColors.muted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Dispositivo e porta USB',
                onPressed: _openDeviceSettings,
                icon: Icon(
                  snapshot.isConnected
                      ? Icons.usb_rounded
                      : Icons.usb_off_rounded,
                  color: snapshot.isConnected
                      ? NeoCncColors.cyan
                      : NeoCncColors.muted,
                ),
              ),
              IconButton(
                tooltip: 'Conexão automática USB',
                onPressed: _autoConnect,
                icon: const Icon(Icons.auto_mode_rounded),
              ),
              IconButton(
                tooltip: 'Configurações da interface',
                onPressed: _openInterfaceSettings,
                icon: const Icon(Icons.tune_rounded),
              ),
              IconButton(
                tooltip: 'Parada de emergência',
                onPressed: snapshot.isConnected
                    ? () => _perform(_controller.emergencyStop)
                    : null,
                color: NeoCncColors.danger,
                icon: const Icon(Icons.emergency_rounded),
              ),
              IconButton(
                tooltip: snapshot.isConnected ? 'Desconectar' : 'Conectar',
                onPressed: _connectOrDisconnect,
                icon: Icon(
                  snapshot.isConnected
                      ? Icons.link_off_rounded
                      : Icons.link_rounded,
                ),
              ),
            ],
          ),
          body: Theme(
            data: Theme.of(context).copyWith(
              visualDensity: _compactControls
                  ? VisualDensity.compact
                  : VisualDensity.standard,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: LayoutBuilder(
                builder: (context, constraints) => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _MachineControlStrip(
                      snapshot: snapshot,
                      feedrate: _feedrate,
                      onFeedrateChanged: (value) =>
                          setState(() => _feedrate = value),
                      onHome: _home,
                      onEnable: () => _perform(_controller.enableSteppers),
                      onDisable: () => _perform(_controller.disableSteppers),
                    ),
                    const SizedBox(height: 20),
                    _PageTitle(tab: _selectedTab),
                    const SizedBox(height: 10),
                    _buildPage(snapshot, constraints),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPage(PrinterSnapshot snapshot, BoxConstraints constraints) {
    final secondaryWidth = constraints.maxWidth >= 1050
        ? (constraints.maxWidth - 12) / 3
        : constraints.maxWidth;
    return switch (_selectedTab) {
      _ControlTab.map => _WorkMapPanel(
        snapshot: snapshot,
        armed: _mapArmed,
        xyReferenced: _controller.isXyReferenced,
        target: _mapTarget,
        onArmedChanged: (armed) {
          if (!_controller.isXyReferenced && armed) {
            _showMessage('Faça HOME XY antes de armar o mapa.');
            return;
          }
          setState(() => _mapArmed = armed);
        },
        onTarget: _moveFromMap,
      ),
      _ControlTab.drawing => _DrawingPanel(
        snapshot: snapshot,
        strokes: _drawingStrokes,
        safeZ: _safeZ,
        drawingZ: _drawingZ,
        feedrate: _feedrate,
        fullyReferenced: _controller.isFullyReferenced,
        running: _controller.isDrawing,
        completedSegments: _controller.drawingCompletedSegments,
        segmentCount: _controller.drawingSegmentCount,
        onSafeZChanged: (value) => setState(() {
          _safeZ = value;
          if (_drawingZ > value) {
            _drawingZ = value;
          }
        }),
        onDrawingZChanged: (value) => setState(() => _drawingZ = value),
        onStrokeStart: _startDrawingStroke,
        onStrokeExtend: _extendDrawingStroke,
        onStrokeEnd: _finishDrawingStroke,
        onClear: _clearDrawing,
        onSend: _sendDrawing,
      ),
      _ControlTab.relativeMotion => _MotionPanel(
        enabled: snapshot.isConnected,
        step: _step,
        feedrate: _feedrate,
        onStepChanged: (step) => setState(() => _step = step),
        onJog: (axis, distance) => _perform(
          () => _controller.jog(
            axis: axis,
            millimeters: distance,
            feedrateMmPerSecond: _feedrate,
          ),
        ),
      ),
      _ControlTab.logs => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: secondaryWidth,
            child: _TemperaturePanel(snapshot: snapshot),
          ),
          SizedBox(
            width: secondaryWidth,
            child: _SensorsPanel(snapshot: snapshot),
          ),
          SizedBox(
            width: constraints.maxWidth,
            child: _ConsolePanel(log: _controller.log),
          ),
          SizedBox(
            width: constraints.maxWidth,
            child: _ManualCommandPanel(
              enabled: snapshot.isConnected,
              controller: _commandController,
              onSend: _sendManual,
            ),
          ),
        ],
      ),
    };
  }
}

class _ControlDrawer extends StatelessWidget {
  const _ControlDrawer({
    required this.selectedTab,
    required this.printerModel,
    required this.port,
    required this.connected,
    required this.onDestinationSelected,
    required this.onDeviceSettings,
  });

  final _ControlTab selectedTab;
  final String printerModel;
  final String? port;
  final bool connected;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onDeviceSettings;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: NeoCncColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: NeoCncColors.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'MÁQUINA ATIVA',
                    style: TextStyle(
                      color: NeoCncColors.amber,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .8,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    printerModel,
                    style: const TextStyle(
                      color: NeoCncColors.ink,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    connected
                        ? '● ${port ?? 'SERIAL'} CONECTADA'
                        : '○ SEM CONEXÃO',
                    style: TextStyle(
                      color: connected ? NeoCncColors.cyan : NeoCncColors.muted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: NavigationDrawer(
                selectedIndex: selectedTab.index,
                onDestinationSelected: onDestinationSelected,
                children: const [
                  NavigationDrawerDestination(
                    icon: Icon(Icons.map_outlined),
                    selectedIcon: Icon(Icons.map_rounded),
                    label: Text('MAPA XY'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.gesture_outlined),
                    selectedIcon: Icon(Icons.gesture_rounded),
                    label: Text('DESENHO XY'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.open_with_outlined),
                    selectedIcon: Icon(Icons.open_with_rounded),
                    label: Text('MOVIMENTO'),
                  ),
                  NavigationDrawerDestination(
                    icon: Icon(Icons.terminal_outlined),
                    selectedIcon: Icon(Icons.terminal_rounded),
                    label: Text('LOGS E CONSOLE'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_input_component_rounded),
              title: const Text('DISPOSITIVO E USB'),
              subtitle: const Text(
                'Modelo, porta e conexão automática',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: onDeviceSettings,
            ),
          ],
        ),
      ),
    );
  }
}

class _MachineControlStrip extends StatelessWidget {
  const _MachineControlStrip({
    required this.snapshot,
    required this.feedrate,
    required this.onFeedrateChanged,
    required this.onHome,
    required this.onEnable,
    required this.onDisable,
  });

  final PrinterSnapshot snapshot;
  final double feedrate;
  final ValueChanged<double> onFeedrateChanged;
  final ValueChanged<String?> onHome;
  final VoidCallback onEnable;
  final VoidCallback onDisable;

  @override
  Widget build(BuildContext context) {
    final enabled = snapshot.isConnected;
    return _Panel(
      label: 'CONTROLE GLOBAL DA MÁQUINA',
      icon: Icons.precision_manufacturing_rounded,
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _GlobalCoordinate(axis: 'X', value: snapshot.x),
          _GlobalCoordinate(axis: 'Y', value: snapshot.y),
          _GlobalCoordinate(axis: 'Z', value: snapshot.z),
          SizedBox(
            width: 310,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VELOCIDADE GLOBAL  ${feedrate.round()} mm/s',
                  style: const TextStyle(
                    color: NeoCncColors.muted,
                    fontSize: 11,
                  ),
                ),
                Slider(
                  value: feedrate,
                  min: 5,
                  max: 300,
                  divisions: 295,
                  label: '${feedrate.round()} mm/s',
                  onChanged: enabled ? onFeedrateChanged : null,
                ),
              ],
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _HomeButton(
                label: 'X',
                enabled: enabled,
                onPressed: () => onHome('X'),
              ),
              _HomeButton(
                label: 'Y',
                enabled: enabled,
                onPressed: () => onHome('Y'),
              ),
              _HomeButton(
                label: 'Z',
                enabled: enabled,
                onPressed: () => onHome('Z'),
              ),
              _HomeButton(
                label: 'XY',
                enabled: enabled,
                onPressed: () => onHome('X Y'),
              ),
              FilledButton(
                onPressed: enabled ? () => onHome(null) : null,
                child: const Text('HOME ALL'),
              ),
              OutlinedButton(
                onPressed: enabled ? onEnable : null,
                child: const Text('M17'),
              ),
              OutlinedButton(
                onPressed: enabled ? onDisable : null,
                child: const Text('M18'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GlobalCoordinate extends StatelessWidget {
  const _GlobalCoordinate({required this.axis, required this.value});

  final String axis;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 102,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: NeoCncColors.canvas,
        border: Border.all(color: NeoCncColors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            axis,
            style: const TextStyle(
              color: NeoCncColors.amber,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value.toStringAsFixed(2),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const Text(
            'mm',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: enabled ? onPressed : null,
      child: Text('HOME $label'),
    );
  }
}

class _PageTitle extends StatelessWidget {
  const _PageTitle({required this.tab});

  final _ControlTab tab;

  @override
  Widget build(BuildContext context) {
    final (title, description) = switch (tab) {
      _ControlTab.map => (
        'MAPA XY',
        'Destino absoluto dentro da área de trabalho.',
      ),
      _ControlTab.drawing => (
        'DESENHO XY',
        'Trace no tapete; a máquina reproduz com a ferramenta em Z.',
      ),
      _ControlTab.relativeMotion => (
        'MOVIMENTO RELATIVO',
        'Jog por passo configurável usando a velocidade global.',
      ),
      _ControlTab.logs => (
        'LOGS E CONSOLE',
        'Telemetria, sensores, mensagens Marlin e G-code manual.',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: NeoCncColors.amber,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: .8,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          description,
          style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class _DeviceSelection {
  const _DeviceSelection({
    required this.model,
    required this.port,
    required this.autoPort,
    required this.connectNow,
  });

  final String model;
  final String? port;
  final bool autoPort;
  final bool connectNow;
}

class _DeviceSettingsDialog extends StatefulWidget {
  const _DeviceSettingsDialog({
    required this.models,
    required this.ports,
    required this.initialModel,
    required this.initialPort,
  });

  final List<String> models;
  final List<String> ports;
  final String initialModel;
  final String? initialPort;

  @override
  State<_DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<_DeviceSettingsDialog> {
  late String _model = widget.initialModel;
  late String? _port = widget.initialPort;
  bool _autoPort = true;
  bool _connectNow = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('DISPOSITIVO E PORTA USB'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _model,
              decoration: const InputDecoration(labelText: 'MODELO DA MÁQUINA'),
              items: widget.models
                  .map(
                    (model) =>
                        DropdownMenuItem(value: model, child: Text(model)),
                  )
                  .toList(),
              onChanged: (model) {
                if (model != null) {
                  setState(() => _model = model);
                }
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('ESCOLHER USB AUTOMATICAMENTE'),
              subtitle: const Text('Prioriza /dev/ttyUSB* e /dev/ttyACM*.'),
              value: _autoPort,
              onChanged: (value) => setState(() => _autoPort = value),
            ),
            if (!_autoPort) ...[
              const SizedBox(height: 4),
              DropdownButtonFormField<String>(
                initialValue: _port,
                decoration: const InputDecoration(labelText: 'PORTA SERIAL'),
                items: widget.ports
                    .map(
                      (port) =>
                          DropdownMenuItem(value: port, child: Text(port)),
                    )
                    .toList(),
                onChanged: (port) => setState(() => _port = port),
              ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('CONECTAR APÓS SALVAR'),
              value: _connectNow,
              onChanged: (value) => setState(() => _connectNow = value),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'A escolha de modelo identifica o equipamento no app; a comunicação continua Marlin serial.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CANCELAR'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _DeviceSelection(
              model: _model,
              port: _port,
              autoPort: _autoPort,
              connectNow: _connectNow,
            ),
          ),
          child: const Text('SALVAR'),
        ),
      ],
    );
  }
}

class _TemperaturePanel extends StatelessWidget {
  const _TemperaturePanel({required this.snapshot});

  final PrinterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'TEMPERATURAS',
      icon: Icons.thermostat_rounded,
      child: Column(
        children: [
          _TemperatureLine(
            label: 'BICO',
            actual: snapshot.hotendActual,
            target: snapshot.hotendTarget,
          ),
          const Divider(height: 22),
          _TemperatureLine(
            label: 'MESA',
            actual: snapshot.bedActual,
            target: snapshot.bedTarget,
          ),
          const SizedBox(height: 12),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Somente telemetria nesta versão.',
              style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _TemperatureLine extends StatelessWidget {
  const _TemperatureLine({
    required this.label,
    required this.actual,
    required this.target,
  });

  final String label;
  final double? actual;
  final double? target;

  @override
  Widget build(BuildContext context) {
    final measured = actual == null ? '—' : actual!.toStringAsFixed(1);
    final setpoint = target == null ? '—' : target!.toStringAsFixed(1);
    return Row(
      children: [
        Text(label, style: const TextStyle(color: NeoCncColors.muted)),
        const Spacer(),
        Text(
          '$measured °C',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        Text(' / $setpoint', style: const TextStyle(color: NeoCncColors.muted)),
      ],
    );
  }
}

class _WorkMapPanel extends StatelessWidget {
  const _WorkMapPanel({
    required this.snapshot,
    required this.armed,
    required this.xyReferenced,
    required this.target,
    required this.onArmedChanged,
    required this.onTarget,
  });

  static const _travel = 220.0;

  final PrinterSnapshot snapshot;
  final bool armed;
  final bool xyReferenced;
  final Offset? target;
  final ValueChanged<bool> onArmedChanged;
  final Future<void> Function(Offset target) onTarget;

  @override
  Widget build(BuildContext context) {
    final canArm = snapshot.isConnected && xyReferenced;
    final targetLabel = target == null
        ? '—'
        : 'X${target!.dx.toStringAsFixed(1)}  Y${target!.dy.toStringAsFixed(1)} mm';

    return _Panel(
      label: 'MAPA XY / DESTINO ABSOLUTO',
      icon: Icons.map_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                xyReferenced
                    ? 'ÁREA ÚTIL  X0–220 • Y0–220 mm'
                    : 'REFERENCIE XY PARA LIBERAR O MAPA',
                style: TextStyle(
                  color: xyReferenced ? NeoCncColors.cyan : NeoCncColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    armed ? 'MOVIMENTO ARMADO' : 'MAPA DESARMADO',
                    style: TextStyle(
                      color: armed ? NeoCncColors.amber : NeoCncColors.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Switch(
                    value: armed,
                    onChanged: canArm ? onArmedChanged : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(360.0, constraints.maxWidth);
              return Center(
                child: SizedBox.square(
                  dimension: side,
                  child: LayoutBuilder(
                    builder: (context, mapConstraints) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) {
                        final point = details.localPosition;
                        final x = (point.dx / mapConstraints.maxWidth * _travel)
                            .clamp(0.0, _travel)
                            .toDouble();
                        final y =
                            (_travel -
                                    point.dy /
                                        mapConstraints.maxHeight *
                                        _travel)
                                .clamp(0.0, _travel)
                                .toDouble();
                        unawaited(onTarget(Offset(x, y)));
                      },
                      child: CustomPaint(
                        painter: _WorkMapPainter(
                          current: xyReferenced
                              ? Offset(snapshot.x, snapshot.y)
                              : null,
                          target: target,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 9),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              const Text(
                '◉ posição atual',
                style: TextStyle(color: NeoCncColors.cyan, fontSize: 11),
              ),
              const Text(
                '◎ destino',
                style: TextStyle(color: NeoCncColors.amber, fontSize: 11),
              ),
              Text(
                'DESTINO  $targetLabel',
                style: const TextStyle(color: NeoCncColors.ink, fontSize: 11),
              ),
              const Text(
                'MALHA 20 mm',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Com o mapa armado, cada clique envia um G0 absoluto na velocidade definida abaixo.',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _WorkMapPainter extends CustomPainter {
  const _WorkMapPainter({required this.current, required this.target});

  static const _travel = 220.0;

  final Offset? current;
  final Offset? target;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final background = Paint()..color = NeoCncColors.canvas;
    final border = Paint()
      ..color = NeoCncColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .55)
      ..strokeWidth = 1;

    canvas.drawRect(area, background);
    for (var mm = 20.0; mm < _travel; mm += 20) {
      final x = mm / _travel * size.width;
      final y = size.height - mm / _travel * size.height;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawRect(area.deflate(.75), border);

    final machinePosition = current;
    if (machinePosition != null && _isWithin(machinePosition)) {
      _drawCurrent(canvas, _toCanvas(machinePosition, size));
    }
    final destination = target;
    if (destination != null && _isWithin(destination)) {
      _drawTarget(canvas, _toCanvas(destination, size));
    }
  }

  Offset _toCanvas(Offset point, Size size) {
    return Offset(
      point.dx / _travel * size.width,
      size.height - point.dy / _travel * size.height,
    );
  }

  bool _isWithin(Offset point) {
    return point.dx >= 0 &&
        point.dx <= _travel &&
        point.dy >= 0 &&
        point.dy <= _travel;
  }

  void _drawCurrent(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = NeoCncColors.cyan
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 8, paint);
    canvas.drawLine(point.translate(-13, 0), point.translate(13, 0), paint);
    canvas.drawLine(point.translate(0, -13), point.translate(0, 13), paint);
  }

  void _drawTarget(Canvas canvas, Offset point) {
    final paint = Paint()
      ..color = NeoCncColors.amber
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(point, 10, paint);
    canvas.drawCircle(point, 3, Paint()..color = NeoCncColors.amber);
  }

  @override
  bool shouldRepaint(covariant _WorkMapPainter oldDelegate) {
    return oldDelegate.current != current || oldDelegate.target != target;
  }
}

class _DrawingPanel extends StatelessWidget {
  const _DrawingPanel({
    required this.snapshot,
    required this.strokes,
    required this.safeZ,
    required this.drawingZ,
    required this.feedrate,
    required this.fullyReferenced,
    required this.running,
    required this.completedSegments,
    required this.segmentCount,
    required this.onSafeZChanged,
    required this.onDrawingZChanged,
    required this.onStrokeStart,
    required this.onStrokeExtend,
    required this.onStrokeEnd,
    required this.onClear,
    required this.onSend,
  });

  static const _travel = 220.0;

  final PrinterSnapshot snapshot;
  final List<List<Offset>> strokes;
  final double safeZ;
  final double drawingZ;
  final double feedrate;
  final bool fullyReferenced;
  final bool running;
  final int completedSegments;
  final int segmentCount;
  final ValueChanged<double> onSafeZChanged;
  final ValueChanged<double> onDrawingZChanged;
  final ValueChanged<Offset> onStrokeStart;
  final ValueChanged<Offset> onStrokeExtend;
  final VoidCallback onStrokeEnd;
  final VoidCallback onClear;
  final Future<void> Function() onSend;

  int get _strokeCount => strokes.where((stroke) => stroke.length >= 2).length;
  int get _segmentCount => strokes.fold<int>(
    0,
    (total, stroke) => total + math.max(0, stroke.length - 1),
  );

  @override
  Widget build(BuildContext context) {
    final progress = segmentCount == 0
        ? 0.0
        : (completedSegments / segmentCount).clamp(0.0, 1.0);
    return _Panel(
      label: 'DESENHO LIVRE / PLOTTER XY',
      icon: Icons.gesture_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                fullyReferenced
                    ? 'HOME XY + Z CONFIRMADO'
                    : 'FAÇA HOME XY + HOME Z PARA ENVIAR',
                style: TextStyle(
                  color: fullyReferenced
                      ? NeoCncColors.cyan
                      : NeoCncColors.amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '$_strokeCount TRAÇO(S) • $_segmentCount SEGMENTO(S)',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              if (running)
                const Text(
                  'MÁQUINA DESENHANDO',
                  style: TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final side = math.min(430.0, constraints.maxWidth);
              return Center(
                child: SizedBox.square(
                  dimension: side,
                  child: LayoutBuilder(
                    builder: (context, canvasConstraints) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: running
                          ? null
                          : (details) => onStrokeStart(
                              _toMachine(
                                details.localPosition,
                                canvasConstraints.biggest,
                              ),
                            ),
                      onPanUpdate: running
                          ? null
                          : (details) => onStrokeExtend(
                              _toMachine(
                                details.localPosition,
                                canvasConstraints.biggest,
                              ),
                            ),
                      onPanEnd: running ? null : (_) => onStrokeEnd(),
                      onPanCancel: running ? null : onStrokeEnd,
                      child: CustomPaint(
                        painter: _DrawingPainter(
                          strokes: strokes,
                          current: fullyReferenced
                              ? Offset(snapshot.x, snapshot.y)
                              : null,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (running) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 6),
            Text(
              'EXECUTANDO $completedSegments / $segmentCount SEGMENTOS',
              style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 18,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              SizedBox(
                width: 250,
                child: _DrawHeightControl(
                  label: 'Z SEGURO',
                  value: safeZ,
                  min: 1,
                  max: 25,
                  onChanged: running ? null : onSafeZChanged,
                ),
              ),
              SizedBox(
                width: 250,
                child: _DrawHeightControl(
                  label: 'Z DE TRAÇO',
                  value: drawingZ,
                  min: 0,
                  max: safeZ,
                  onChanged: running ? null : onDrawingZChanged,
                ),
              ),
              Text(
                'XY  ${feedrate.round()} mm/s\nZ  até 20 mm/s',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
              ),
              OutlinedButton.icon(
                onPressed: running || strokes.isEmpty ? null : onClear,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('LIMPAR'),
              ),
              FilledButton.icon(
                onPressed: running || _strokeCount == 0
                    ? null
                    : () => unawaited(onSend()),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('DESENHAR NA MÁQUINA'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Modo caneta: G0 sobe e reposiciona; G1 percorre o traço. Não extruda filamento. Calibre Z0 sobre o papel antes de iniciar.',
            style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Offset _toMachine(Offset local, Size size) {
    return Offset(
      (local.dx / size.width * _travel).clamp(0.0, _travel).toDouble(),
      (_travel - local.dy / size.height * _travel)
          .clamp(0.0, _travel)
          .toDouble(),
    );
  }
}

class _DrawHeightControl extends StatelessWidget {
  const _DrawHeightControl({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    final divisions = ((max - min) * 10).round().clamp(1, 250).toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label  ${value.toStringAsFixed(1)} mm',
          style: const TextStyle(color: NeoCncColors.muted, fontSize: 11),
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: '${value.toStringAsFixed(1)} mm',
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _DrawingPainter extends CustomPainter {
  const _DrawingPainter({required this.strokes, required this.current});

  static const _travel = 220.0;

  final List<List<Offset>> strokes;
  final Offset? current;

  @override
  void paint(Canvas canvas, Size size) {
    final area = Offset.zero & size;
    final background = Paint()..color = NeoCncColors.canvas;
    final border = Paint()
      ..color = NeoCncColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .55)
      ..strokeWidth = 1;
    canvas.drawRect(area, background);
    for (var mm = 20.0; mm < _travel; mm += 20) {
      final x = mm / _travel * size.width;
      final y = size.height - mm / _travel * size.height;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    canvas.drawRect(area.deflate(.75), border);

    final route = Paint()
      ..color = NeoCncColors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final point = Paint()..color = NeoCncColors.cyan;
    for (final stroke in strokes) {
      if (stroke.isEmpty) {
        continue;
      }
      final path = Path()
        ..moveTo(
          _toCanvas(stroke.first, size).dx,
          _toCanvas(stroke.first, size).dy,
        );
      for (final value in stroke.skip(1)) {
        final canvasPoint = _toCanvas(value, size);
        path.lineTo(canvasPoint.dx, canvasPoint.dy);
      }
      canvas.drawPath(path, route);
      canvas.drawCircle(_toCanvas(stroke.first, size), 3.5, point);
    }
    if (current != null && _isWithin(current!)) {
      final machinePoint = _toCanvas(current!, size);
      final machine = Paint()
        ..color = NeoCncColors.cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(machinePoint, 7, machine);
      canvas.drawLine(
        machinePoint.translate(-11, 0),
        machinePoint.translate(11, 0),
        machine,
      );
      canvas.drawLine(
        machinePoint.translate(0, -11),
        machinePoint.translate(0, 11),
        machine,
      );
    }
  }

  Offset _toCanvas(Offset point, Size size) => Offset(
    point.dx / _travel * size.width,
    size.height - point.dy / _travel * size.height,
  );

  bool _isWithin(Offset point) =>
      point.dx >= 0 &&
      point.dx <= _travel &&
      point.dy >= 0 &&
      point.dy <= _travel;

  @override
  bool shouldRepaint(covariant _DrawingPainter oldDelegate) => true;
}

class _MotionPanel extends StatelessWidget {
  const _MotionPanel({
    required this.enabled,
    required this.step,
    required this.feedrate,
    required this.onStepChanged,
    required this.onJog,
  });

  final bool enabled;
  final double step;
  final double feedrate;
  final ValueChanged<double> onStepChanged;
  final void Function(String axis, double distance) onJog;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'JOG / MOVIMENTO RELATIVO',
      icon: Icons.open_with_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PASSO  ${_formatMeasure(step)} mm',
            style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
          ),
          Slider(
            value: step,
            min: 0.1,
            max: 100,
            divisions: 999,
            label: '${_formatMeasure(step)} mm',
            onChanged: enabled ? onStepChanged : null,
          ),
          const SizedBox(height: 15),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  children: [
                    _JogButton(
                      label: 'Y+',
                      icon: Icons.keyboard_arrow_up_rounded,
                      enabled: enabled,
                      onPressed: () => onJog('Y', step),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _JogButton(
                          label: 'X−',
                          icon: Icons.keyboard_arrow_left_rounded,
                          enabled: enabled,
                          onPressed: () => onJog('X', -step),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: NeoCncColors.canvas,
                            border: Border.all(color: NeoCncColors.line),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('XY'),
                        ),
                        const SizedBox(width: 6),
                        _JogButton(
                          label: 'X+',
                          icon: Icons.keyboard_arrow_right_rounded,
                          enabled: enabled,
                          onPressed: () => onJog('X', step),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _JogButton(
                      label: 'Y−',
                      icon: Icons.keyboard_arrow_down_rounded,
                      enabled: enabled,
                      onPressed: () => onJog('Y', -step),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Column(
                children: [
                  const Text(
                    'EIXO Z',
                    style: TextStyle(color: NeoCncColors.muted),
                  ),
                  const SizedBox(height: 8),
                  _JogButton(
                    label: 'Z+',
                    icon: Icons.add_rounded,
                    enabled: enabled,
                    onPressed: () => onJog('Z', step),
                  ),
                  const SizedBox(height: 8),
                  _JogButton(
                    label: 'Z−',
                    icon: Icons.remove_rounded,
                    enabled: enabled,
                    onPressed: () => onJog('Z', -step),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Usando velocidade global: ${feedrate.round()} mm/s',
            style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  String _formatMeasure(double value) {
    return value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toStringAsFixed(1);
  }
}

class _JogButton extends StatelessWidget {
  const _JogButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: enabled ? onPressed : null,
      icon: Icon(icon),
      label: Text(label),
    );
  }
}

class _SensorsPanel extends StatelessWidget {
  const _SensorsPanel({required this.snapshot});

  final PrinterSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final sensors = snapshot.endstops.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return _Panel(
      label: 'SENSORES E MÍDIA',
      icon: Icons.sensors_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'FINS DE CURSO',
            style: TextStyle(color: NeoCncColors.muted),
          ),
          const SizedBox(height: 9),
          if (sensors.isEmpty)
            const Text('Conecte para consultar com M119.')
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: sensors
                  .map(
                    (sensor) =>
                        _SensorChip(name: sensor.key, value: sensor.value),
                  )
                  .toList(),
            ),
          const Divider(height: 28),
          const Text('MICROSD', style: TextStyle(color: NeoCncColors.muted)),
          const SizedBox(height: 6),
          Text(snapshot.sdStatus),
          if (snapshot.lastError != null) ...[
            const Divider(height: 28),
            const Text(
              'ÚLTIMO AVISO',
              style: TextStyle(color: NeoCncColors.danger, fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              snapshot.lastError!,
              style: const TextStyle(color: NeoCncColors.danger, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _SensorChip extends StatelessWidget {
  const _SensorChip({required this.name, required this.value});

  final String name;
  final String value;

  @override
  Widget build(BuildContext context) {
    final triggered = value == 'TRIGGERED';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (triggered ? NeoCncColors.amber : NeoCncColors.cyan).withValues(
          alpha: .10,
        ),
        border: Border.all(
          color: triggered ? NeoCncColors.amber : NeoCncColors.cyan,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$name  $value',
        style: TextStyle(
          color: triggered ? NeoCncColors.amber : NeoCncColors.cyan,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ConsolePanel extends StatelessWidget {
  const _ConsolePanel({required this.log});

  final List<String> log;

  @override
  Widget build(BuildContext context) {
    final visibleLog = log.reversed.take(11).toList().reversed;
    return _Panel(
      label: 'CONSOLE SERIAL',
      icon: Icons.terminal_rounded,
      child: Container(
        constraints: const BoxConstraints(minHeight: 170),
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF070A0D),
          border: Border.all(color: NeoCncColors.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          visibleLog.isEmpty
              ? 'Aguardando tráfego serial…'
              : visibleLog.join('\n'),
          style: const TextStyle(fontSize: 12, height: 1.45),
        ),
      ),
    );
  }
}

class _ManualCommandPanel extends StatelessWidget {
  const _ManualCommandPanel({
    required this.enabled,
    required this.controller,
    required this.onSend,
  });

  final bool enabled;
  final TextEditingController controller;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      label: 'G-CODE MANUAL',
      icon: Icons.code_rounded,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              enabled: enabled,
              controller: controller,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Ex.: M503  |  G0 X10 F1200',
                prefixText: '> ',
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: enabled ? onSend : null,
            icon: const Icon(Icons.send_rounded),
            label: const Text('REVISAR E ENVIAR'),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.label, required this.icon, required this.child});

  final String label;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: NeoCncColors.panel,
        border: Border.all(color: NeoCncColors.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: NeoCncColors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: NeoCncColors.amber,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .7,
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1),
          ),
          child,
        ],
      ),
    );
  }
}
