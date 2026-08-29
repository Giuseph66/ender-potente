# Arquitetura

Na Fase 1, a mainboard Creality executa Marlin/NeoCNC e mantém todo controle de movimento. A única alteração planejada é software de interface: nome da máquina e Snake no LCD/encoder original.

```text
LCD + encoder → NeoCNC (Marlin) → mainboard Creality → motores/sensores
```

ESP32/NeoBridge fica fora desta fase. Em fase futura, ele será interface Wi-Fi/BLE e falará G-code por UART, sem assumir STEP/DIR ou controle em tempo real.
