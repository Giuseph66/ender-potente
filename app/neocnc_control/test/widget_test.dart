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

  testWidgets('abre o editor de desenho XY', (tester) async {
    await tester.pumpWidget(const NeoCncApp());

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('DESENHO XY'));
    await tester.pumpAndSettle();

    expect(find.text('DESENHO LIVRE / PLOTTER XY'), findsOneWidget);
    expect(find.text('DESENHAR NA MÁQUINA'), findsOneWidget);
  });
}
