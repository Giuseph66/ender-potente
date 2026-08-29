# Inventário físico — obrigatório antes do flash

Preencher com a Ender ainda no firmware original.

| Item | Valor | Evidência |
| --- | --- | --- |
| Modelo | Ender-3 Neo | `M115` |
| Mainboard | Creality V4.2.2 | foto fornecida pelo usuário |
| MCU | GD32F303RET6 (leitura visual) | foto fornecida pelo usuário |
| Display |  | foto/conector |
| Versão do firmware | Creality 2.0.8.2 (03/02/2023) | `docs/original/M115.txt` |
| Configuração EEPROM | registrada | `docs/original/M503.txt` |
| Porta serial / baudrate | `/dev/ttyUSB0` / 115200 | `docs/original/serial-info.txt` |

Não selecionar ambiente PlatformIO, placa Marlin, ou método de flash até identificar mainboard e MCU.
