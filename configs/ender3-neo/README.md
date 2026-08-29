# Configuração Ender-3 Neo

Status: configurada; compilação pendente.

Os checkouts oficiais `firmware/marlin` e `firmware/configurations` estão fixados no mesmo commit da branch `bugfix-2.1.x`. Essa combinação contém `config/examples/Creality/Ender-3 Neo` e o ambiente GD32 MFL.

A placa identificada é Creality V4.2.2 com MCU `GD32F303RET6`. A configuração oficial Ender-3 Neo foi copiada ao Marlin e recebeu somente estes diffs:

- `MOTHERBOARD`: `BOARD_CREALITY_V422` → `BOARD_CREALITY_V422_GD32_MFL`;
- `SERIAL_PORT`: `1` → `0` (a HAL GD32 enumera o mesmo CH340 em UART0, PA9/PA10);
- `CUSTOM_MACHINE_NAME` → `"NeoCNC LAB"`;
- `MARLIN_SNAKE` habilitado.

Nenhuma mudança foi feita em limites, PID, steps/mm, termistores, probe, drivers, correntes ou pinos.

Após o primeiro flash, a EEPROM foi reinicializada por incompatibilidade de versão. Os defaults e a EEPROM foram então reconciliados com `docs/original/M503.txt`; essa compatibilidade é parte do NeoCNC 0.0.2.
