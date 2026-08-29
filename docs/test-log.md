# Log de testes

| Data | Build / SHA-256 | Hardware identificado | Teste | Resultado | Observações |
| --- | --- | --- | --- | --- | --- |
| 2026-08-29 | `firmware-110538.bin` / `6aeeb4d9dc76305d05751072f5e400170bec0db35ef5a9837367cc0ab8df084f` | Creality V4.2.2 / GD32F303RET6 | PlatformIO `GD32F303RE_creality_mfl` | sucesso | Flash 188276/495616 bytes; binário 188700 bytes; Snake compilado |
| 2026-08-29 | `firmware-110538.bin` | Creality V4.2.2 / GD32F303RET6 | PlatformIO `GD32F303RE_creality_mfl_xfer` | sucesso | Requisitos BINARY_FILE_TRANSFER, CUSTOM_FIRMWARE_UPLOAD e M997 compilados |
| 2026-08-29 | `firmware-110538.bin` | Creality V4.2.2 / GD32F303RET6 | Flash microSD + `M115` em `/dev/ttyUSB0` | sucesso | `MACHINE_TYPE:NeoCNC LAB`; BINARY_FILE_TRANSFER=1; CUSTOM_FIRMWARE_UPLOAD=1 |
| 2026-08-29 | `NeoCNC-0.0.2.bin` / `865e45f5477d50794920ebe3c90e8a2e5a02f50be498a6f2aa512df42de2c540` | Creality V4.2.2 / GD32F303RET6 | PlatformIO `GD32F303RE_creality_mfl` | sucesso | Flash 188608/495616 bytes; binário 189032 bytes; valores originais e RUNOUT desativado na configuração padrão |
| 2026-08-29 | `NEOCNC02.BIN` | Creality V4.2.2 / GD32F303RET6 | Flash microSD + `M115` e `M503` em `/dev/ttyUSB0` | sucesso | Build `11:22:52`; BINARY_FILE_TRANSFER=1; CUSTOM_FIRMWARE_UPLOAD=1; RUNOUT=1; parâmetros originais preservados; sem malha ABL |
| 2026-08-29 | `NeoCNC-0.0.2.bin` | Creality V4.2.2 / GD32F303RET6 | Escrita de teste e Binary File Transfer | bloqueado pelo cartão | `M21`=SD card ok, mas `M28 TEST.GCO` e abertura BFT falharam; o cartão é gravável pelo computador e precisa ser formatado/testado para atualização serial |
