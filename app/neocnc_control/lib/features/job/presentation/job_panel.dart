import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../core/theme/neocnc_theme.dart';
import '../domain/gcode_job.dart';

/// Painel de trabalho de corte: importa um `.nc`/`.gcode`, confere o envelope,
/// grava no cartão da máquina e comanda a execução.
class JobPanel extends StatelessWidget {
  const JobPanel({
    super.key,
    required this.job,
    required this.limits,
    required this.violations,
    required this.remoteName,
    required this.zOffsetMm,
    required this.importing,
    required this.uploading,
    required this.uploadProgress,
    required this.uploadedName,
    required this.connected,
    required this.fullyReferenced,
    required this.sdJobName,
    required this.sdStatus,
    required this.sdProgress,
    required this.onImport,
    required this.onZOffsetChanged,
    required this.onZOffsetCommitted,
    required this.onUpload,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onAbort,
    required this.onSpindleOn,
    required this.onSpindleOff,
    required this.spindleOn,
    required this.spindlePower,
    required this.onSpindlePowerChanged,
    required this.onSpindlePowerCommitted,
  });

  final GcodeJob? job;
  final MachineLimits limits;
  final List<String> violations;
  final String? remoteName;
  final double zOffsetMm;
  final bool importing;
  final bool uploading;
  final double uploadProgress;
  final String? uploadedName;
  final bool connected;
  final bool fullyReferenced;
  final String? sdJobName;
  final String sdStatus;
  final double? sdProgress;
  final VoidCallback onImport;
  final ValueChanged<double> onZOffsetChanged;
  final ValueChanged<double> onZOffsetCommitted;
  final VoidCallback onUpload;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onAbort;
  final VoidCallback onSpindleOn;
  final VoidCallback onSpindleOff;
  final int spindlePower;
  final ValueChanged<int> onSpindlePowerChanged;
  final ValueChanged<int> onSpindlePowerCommitted;

  /// Estado da ferramenta segundo os `M3`/`M5` que o app confirmou.
  final bool spindleOn;

  bool get _readyToUpload =>
      job != null && violations.isEmpty && connected && !uploading;

  bool get _readyToStart =>
      uploadedName != null &&
      connected &&
      fullyReferenced &&
      !uploading &&
      sdJobName == null;

