import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neocnc_control/main.dart';

void main() {
  testWidgets('exibe o painel de controle NeoCNC', (tester) async {
    await tester.pumpWidget(const NeoCncApp());

    expect(find.text('NEOCNC / CONTROL DESK'), findsOneWidget);
    expect(find.text('CONTROLE GLOBAL DA MÁQUINA'), findsOneWidget);
    expect(find.text('MAPA XY'), findsWidgets);
    expect(find.text('MAPA XY / DESTINO ABSOLUTO'), findsOneWidget);
  });

  testWidgets('navega para logs pelo drawer lateral', (tester) async {
    await tester.pumpWidget(const NeoCncApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LOGS E CONSOLE'));
    await tester.pumpAndSettle();

    expect(find.text('CONSOLE SERIAL'), findsOneWidget);
    expect(find.text('G-CODE MANUAL'), findsOneWidget);
  });

  testWidgets('abre o painel de trabalho de corte', (tester) async {
    await tester.pumpWidget(const NeoCncApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CORTE / CAM'));
    await tester.pumpAndSettle();

    expect(find.text('ARQUIVO DE CORTE'), findsOneWidget);
    expect(find.text('IMPORTAR .NC / .GCODE'), findsOneWidget);
    expect(find.text('ENVIO E EXECUÇÃO'), findsOneWidget);
    expect(find.text('GRAVAR NO CARTÃO'), findsOneWidget);
    expect(find.text('INICIAR CORTE'), findsOneWidget);
  });

  testWidgets('abre o editor de desenho XY', (tester) async {
    await tester.pumpWidget(const NeoCncApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DESENHO XY'));
    await tester.pumpAndSettle();

    expect(find.text('DESENHO LIVRE / PLOTTER XY'), findsOneWidget);
    expect(find.text('IMPORTAR IMAGEM P/B'), findsOneWidget);
    expect(find.text('IMPORTAR SVG'), findsOneWidget);
    expect(find.text('DESENHAR NA MÁQUINA'), findsOneWidget);
  });

  testWidgets('prévia do percurso desenha a rota traçada à mão', (
    tester,
  ) async {
    // Tela de desktop: o editor de desenho ocupa boa parte da janela.
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const NeoCncApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DESENHO XY'));
    await tester.pumpAndSettle();

    // Sem rota não há percurso para ver.
    final previewButton = find.widgetWithText(
      OutlinedButton,
      'VER O PERCURSO',
    );
    expect(previewButton, findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(previewButton).onPressed,
      isNull,
      reason: 'sem traços não há o que simular',
    );

    // Traça um risco na prévia da mesa.
    final canvas = find.byWidgetPredicate(
      (widget) =>
          widget is CustomPaint &&
          widget.painter.runtimeType.toString() == '_DrawingPainter',
    );
    expect(canvas, findsOneWidget);
    await tester.ensureVisible(canvas);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(canvas));
    await tester.pump();
    // Só na horizontal: um arrasto vertical seria capturado pela rolagem
    // da página em vez do editor de desenho.
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(
      tester.widget<OutlinedButton>(previewButton).onPressed,
      isNotNull,
      reason: 'com um traço o percurso pode ser visto',
    );
    await tester.tap(previewButton);
    await tester.pumpAndSettle();

    expect(find.text('PERCURSO VISÍVEL'), findsOneWidget);
    expect(find.text('SIMULAR'), findsOneWidget);
    expect(find.textContaining('DESENHO '), findsWidgets);
  });
}
