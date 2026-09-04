import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/features/job/domain/gcode_job.dart';
import 'package:neocnc_control/features/job/presentation/job_panel.dart';

Widget _harness({
  required bool connected,
  required bool spindleOn,
  VoidCallback? onSpindleOn,
  VoidCallback? onSpindleOff,
  ValueChanged<int>? onSpindlePowerChanged,
  ValueChanged<int>? onSpindlePowerCommitted,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: JobPanel(
          job: null,
          limits: MachineLimits.neoCnc,
          violations: const [],
          remoteName: null,
          zOffsetMm: 0,
          importing: false,
          uploading: false,
          uploadProgress: 0,
          uploadedName: null,
          connected: connected,
          fullyReferenced: false,
          sdJobName: null,
          sdStatus: '',
          sdProgress: null,
          spindleOn: spindleOn,
          spindlePower: 100,
          onImport: () {},
          onZOffsetChanged: (_) {},
          onZOffsetCommitted: (_) {},
          onUpload: () {},
          onStart: () {},
          onPause: () {},
          onResume: () {},
          onAbort: () {},
          onSpindleOn: onSpindleOn ?? () {},
          onSpindleOff: onSpindleOff ?? () {},
          onSpindlePowerChanged: onSpindlePowerChanged ?? (_) {},
          onSpindlePowerCommitted: onSpindlePowerCommitted ?? (_) {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('desconectado explica por que não dá para comandar', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1600, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(connected: false, spindleOn: false));
    await tester.pumpAndSettle();

    expect(find.text('SEM CONEXÃO'), findsOneWidget);
    expect(
      find.text('Conecte a máquina para comandar a ferramenta.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('spindle-on')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('conectado e desligado libera o M3', (tester) async {
    tester.view.physicalSize = const ui.Size(1600, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var ligou = false;
    await tester.pumpWidget(
      _harness(
        connected: true,
        spindleOn: false,
        onSpindleOn: () => ligou = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('FERRAMENTA DESLIGADA'), findsOneWidget);
    await tester.tap(find.byKey(const Key('spindle-on')));
    expect(ligou, isTrue);
  });

  testWidgets('com a ferramenta ligada avisa e mantém o M5 disponível', (
    tester,
  ) async {
    tester.view.physicalSize = const ui.Size(1600, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    var desligou = false;
    await tester.pumpWidget(
      _harness(
        connected: true,
        spindleOn: true,
        onSpindleOff: () => desligou = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('FERRAMENTA LIGADA'), findsOneWidget);
    // Ligar de novo não faz sentido; desligar tem que estar sempre à mão.
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('spindle-on')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const Key('spindle-off')));
    expect(desligou, isTrue);
  });
}
