# NeoCNC

Base aberta e programável para a Creality Ender-3 Neo, convertida para fresagem de PCB. Fase atual: `NeoCNC 0.0.4` compilado, com controle de ferramenta por `M3`/`M5`, serial a 250000 baud e envio de trabalhos para o cartão pelo app.

## Estado

As fontes oficiais Marlin e Configurations estão fixadas em `bugfix-2.1.x`: essa é a primeira linha que contém simultaneamente a configuração oficial **Ender-3 Neo** e suporte nativo à mainboard Creality V4.2.2 com MCU GD32F303RET6. O tag `2.1.2.7` foi preservado em `firmware/*-2.1.2.7-unsupported`, mas não suporta esse MCU.

`builds/NeoCNC-0.0.4.bin` está compilado e pendente de instalação (RAM 19,9%, flash 27,8%). Ele mantém `BINARY_FILE_TRANSFER` e acrescenta o que faltava para cortar: buffers dimensionados para streaming de CNC, `EMERGENCY_PARSER` para que `M112` não fique preso na fila e `SPINDLE_FEATURE` na saída FAN0.

O cartão atual ainda precisa ser formatado/testado para aceitar escrita pelo Marlin: no primeiro flash `M21` reportou sucesso mas `M28 TEST.GCO` falhou. Sem isso, nem a atualização por serial nem o envio de trabalhos funcionam.

Antes da configuração e do flash, registrar placa, MCU e firmware original em [`docs/hardware.md`](docs/hardware.md). Consulte [`configs/ender3-neo/README.md`](configs/ender3-neo/README.md) para o bloqueio de configuração, [`docs/flashing.md`](docs/flashing.md) para o fluxo seguro e [`docs/cam-workflow.md`](docs/cam-workflow.md) para o caminho de uma placa até o corte.

## Fontes fixadas

| Fonte | Tag | Commit |
| --- | --- | --- |
| `firmware/marlin` | `bugfix-2.1.x` | `171ee00a6b30136b6b6e3723b163d45f88042b8f` |
| `firmware/configurations` | `bugfix-2.1.x` | `dbb0c2137cbdea1f76c623d4dffb62faf5eef3d3` |

## Layout

```text
firmware/          fontes oficiais fixadas
configs/           configuração aprovada por modelo
builds/            binários gerados (não versionar)
docs/original/     backup M115, M503, fotos e dados de placa
esp32/             reservado para NeoBridge futuro
app/neocnc_control/ desk de controle em Flutter
```

## Segurança

`SPINDLE_LASER_ACTIVE_STATE` é `HIGH` para casar com o MOSFET da saída FAN0, de
modo que o pino em nível baixo no boot mantém a ferramenta desligada. Verifique
esse comportamento com a retífica desconectada antes do primeiro uso.

Até o flash de `0.0.4`, `EMERGENCY_PARSER` está desabilitado no firmware
instalado: o `M112` do app entra na fila de comandos e não interrompe a máquina
na hora. Mantenha uma chave física cortando a alimentação da retífica.
