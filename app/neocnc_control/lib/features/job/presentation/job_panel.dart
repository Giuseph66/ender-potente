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
                    label: Text(
                      importing ? 'LENDO…' : 'IMPORTAR .NC / .GCODE',
                    ),
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
            child: AspectRatio(
              aspectRatio: 1,
              child: CustomPaint(
                painter: _JobPreviewPainter(job: current, limits: limits),
                child: const SizedBox.expand(),
              ),
            ),
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
                    style: TextStyle(
                      color: NeoCncColors.amber,
                      fontSize: 11,
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              const Divider(height: 1),
              const SizedBox(height: 14),
              Text(
                'CARTÃO  $sdStatus',
                style: const TextStyle(
                  color: NeoCncColors.muted,
                  fontSize: 12,
                ),
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
                'M3 liga o relé da microrretífica na saída FAN0 e espera o '
                'tempo de partida; M5 desliga. Sem PWM nesse pino: é liga e '
                'desliga.',
                style: TextStyle(color: NeoCncColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    onPressed: connected ? onSpindleOn : null,
                    icon: const Icon(Icons.power_settings_new_rounded),
                    label: const Text('LIGAR (M3)'),
                  ),
                  OutlinedButton.icon(
                    onPressed: connected ? onSpindleOff : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: NeoCncColors.danger,
                    ),
                    icon: const Icon(Icons.power_off_rounded),
                    label: const Text('DESLIGAR (M5)'),
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
        _Metric(label: 'TEMPO EST.', value: _formatDuration(job.estimatedDuration)),
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

class _JobPreviewPainter extends CustomPainter {
  const _JobPreviewPainter({required this.job, required this.limits});

  final GcodeJob job;
  final MachineLimits limits;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / limits.maxX;

    // Y da máquina cresce para o fundo da mesa; a tela cresce para baixo.
    Offset toCanvas(Offset point) =>
        Offset(point.dx * scale, size.height - point.dy * scale);

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = NeoCncColors.canvas,
    );

    final grid = Paint()
      ..color = NeoCncColors.line.withValues(alpha: .5)
      ..strokeWidth = 1;
    for (var mm = 0.0; mm <= limits.maxX; mm += 20) {
      canvas.drawLine(
        toCanvas(Offset(mm, 0)),
        toCanvas(Offset(mm, limits.maxY)),
        grid,
      );
      canvas.drawLine(
        toCanvas(Offset(0, mm)),
        toCanvas(Offset(limits.maxX, mm)),
        grid,
      );
    }

    void drawPaths(List<List<Offset>> paths, Paint paint) {
      for (final path in paths) {
        if (path.length < 2) {
          continue;
        }
        final drawn = Path()..moveTo(
          toCanvas(path.first).dx,
          toCanvas(path.first).dy,
        );
        for (final point in path.skip(1)) {
          final mapped = toCanvas(point);
          drawn.lineTo(mapped.dx, mapped.dy);
        }
        canvas.drawPath(drawn, paint);
      }
    }

    drawPaths(
      job.travelPaths,
      Paint()
        ..color = NeoCncColors.muted.withValues(alpha: .35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    drawPaths(
      job.cutPaths,
      Paint()
        ..color = NeoCncColors.cyan
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );

    if (!job.bounds.isEmpty) {
      final topLeft = toCanvas(Offset(job.bounds.minX, job.bounds.maxY));
      final bottomRight = toCanvas(Offset(job.bounds.maxX, job.bounds.minY));
      canvas.drawRect(
        Rect.fromPoints(topLeft, bottomRight),
        Paint()
          ..color = NeoCncColors.amber.withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_JobPreviewPainter oldDelegate) =>
      oldDelegate.job != job || oldDelegate.limits != limits;
}

String _formatDuration(Duration duration) {
  if (duration.inMinutes < 1) {
    return '${duration.inSeconds}s';
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  return hours > 0 ? '${hours}h ${minutes}min' : '${minutes}min';
}
