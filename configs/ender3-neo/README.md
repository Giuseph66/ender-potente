# Configuração Ender-3 Neo

Status: configurada; compilação pendente.

Os checkouts oficiais `firmware/marlin` e `firmware/configurations` estão fixados no mesmo commit da branch `bugfix-2.1.x`. Essa combinação contém `config/examples/Creality/Ender-3 Neo` e o ambiente GD32 MFL.

A placa identificada é Creality V4.2.2 com MCU `GD32F303RET6`. A configuração oficial Ender-3 Neo foi copiada ao Marlin e recebeu somente estes diffs:

- `MOTHERBOARD`: `BOARD_CREALITY_V422` → `BOARD_CREALITY_V422_GD32_MFL`;
- `SERIAL_PORT`: `1` → `0` (a HAL GD32 enumera o mesmo CH340 em UART0, PA9/PA10);
- `CUSTOM_MACHINE_NAME` → `"NeoCNC LAB"`;
- `MARLIN_SNAKE` habilitado.

Nenhuma mudança foi feita em limites, steps/mm, probe, drivers ou correntes.

## Diffs de `NeoCNC 0.0.4`

Voltados a executar corte, não impressão:

| Define | Antes | Depois | Motivo |
| --- | --- | --- | --- |
| `BAUDRATE` | 115200 | 115200 | CH340 da Ender-3 original: comunicação estável |
| `BUFSIZE` | 4 | 8 | 4 slots esvaziam entre segmentos curtos |
| `TX_BUFFER_SIZE` | 0 | 128 | exigido por `ADVANCED_OK` |
| `RX_BUFFER_SIZE` | — | 1024 | evita perda de bytes no streaming |
| `ADVANCED_OK` | off | on | o `ok` passa a informar espaço na fila |
| `EMERGENCY_PARSER` | off | on | `M112`/`M410` deixam de esperar a fila |
| `SPINDLE_FEATURE` | off | on | `M3`/`M5` para a microrretífica |
| `SPINDLE_LASER_ACTIVE_STATE` | `LOW` | `HIGH` | o MOSFET da FAN0 conduz em nível alto |
| `SPINDLE_LASER_USE_PWM` | on | off | PA0 é soft PWM; o relé é liga/desliga |
| `FAN0_PIN` | `PA0` | `-1` | libera PA0 para a ferramenta |
| `SPINDLE_LASER_ENA_PIN` | — | `PA0` | saída FAN0 da V4.2.2 |

O app inicia em 115200 para esta Ender-3; o seletor de velocidade continua
disponível para outras máquinas.

Após o primeiro flash, a EEPROM foi reinicializada por incompatibilidade de versão. Os defaults e a EEPROM foram então reconciliados com `docs/original/M503.txt`; essa compatibilidade é parte do NeoCNC 0.0.2.
