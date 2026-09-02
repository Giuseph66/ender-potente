# Arquitetura

Na Fase 1, a mainboard Creality executa Marlin/NeoCNC e mantém todo controle de movimento. A única alteração planejada é software de interface: nome da máquina e Snake no LCD/encoder original.

```text
LCD + encoder → NeoCNC (Marlin) → mainboard Creality → motores/sensores
```

ESP32/NeoBridge fica fora desta fase. Em fase futura, ele será interface Wi-Fi/BLE e falará G-code por UART, sem assumir STEP/DIR ou controle em tempo real.

## Caminho de um trabalho de corte

O desk em `app/neocnc_control` não transmite o corte: ele grava o arquivo no
cartão e manda a máquina executar de lá.

```text
.nc do CAM → GcodeImporter (mm, absoluto, Z deslocado, limites)
           → MarlinBinaryProtocol/MarlinFileTransfer (M28 B1 + BFT)
           → cartão → M23/M24 → progresso por M27
```

A alternativa — `G1` linha a linha esperando `ok` — custa um round-trip serial
por segmento. É o que `PrinterController.draw()` ainda faz para o plotter, e é
aceitável ali; para isolação de PCB, com milhares de segmentos curtos, o planner
esvazia entre os movimentos e a ferramenta marca a peça a cada parada.