  @override
  Widget build(BuildContext context) {
    final current = job;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _JobSection(
          label: 'ARQUIVO DE CORTE',
          icon: Icons.description_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Aceita G-code de CAM (FlatCAM, pcb2gcode). O arquivo é '
                'convertido para milímetros, coordenadas absolutas e o Z '
                'deslocado para a altura da placa antes de subir.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: importing ? null : onImport,
                    icon: importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open_rounded),
                    label: Text(importing ? 'LENDO…' : 'IMPORTAR .NC / .GCODE'),
                  ),
                ],
              ),
              if (current != null) ...[
                const SizedBox(height: 16),
                _JobSummary(job: current, remoteName: remoteName),
              ],
            ],
          ),
        ),
        if (current != null) ...[
          const SizedBox(height: 12),
          _JobSection(
            label: 'ALTURA DA PLACA',
            icon: Icons.height_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'DESLOCAMENTO DE Z  ${zOffsetMm.toStringAsFixed(2)} mm  '
                  '→ plano de corte em '
                  'Z${current.bounds.minZ.toStringAsFixed(3)} mm',
                  style: const TextStyle(
                    color: NeoCncColors.muted,
                    fontSize: 12,
                  ),
                ),
                Slider(
                  value: zOffsetMm.clamp(0, 20),
                  max: 20,
                  divisions: 400,
                  label: '${zOffsetMm.toStringAsFixed(2)} mm',
                  onChanged: uploading ? null : onZOffsetChanged,
                  onChangeEnd: uploading ? null : onZOffsetCommitted,
                ),
                const Text(
                  'O CAM entrega o mergulho em Z negativo, contado a partir da '
                  'superfície do cobre. O firmware recusa Z negativo: some aqui '
                  'a altura medida da placa sobre a mesa.',
                  style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _JobSection(
            label: 'PREVIEW NA MESA',
            icon: Icons.grid_on_rounded,
            child: _JobPreview(job: current, limits: limits),
          ),
          if (violations.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MessageList(
              label: 'IMPEDE O ENVIO',
              icon: Icons.block_rounded,
              color: NeoCncColors.danger,
              messages: violations,
            ),
          ],
          if (current.warnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            _MessageList(
              label: 'CONFERIR ANTES DE RODAR',
              icon: Icons.warning_amber_rounded,
              color: NeoCncColors.amber,
              messages: current.warnings,
            ),
          ],
        ],
        const SizedBox(height: 12),
        _JobSection(
          label: 'ENVIO E EXECUÇÃO',
          icon: Icons.sd_card_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'O arquivo vai para o cartão pelo protocolo binário do Marlin '
                'e roda de lá. A máquina lê no próprio ritmo, sem depender do '
                'PC nem da latência do USB.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              if (uploading) ...[
                LinearProgressIndicator(
                  value: uploadProgress,
                  backgroundColor: NeoCncColors.canvas,
                ),
                const SizedBox(height: 6),
                Text(
                  'GRAVANDO  ${(uploadProgress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (uploadedName != null && !uploading)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '● $uploadedName gravado no cartão',
                    style: const TextStyle(
                      color: NeoCncColors.cyan,
                      fontSize: 12,
                    ),
                  ),
                ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _readyToUpload ? onUpload : null,
                    icon: const Icon(Icons.upload_rounded),
                    label: const Text('GRAVAR NO CARTÃO'),
                  ),
                  FilledButton.icon(
                    onPressed: _readyToStart ? onStart : null,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('INICIAR CORTE'),
                  ),
                  OutlinedButton.icon(
                    onPressed: sdJobName != null ? onPause : null,
                    icon: const Icon(Icons.pause_rounded),
                    label: const Text('PAUSAR'),
                  ),
                  OutlinedButton.icon(
                    onPressed: sdJobName != null ? onResume : null,
                    icon: const Icon(Icons.play_circle_outline_rounded),
                    label: const Text('RETOMAR'),
                  ),
                  OutlinedButton.icon(
                    onPressed: sdJobName != null ? onAbort : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NeoCncColors.danger,
                    ),
                    icon: const Icon(Icons.stop_rounded),
                    label: const Text('ABORTAR'),
                  ),
                ],
              ),
              if (!fullyReferenced)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Faça HOME XY e HOME Z antes de iniciar: sem referência a '
                    'máquina não sabe onde está a placa.',
                    style: TextStyle(color: NeoCncColors.amber, fontSize: 11),
                  ),
                ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Text(
                'CARTÃO  $sdStatus',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              if (sdProgress != null) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: sdProgress,
                  backgroundColor: NeoCncColors.canvas,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _JobSection(
          label: 'FERRAMENTA',
          icon: Icons.settings_input_svideo_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Saída HOTEND: PWM de 1 a 100% via M3 S1…S100. Conecte '
                'somente ao opto/driver externo; nunca a microrretífica '
                'direto na placa.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              _SpindleState(on: spindleOn, connected: connected),
              const SizedBox(height: 12),
              Text(
                'POTÊNCIA PWM  $spindlePower%',
                style: const TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              Slider(
                value: spindlePower.toDouble(),
                min: 1,
                max: 100,
                divisions: 99,
                label: '$spindlePower%',
                onChanged: (value) => onSpindlePowerChanged(value.round()),
                onChangeEnd: (value) => onSpindlePowerCommitted(value.round()),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const Key('spindle-on'),
                    onPressed: connected && !spindleOn ? onSpindleOn : null,
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: Text('LIGAR $spindlePower% (M3)'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('spindle-off'),
                    onPressed: connected ? onSpindleOff : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NeoCncColors.danger,
                    ),
                    icon: const Icon(Icons.power_off_rounded),
                    label: const Text('DESLIGAR (M5)'),
                  ),
                  if (!connected)
                    const Text(
                      'Conecte a máquina para comandar a ferramenta.',
                      style: TextStyle(color: NeoCncColors.muted, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Estado da ferramenta em destaque: uma fresa girando é o item mais
/// perigoso da máquina, e até agora a tela não dizia se ela estava ligada.
class _SpindleState extends StatelessWidget {
  const _SpindleState({required this.on, required this.connected});

  final bool on;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = !connected
        ? NeoCncColors.muted
        : on
        ? NeoCncColors.danger
        : NeoCncColors.cyan;
    final label = !connected
        ? 'SEM CONEXÃO'
        : on
        ? 'FERRAMENTA LIGADA'
        : 'FERRAMENTA DESLIGADA';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        border: Border.all(color: color.withValues(alpha: .6)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            on && connected
                ? Icons.warning_amber_rounded
                : Icons.check_circle_outline_rounded,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _JobSummary extends StatelessWidget {
  const _JobSummary({required this.job, required this.remoteName});

  final GcodeJob job;
  final String? remoteName;

  @override
  Widget build(BuildContext context) {
    final bounds = job.bounds;
    return Wrap(
      spacing: 22,
      runSpacing: 10,
      children: [
        _Metric(label: 'ARQUIVO', value: job.name),
        if (remoteName != null) _Metric(label: 'NO CARTÃO', value: remoteName!),
        _Metric(
          label: 'TAMANHO',
          value: '${(job.byteSize / 1024).toStringAsFixed(1)} KiB',
        ),
        _Metric(label: 'COMANDOS', value: '${job.commandCount}'),
        _Metric(
          label: 'ÁREA',
          value:
              '${bounds.width.toStringAsFixed(1)} × '
              '${bounds.height.toStringAsFixed(1)} mm',
        ),
        _Metric(
          label: 'ORIGEM',
          value:
              'X${bounds.minX.toStringAsFixed(1)} '
              'Y${bounds.minY.toStringAsFixed(1)}',
        ),
        _Metric(
          label: 'Z',
          value:
              '${bounds.minZ.toStringAsFixed(2)} … '
              '${bounds.maxZ.toStringAsFixed(2)} mm',
        ),
        _Metric(
          label: 'CORTE',
          value: '${job.cutLengthMm.toStringAsFixed(0)} mm',
        ),
        _Metric(
          label: 'DESLOCAMENTO',
          value: '${job.travelLengthMm.toStringAsFixed(0)} mm',
        ),
        _Metric(
          label: 'TEMPO EST.',
          value: _formatDuration(job.estimatedDuration),
        ),
        _Metric(
          label: 'FERRAMENTAS',
          value: job.tools.isEmpty ? '—' : job.tools.join(', '),
        ),
      ],
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: NeoCncColors.muted,
            fontSize: 10,
            letterSpacing: .7,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(
            color: NeoCncColors.ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MessageList extends StatelessWidget {
  const _MessageList({
    required this.label,
    required this.icon,
    required this.color,
    required this.messages,
  });

  final String label;
  final IconData icon;
  final Color color;
  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NeoCncColors.panel,
        border: Border.all(color: color.withValues(alpha: .5)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: .7,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final message in messages)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '— $message',
                style: const TextStyle(
                  color: NeoCncColors.ink,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _JobSection extends StatelessWidget {
  const _JobSection({
    required this.label,
    required this.icon,
    required this.child,
  });

  final String label;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
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

/// Preview do trabalho na mesa. O corte quase sempre é bem menor que a mesa
/// (uma placa de 40 x 30 mm ocupa 2% de uma mesa 220 x 220), então dá para
/// enquadrar o trabalho em vez de olhar a mesa inteira.
/// Enquadramento em milímetros de máquina: a mesa toda, ou o envelope do
/// trabalho com uma folga em volta.
({double minX, double minY, double maxX, double maxY}) _viewportFor(
  GcodeJob job,
  MachineLimits limits,
  bool fitToJob,
) {
  final bounds = job.bounds;
  if (!fitToJob || bounds.isEmpty) {
    return (minX: 0, minY: 0, maxX: limits.maxX, maxY: limits.maxY);
  }
  final margin = math.max(2.0, math.max(bounds.width, bounds.height) * .14);
  return (
    minX: bounds.minX - margin,
    minY: bounds.minY - margin,
    maxX: bounds.maxX + margin,
    maxY: bounds.maxY + margin,
  );
}

class _JobPreview extends StatefulWidget {
  const _JobPreview({required this.job, required this.limits});

  final GcodeJob job;
  final MachineLimits limits;

  @override
  State<_JobPreview> createState() => _JobPreviewState();
}

class _JobPreviewState extends State<_JobPreview>
    with SingleTickerProviderStateMixin {
  static const _minDuration = Duration(seconds: 3);
  static const _maxDuration = Duration(seconds: 20);

  bool _fitToJob = true;
  late final AnimationController _playback;

  @override
  void initState() {
    super.initState();
    _playback = AnimationController(vsync: this)
      ..addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_JobPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.job != widget.job) {
      _playback
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _playback.dispose();
    super.dispose();
  }

  void _togglePlayback() {
    if (_playback.isAnimating) {
      _playback.stop();
      setState(() {});
      return;
    }
    if (widget.job.moves.isEmpty) {
      return;
    }
    // Roda numa escala confortável de assistir: um corte de meia hora não
    // pode levar meia hora aqui.
    final scaled = widget.job.estimatedDuration.inMilliseconds ~/ 12;
    _playback.duration = Duration(
      milliseconds: scaled.clamp(
        _minDuration.inMilliseconds,
        _maxDuration.inMilliseconds,
      ),
    );
    if (_playback.value >= 1) {
      _playback.value = 0;
    }
    _playback.forward();
  }

  double _viewAspect(bool fitToJob) {
    final view = _viewportFor(widget.job, widget.limits, fitToJob);
    final width = math.max(1.0, view.maxX - view.minX);
    final height = math.max(1.0, view.maxY - view.minY);
    // Sem extremos: uma tira muito fina viraria uma linha inútil na tela.
    return (width / height).clamp(.6, 2.2);
  }

  @override
  Widget build(BuildContext context) {
    final canFit = !widget.job.bounds.isEmpty;
    final fitToJob = _fitToJob && canFit;
    final canSimulate = widget.job.moves.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  icon: Icon(Icons.center_focus_strong_rounded, size: 16),
                  label: Text('TRABALHO'),
                ),
                ButtonSegment(
                  value: false,
                  icon: Icon(Icons.grid_on_rounded, size: 16),
                  label: Text('MESA INTEIRA'),
                ),
              ],
              selected: {fitToJob},
              onSelectionChanged: canFit
                  ? (selection) => setState(() => _fitToJob = selection.first)
                  : null,
            ),
            FilledButton.tonalIcon(
              key: const Key('job-preview-playback'),
              onPressed: canSimulate ? _togglePlayback : null,
              icon: Icon(
                _playback.isAnimating
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
              ),
              label: Text(_playback.isAnimating ? 'PAUSAR' : 'SIMULAR'),
            ),
            const _PreviewLegend(),
          ],
        ),
        if (canSimulate) ...[
          Row(
            children: [
              Expanded(
                child: Slider(
                  key: const Key('job-preview-scrub'),
                  value: _playback.value.clamp(0, 1),
                  onChanged: (value) {
                    _playback.stop();
                    setState(() => _playback.value = value);
                  },
                ),
              ),
              SizedBox(
                width: 130,
                child: Text(
                  '${(_playback.value * 100).round()}%  •  '
                  '${(widget.job.previewLength * _playback.value).round()} '
                  'de ${widget.job.previewLength.round()} mm',
                  style: const TextStyle(
                    color: NeoCncColors.cyan,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ] else
          const SizedBox(height: 10),
        // A caixa acompanha a proporção do que está enquadrado: um trabalho
        // largo e baixo não precisa de um quadrado cheio de vazio.
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 460),
            child: AspectRatio(
              aspectRatio: _viewAspect(fitToJob),
              child: CustomPaint(
                painter: _JobPreviewPainter(
                  job: widget.job,
                  limits: widget.limits,
                  fitToJob: fitToJob,
                  // Em repouso no começo mostra o traçado inteiro em força
                  // total; a simulação só assume depois que ela anda.
                  progress: canSimulate && _playback.value > 0
                      ? _playback.value
                      : null,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewLegend extends StatelessWidget {
  const _PreviewLegend();

  @override
  Widget build(BuildContext context) {
    return const Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        _LegendItem(color: NeoCncColors.cyan, label: 'CORTE'),
        _LegendItem(
          color: NeoCncColors.muted,
          label: 'DESLOCAMENTO',
          dashed: true,
        ),
        _LegendItem(color: NeoCncColors.amber, label: 'ENVELOPE'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 2,
          decoration: BoxDecoration(
            color: dashed ? null : color,
            border: dashed ? Border.all(color: color, width: 1) : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(color: NeoCncColors.muted, fontSize: 10),
        ),
      ],
    );
  }
}

class _JobPreviewPainter extends CustomPainter {
  const _JobPreviewPainter({
    required this.job,
    required this.limits,
    required this.fitToJob,
    this.progress,
  });

  final GcodeJob job;
  final MachineLimits limits;

  /// Enquadra o envelope do trabalho em vez da mesa inteira.
  final bool fitToJob;

  /// Fração do trabalho já percorrida na simulação (nulo = sem simulação).
  final double? progress;

  /// Passos de grade e de barra de escala que dão números redondos.
  static const _niceSteps = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = NeoCncColors.canvas);

    final bounds = job.bounds;
    final view = _viewportFor(job, limits, fitToJob);
    final viewMinX = view.minX;
    final viewMinY = view.minY;
    final viewMaxX = view.maxX;
    final viewMaxY = view.maxY;
    final viewWidth = math.max(1.0, viewMaxX - viewMinX);
    final viewHeight = math.max(1.0, viewMaxY - viewMinY);
    final scale = math.min(size.width / viewWidth, size.height / viewHeight);
    final drawWidth = viewWidth * scale;
    final drawHeight = viewHeight * scale;
    final originX = (size.width - drawWidth) / 2;
    final originY = (size.height - drawHeight) / 2;

    // Y da máquina cresce para o fundo da mesa; a tela cresce para baixo.
    Offset toCanvas(Offset point) => Offset(
      originX + (point.dx - viewMinX) * scale,
      originY + drawHeight - (point.dy - viewMinY) * scale,
    );

    _paintGrid(canvas, size, viewMinX, viewMinY, viewMaxX, viewMaxY, toCanvas);

    // Contorno da mesa: mostra onde acaba o curso mesmo com zoom.
    canvas.drawRect(
      Rect.fromPoints(
        toCanvas(Offset(0, limits.maxY)),
        toCanvas(Offset(limits.maxX, 0)),
      ),
      Paint()
        ..color = NeoCncColors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    final simulation = progress;
    if (simulation != null) {
      _paintSimulation(canvas, toCanvas, simulation);
    } else {
      _paintPaths(
        canvas,
        job.travelPaths,
        toCanvas,
        Paint()
          ..color = NeoCncColors.muted.withValues(alpha: .5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
        dashed: true,
      );
      _paintPaths(
        canvas,
        job.cutPaths,
        toCanvas,
        Paint()
          ..color = NeoCncColors.cyan
          ..style = PaintingStyle.stroke
          ..strokeWidth = fitToJob ? 2.2 : 1.6
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    if (!bounds.isEmpty) {
      _paintEnvelope(canvas, bounds, toCanvas);
    }
    _paintOrigin(canvas, toCanvas, viewMinX, viewMinY, viewMaxX, viewMaxY);
    _paintScaleBar(canvas, size, scale);
    if (fitToJob && !bounds.isEmpty) {
      _paintMinimap(canvas, size, bounds);
    }
  }

  void _paintGrid(
    Canvas canvas,
    Size size,
    double viewMinX,
    double viewMinY,
    double viewMaxX,
    double viewMaxY,
    Offset Function(Offset) toCanvas,
  ) {
    final step = _niceStep(
      math.max(viewMaxX - viewMinX, viewMaxY - viewMinY) / 8,
    );
    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .5)
      ..strokeWidth = 1;
    for (var mm = (viewMinX / step).ceil() * step; mm <= viewMaxX; mm += step) {
      canvas.drawLine(
        toCanvas(Offset(mm, viewMinY)),
        toCanvas(Offset(mm, viewMaxY)),
        grid,
      );
      _label(
        canvas,
        _number(mm),
        toCanvas(Offset(mm, viewMinY)).translate(2, -12),
      );
    }
    for (var mm = (viewMinY / step).ceil() * step; mm <= viewMaxY; mm += step) {
      canvas.drawLine(
        toCanvas(Offset(viewMinX, mm)),
        toCanvas(Offset(viewMaxX, mm)),
        grid,
      );
      _label(
        canvas,
        _number(mm),
        toCanvas(Offset(viewMinX, mm)).translate(3, 2),
      );
    }
  }

  void _paintPaths(
    Canvas canvas,
    List<List<Offset>> paths,
    Offset Function(Offset) toCanvas,
    Paint paint, {
    bool dashed = false,
  }) {
    for (final path in paths) {
      if (path.length < 2) {
        continue;
      }
      if (dashed) {
        for (var i = 0; i + 1 < path.length; i++) {
          _dashedLine(canvas, toCanvas(path[i]), toCanvas(path[i + 1]), paint);
        }
        continue;
      }
      final drawn = Path();
      final first = toCanvas(path.first);
      drawn.moveTo(first.dx, first.dy);
      for (final point in path.skip(1)) {
        final mapped = toCanvas(point);
        drawn.lineTo(mapped.dx, mapped.dy);
      }
      canvas.drawPath(drawn, paint);
    }
  }

  /// Desenha o trabalho até onde a simulação chegou: o que já passou em
  /// destaque, o que falta apagado, e a ferramenta na posição atual.
  void _paintSimulation(
    Canvas canvas,
    Offset Function(Offset) toCanvas,
    double progress,
  ) {
    final doneCut = Paint()
      ..color = NeoCncColors.cyan
      ..style = PaintingStyle.stroke
      ..strokeWidth = fitToJob ? 2.4 : 1.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final pendingCut = Paint()
      ..color = NeoCncColors.cyan.withValues(alpha: .2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = fitToJob ? 2.0 : 1.4
      ..strokeCap = StrokeCap.round;
    final doneTravel = Paint()
      ..color = NeoCncColors.muted.withValues(alpha: .65)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final pendingTravel = Paint()
      ..color = NeoCncColors.muted.withValues(alpha: .15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    final target = job.previewLength * progress.clamp(0.0, 1.0);
    var walked = 0.0;
    for (final move in job.moves) {
      final from = toCanvas(move.from);
      final to = toCanvas(move.to);
      final end = walked + move.length;
      final done = end <= target;
      final partial = !done && walked < target && move.length > 0;
      final cut = Offset.lerp(
        from,
        to,
        move.length <= 0
            ? 0
            : ((target - walked) / move.length).clamp(0.0, 1.0),
      )!;
      if (move.cutting) {
        canvas.drawLine(from, to, done ? doneCut : pendingCut);
        if (partial) {
          canvas.drawLine(from, cut, doneCut);
        }
      } else {
        _dashedLine(canvas, from, to, done ? doneTravel : pendingTravel);
        if (partial) {
          _dashedLine(canvas, from, cut, doneTravel);
        }
      }
      walked = end;
    }

    final sample = job.sampleAt(target);
    final head = toCanvas(sample.position);
    canvas.drawCircle(
      head,
      7,
      Paint()
        ..color = (sample.cutting ? NeoCncColors.cyan : NeoCncColors.muted)
            .withValues(alpha: .22),
    );
    canvas.drawCircle(
      head,
      3.6,
      Paint()
        ..color = sample.cutting ? NeoCncColors.cyan : NeoCncColors.ink
        ..style = sample.cutting ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  void _paintEnvelope(
    Canvas canvas,
    GcodeBounds bounds,
    Offset Function(Offset) toCanvas,
  ) {
    final rect = Rect.fromPoints(
      toCanvas(Offset(bounds.minX, bounds.maxY)),
      toCanvas(Offset(bounds.maxX, bounds.minY)),
    );
    final paint = Paint()
      ..color = NeoCncColors.amber.withValues(alpha: .75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    _dashedLine(canvas, rect.topLeft, rect.topRight, paint);
    _dashedLine(canvas, rect.topRight, rect.bottomRight, paint);
    _dashedLine(canvas, rect.bottomRight, rect.bottomLeft, paint);
    _dashedLine(canvas, rect.bottomLeft, rect.topLeft, paint);

    _label(
      canvas,
      '${bounds.width.toStringAsFixed(1)} × '
      '${bounds.height.toStringAsFixed(1)} mm',
      rect.topLeft.translate(0, -14),
      color: NeoCncColors.amber,
    );
    _label(
      canvas,
      'X${_number(bounds.minX)} Y${_number(bounds.minY)}',
      rect.bottomLeft.translate(0, 3),
      color: NeoCncColors.amber.withValues(alpha: .7),
    );
  }

  void _paintOrigin(
    Canvas canvas,
    Offset Function(Offset) toCanvas,
    double viewMinX,
    double viewMinY,
    double viewMaxX,
    double viewMaxY,
  ) {
    if (viewMinX > 0 || viewMinY > 0 || viewMaxX < 0 || viewMaxY < 0) {
      return;
    }
    final origin = toCanvas(Offset.zero);
    final paint = Paint()
      ..color = NeoCncColors.ink.withValues(alpha: .6)
      ..strokeWidth = 1.2;
    canvas.drawLine(origin.translate(-7, 0), origin.translate(7, 0), paint);
    canvas.drawLine(origin.translate(0, -7), origin.translate(0, 7), paint);
    _label(canvas, 'X0 Y0', origin.translate(8, 2));
  }

  /// Régua: sem ela não dá para saber o tamanho do que está na tela quando o
  /// enquadramento muda.
  void _paintScaleBar(Canvas canvas, Size size, double scale) {
    final target = size.width / 4 / scale;
    final millimeters = _niceStep(target);
    final pixels = millimeters * scale;
    final y = size.height - 12;
    final left = 12.0;
    final paint = Paint()
      ..color = NeoCncColors.ink.withValues(alpha: .75)
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(left, y), Offset(left + pixels, y), paint);
    canvas.drawLine(Offset(left, y - 4), Offset(left, y + 4), paint);
    canvas.drawLine(
      Offset(left + pixels, y - 4),
      Offset(left + pixels, y + 4),
      paint,
    );
    _label(
      canvas,
      '${_number(millimeters)} mm',
      Offset(left, y - 20),
      color: NeoCncColors.ink.withValues(alpha: .75),
    );
  }

  /// Com zoom no trabalho perde-se a noção de onde ele fica na mesa; o
  /// minimapa devolve isso.
  void _paintMinimap(Canvas canvas, Size size, GcodeBounds bounds) {
    const side = 62.0;
    final rect = Rect.fromLTWH(size.width - side - 10, 10, side, side);
    canvas.drawRect(
      rect,
      Paint()..color = NeoCncColors.surface.withValues(alpha: .9),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = NeoCncColors.line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final scale = math.min(side / limits.maxX, side / limits.maxY);
    Offset toMini(Offset point) =>
        Offset(rect.left + point.dx * scale, rect.bottom - point.dy * scale);
    final job = Rect.fromPoints(
      toMini(Offset(bounds.minX, bounds.maxY)),
      toMini(Offset(bounds.maxX, bounds.minY)),
    );
    canvas.drawRect(
      // Um trabalho pequeno vira um ponto: garante que dê para ver.
      Rect.fromCenter(
        center: job.center,
        width: math.max(3, job.width),
        height: math.max(3, job.height),
      ),
      Paint()..color = NeoCncColors.amber,
    );
  }

  void _dashedLine(Canvas canvas, Offset from, Offset to, Paint paint) {
    const dash = 4.0;
    const gap = 3.0;
    final total = (to - from).distance;
    if (total <= 0) {
      return;
    }
    final step = (to - from) / total;
    var walked = 0.0;
    while (walked < total) {
      final end = math.min(walked + dash, total);
      canvas.drawLine(from + step * walked, from + step * end, paint);
      walked = end + gap;
    }
  }

  void _label(Canvas canvas, String text, Offset at, {Color? color}) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color ?? NeoCncColors.muted.withValues(alpha: .8),
          fontSize: 9,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  static double _niceStep(double target) {
    for (final step in _niceSteps) {
      if (step >= target) {
        return step;
      }
    }
    return _niceSteps.last;
  }

  static String _number(double value) {
    if (value == value.roundToDouble()) {
      return value.toInt().toString();
    }
    return value.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(_JobPreviewPainter oldDelegate) =>
      oldDelegate.job != job ||
      oldDelegate.limits != limits ||
      oldDelegate.fitToJob != fitToJob ||
      oldDelegate.progress != progress;
}

String _formatDuration(Duration duration) {
  if (duration.inMinutes < 1) {
    return '${duration.inSeconds}s';
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  return hours > 0 ? '${hours}h ${minutes}min' : '${minutes}min';
}
