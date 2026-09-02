# Atualização por USB serial

Disponível somente **depois** da primeira instalação via microSD. O firmware recebe o binário pelo CH340, grava-o no microSD inserido e executa `M997` para reiniciar no bootloader.

Pré-condições:

1. NeoCNC já inicializado e microSD inserido na Ender.
2. Sem impressão, aquecimento ou movimento em curso.
3. `M115` informa `Cap:BINARY_FILE_TRANSFER:1` e `Cap:CUSTOM_FIRMWARE_UPLOAD:1`.
4. O cartão aceita escrita pelo Marlin. No cartão usado no primeiro flash, `M21` informou sucesso mas `M28 TEST.GCO` falhou; formatar FAT32 ou trocar o cartão antes de usar este fluxo.

Para uma versão posterior:

```sh
cd firmware/marlin
pio run -e GD32F303RE_creality_mfl
cd ../..
python3 tools/upload_serial.py firmware/marlin/.pio/build/GD32F303RE_creality_mfl/firmware-<hora>.bin --port /dev/ttyUSB0
```

`.pio/libdeps` pode estar com arquivos de root de uma execução anterior; nesse
caso aponte os diretórios de build para fora da árvore:

```sh
PLATFORMIO_LIBDEPS_DIR=/tmp/pio-libdeps PLATFORMIO_BUILD_DIR=/tmp/pio-build \
  pio run -e GD32F303RE_creality_mfl
```

## Velocidade da serial

`NeoCNC 0.0.4` subiu `BAUDRATE` para 250000. O launcher conversa com o firmware
**instalado**, não com o que está sendo enviado, então a atualização que instala
`0.0.4` por cima de uma versão anterior precisa de `--baud 115200`:

```sh
python3 tools/upload_serial.py builds/NeoCNC-0.0.4.bin --port /dev/ttyUSB0 --baud 115200
```

Depois disso, o padrão (`250000`) é o correto.

O launcher remove `.bin` antigos da raiz do cartão, transfere o novo binário por serial e dispara `M997`. Não desligar a máquina durante transferência/atualização. Se o launcher acusar falha de abertura no cliente, ele volta ao modo serial normal e não atualiza o firmware.
