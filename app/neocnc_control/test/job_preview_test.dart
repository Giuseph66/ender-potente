import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/job/domain/gcode_job.dart';
import 'package:neocnc_control/features/job/presentation/job_panel.dart';

GcodeJob _job({
  double minX = 10,
  double maxX = 50,
  double minY = 20,
  double maxY = 50,
}) {
  return GcodeJob(
    name: 'pcb.nc',
    commands: const [],
    bounds: GcodeBounds(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      minZ: -1.5,
      maxZ: 5,
    ),
    cutPaths: [
      [ui.Offset(minX, minY), ui.Offset(maxX, minY), ui.Offset(maxX, maxY)],
    ],
    travelPaths: [
      [ui.Offset(maxX, maxY), ui.Offset(minX, minY)],
    ],
    moves: [
      JobMove(
        from: const ui.Offset(0, 0),
        to: ui.Offset(minX, minY),
        kind: GcodeMoveKind.rapid,
      ),
      JobMove(
        from: ui.Offset(minX, minY),
        to: ui.Offset(maxX, minY),
        kind: GcodeMoveKind.feed,
      ),
      JobMove(
        from: ui.Offset(maxX, minY),
        to: ui.Offset(maxX, maxY),
        kind: GcodeMoveKind.feed,
      ),
    ],
    cutLengthMm: 183,
    travelLengthMm: 103,
    estimatedDuration: const Duration(minutes: 1),
    tools: const {},
    usesSpindle: false,
    warnings: const [],
    blockingIssues: const [],
    byteSize: 300,
  );
}

Widget _harness(GcodeJob job) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: JobPanel(
          job: job,
          limits: MachineLimits.neoCnc,
          violations: const [],
          remoteName: 'PCB.GCO',
          zOffsetMm: 0,
          importing: false,
          uploading: false,
          uploadProgress: 0,
          uploadedName: null,
          connected: false,
          fullyReferenced: false,
          sdJobName: null,
          sdStatus: '',
          sdProgress: null,
          onImport: () {},
          onZOffsetChanged: (_) {},
          onZOffsetCommitted: (_) {},
          onUpload: () {},
          onStart: () {},
          onPause: () {},
          onResume: () {},
          onAbort: () {},
          onSpindleOn: () {},
          onSpindleOff: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('preview abre enquadrado no trabalho e alterna para a mesa', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_job()));
    await tester.pumpAndSettle();

    expect(find.text('PREVIEW NA MESA'), findsOneWidget);
    // Legenda do preview (o rótulo também aparece nas estatísticas do topo).
    expect(find.text('CORTE'), findsWidgets);
    expect(find.text('DESLOCAMENTO'), findsWidgets);
    expect(find.text('ENVELOPE'), findsOneWidget);

    final toggle = find.byType(SegmentedButton<bool>);
    expect(toggle, findsOneWidget);
    // Começa enquadrado no trabalho, que é o caso comum: uma placa pequena
    // numa mesa grande.
    expect(
      tester.widget<SegmentedButton<bool>>(toggle).selected,
      {true},
    );

    await tester.tap(find.text('MESA INTEIRA'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<SegmentedButton<bool>>(toggle).selected,
      {false},
    );
  });

  testWidgets('sem geometria o enquadramento no trabalho fica indisponível', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final empty = GcodeJob(
      name: 'vazio.nc',
      commands: const [],
      bounds: GcodeBounds.empty,
      cutPaths: const [],
      travelPaths: const [],
      cutLengthMm: 0,
      travelLengthMm: 0,
      estimatedDuration: Duration.zero,
      tools: const {},
      usesSpindle: false,
      warnings: const [],
      blockingIssues: const [],
      byteSize: 0,
    );

    await tester.pumpWidget(_harness(empty));
    await tester.pumpAndSettle();

    final toggle = find.byType(SegmentedButton<bool>);
    expect(
      tester.widget<SegmentedButton<bool>>(toggle).onSelectionChanged,
      isNull,
    );
    expect(
      tester.widget<SegmentedButton<bool>>(toggle).selected,
      {false},
      reason: 'sem envelope só resta mostrar a mesa inteira',
    );
  });

  testWidgets('simula o trabalho e permite arrastar pelo percurso', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(_job()));
    await tester.pumpAndSettle();

    const playback = Key('job-preview-playback');
    expect(
      find.descendant(of: find.byKey(playback), matching: find.text('SIMULAR')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(playback));
    await tester.pump();
    expect(
      find.descendant(of: find.byKey(playback), matching: find.text('PAUSAR')),
      findsOneWidget,
    );

    // Com a animação em curso o progresso avança.
    await tester.pump(const Duration(seconds: 1));
    final slider = tester.widget<Slider>(
      find.byKey(const Key('job-preview-scrub')),
    );
    expect(slider.value, greaterThan(0));

    await tester.tap(find.byKey(playback));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(playback), matching: find.text('SIMULAR')),
      findsOneWidget,
    );
  });

  testWidgets('sem movimentos não há o que simular', (tester) async {
    tester.view.physicalSize = const ui.Size(1600, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final semMovimentos = GcodeJob(
      name: 'x.nc',
      commands: const [],
      bounds: const GcodeBounds(
        minX: 0,
        maxX: 10,
        minY: 0,
        maxY: 10,
        minZ: 0,
        maxZ: 1,
      ),
      cutPaths: const [],
      travelPaths: const [],
      cutLengthMm: 0,
      travelLengthMm: 0,
      estimatedDuration: Duration.zero,
      tools: const {},
      usesSpindle: false,
      warnings: const [],
      blockingIssues: const [],
      byteSize: 0,
    );

    await tester.pumpWidget(_harness(semMovimentos));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('job-preview-playback'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
  });
}
