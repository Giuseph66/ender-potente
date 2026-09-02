import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/job/application/gcode_importer.dart';
import 'package:neocnc_control/features/job/domain/gcode_job.dart';

const _flatCamIsolation = '''
(Isolation routing)
G21
G90
G94
M03 S1000
G00 Z2.0000
G00 X10.0000 Y10.0000
G01 Z-0.1000 F60
G01 X20.0000 Y10.0000 F120
G01 X20.0000 Y30.0000
G00 Z2.0000
M05
M30
''';

void main() {
  test('lê um arquivo de isolação do FlatCAM', () {
    final job = GcodeImporter.parse(_flatCamIsolation, name: 'isola');

    expect(job.bounds.minX, 10);
    expect(job.bounds.maxX, 20);
    expect(job.bounds.minY, 10);
    expect(job.bounds.maxY, 30);
    expect(job.bounds.minZ, closeTo(-.1, 1e-9));
    expect(job.bounds.maxZ, 2);
    expect(job.usesSpindle, isTrue);
    expect(job.cutLengthMm, closeTo(2.1 + 10 + 20, 1e-6));
    expect(job.cutPaths, isNotEmpty);
    expect(job.travelPaths, isNotEmpty);
  });

  test('recusa Z negativo e aceita depois do deslocamento', () {
    final raw = GcodeImporter.parse(_flatCamIsolation, name: 'isola');
    expect(
      raw.violationsFor(MachineLimits.neoCnc).join(' '),
      contains('mergulha até Z'),
    );

    final shifted = GcodeImporter.parse(
      _flatCamIsolation,
      name: 'isola',
      zOffsetMm: .1,
    );
    expect(shifted.bounds.minZ, closeTo(0, 1e-9));
    expect(shifted.violationsFor(MachineLimits.neoCnc), isEmpty);
    expect(
      GcodeImporter.render(shifted.commands, name: 'isola'),
      contains('G1 Z0 F60'),
    );
  });

  test('converte polegadas para milímetros', () {
    final job = GcodeImporter.parse(
      'G20\nG90\nG01 X1 Y2 F10\n',
      name: 'polegadas',
    );

    expect(job.bounds.maxX, closeTo(25.4, 1e-9));
    expect(job.bounds.maxY, closeTo(50.8, 1e-9));
    expect(job.warnings, contains(contains('polegadas convertido')));
    expect(
      GcodeImporter.render(job.commands, name: 'polegadas'),
      contains('X25.4 Y50.8'),
    );
  });

  test('reescreve trechos relativos em coordenadas absolutas', () {
    final job = GcodeImporter.parse(
      'G21\nG90\nG01 X10 Y10 F100\nG91\nG01 X5 Y0\nG01 X0 Y5\n',
      name: 'relativo',
    );

    expect(job.bounds.maxX, 15);
    expect(job.bounds.maxY, 15);
    final rendered = GcodeImporter.render(job.commands, name: 'relativo');
    expect(rendered, contains('G90'));
    expect(rendered, isNot(contains('G91')));
    expect(rendered, contains('X15 Y10'));
    expect(rendered, contains('X15 Y15'));
  });

  test('achata arcos G2 para o preview e para os limites', () {
    // Meia volta de raio 5 em torno de (5,0): o topo do arco chega a Y=5,
    // fora da corda que liga os extremos.
    final job = GcodeImporter.parse(
      'G21\nG90\nG01 X0 Y0 F100\nG02 X10 Y0 I5 J0\n',
      name: 'arco',
    );

    expect(job.bounds.maxY, closeTo(5, .01));
    expect(job.bounds.maxX, closeTo(10, .01));
    expect(job.cutLengthMm, closeTo(5 * 3.14159, .05));
  });

  test('avisa sobre múltiplas ferramentas e ausência de spindle', () {
    final job = GcodeImporter.parse(
      'G21\nG90\nT1 M6\nG01 X1 Y1 F100\nT2 M6\nG01 X2 Y2\n',
      name: 'multi',
    );

    expect(job.tools, {1, 2});
    expect(job.usesSpindle, isFalse);
    expect(job.warnings, contains(contains('2 ferramentas')));
    expect(job.warnings, contains(contains('não liga a ferramenta')));
  });

  test('aponta trabalho fora da mesa', () {
    final job = GcodeImporter.parse(
      'G21\nG90\nG01 X300 Y10 F100\n',
      name: 'grande',
    );

    expect(
      job.violationsFor(MachineLimits.neoCnc).join(' '),
      contains('ultrapassa a mesa'),
    );
  });

  test('gera nome 8.3 aceito pelo M23', () {
    expect(GcodeJob.toShortFilename('placa-isolacao-v2.nc'), 'PLACAISO.GCO');
    expect(GcodeJob.toShortFilename('/tmp/furos.drl'), 'FUROS.GCO');
    expect(GcodeJob.toShortFilename('---.nc'), 'JOB.GCO');
  });
}
