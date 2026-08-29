# NeoCNC

Base aberta e programável para a Creality Ender-3 Neo. Fase atual: `NeoCNC 0.0.2` instalado, com nome `NeoCNC LAB`, Snake no LCD original e recepção de atualizações por serial habilitada.

## Estado

As fontes oficiais Marlin e Configurations estão fixadas em `bugfix-2.1.x`: essa é a primeira linha que contém simultaneamente a configuração oficial **Ender-3 Neo** e suporte nativo à mainboard Creality V4.2.2 com MCU GD32F303RET6. O tag `2.1.2.7` foi preservado em `firmware/*-2.1.2.7-unsupported`, mas não suporta esse MCU.

`builds/NeoCNC-0.0.2.bin` foi instalado com sucesso na Ender. O firmware anuncia `BINARY_FILE_TRANSFER`, `CUSTOM_FIRMWARE_UPLOAD` e o sensor de fim de filamento; o cartão atual, porém, ainda precisa ser formatado/testado para permitir a gravação pelo Marlin e concluir atualização serial ponta a ponta.

Antes da configuração e do flash, registrar placa, MCU e firmware original em [`docs/hardware.md`](docs/hardware.md). Consulte [`configs/ender3-neo/README.md`](configs/ender3-neo/README.md) para o bloqueio de configuração e [`docs/flashing.md`](docs/flashing.md) para o fluxo seguro.

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
```
