# NeoCNC Control

Aplicativo Flutter nativo para controlar uma Ender 3 Neo convertida em NeoCNC. A primeira entrega usa USB serial e protocolo Marlin; não é um site.

## Funções desta versão

- Lista e conecta portas USB seriais em `115200 8N1`.
- Lê identificação (`M115`), temperatura (`M105`), posição (`M114`), fins de curso (`M119`) e estado do microSD (`M27`).
- Atualiza o LCD da própria máquina com `M117` ao iniciar e concluir homing, jog e movimentos pelo mapa.
- Move X, Y e Z de modo relativo com passo contínuo entre `0,1` e `100 mm` e velocidade contínua de `5` a `300 mm/s` (o limite final ainda é imposto pelo Marlin).
- Traz mapa XY clicável de `220 × 220 mm`: após `HOME XY` e armar o mapa, cada clique envia um destino absoluto `G0` dentro da área útil.
- Organiza as funções em um Drawer lateral: mapa XY, movimento relativo e logs/console. Posição, homes por eixo e velocidade ficam globais em todas as telas.
- Permite escolher visualmente o modelo da máquina e a porta USB, ou usar a seleção automática que prioriza dispositivos USB/ACM.
- Oferece homing com confirmação, M17/M18, parada de emergência M112 e console de G-code manual confirmado.
- Mantém o transporte separado da interface: Wi-Fi/TCP ou BLE de um ESP32 entram depois como outro `PrinterTransport`.

## Executar no Linux

```bash
flutter pub get
flutter run -d linux
```

Para acessar `/dev/ttyUSB0`, o usuário Linux normalmente precisa pertencer ao grupo `dialout` e reiniciar a sessão após a alteração:

```bash
sudo usermod -aG dialout $USER
```

## Segurança

Use o jog, o mapa e o homing somente com a área de trabalho livre, limites testados e supervisão. O mapa exige `HOME XY` e fica restrito a X0–220/Y0–220 mm; confira se essas dimensões correspondem à sua área CNC antes de movimentar. O painel não controla aquecimento nesta versão. `M112` é imediato e normalmente exige reinício físico da controladora antes de novos comandos.
