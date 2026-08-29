# Flashing NeoCNC 0.0.2

Status: NeoCNC 0.0.2 instalado com sucesso. Usar somente ambiente `GD32F303RE_creality_mfl`; não usar `STM32F103RE_creality`.

1. Com firmware original, salvar `M115`, `M503`, dados da serial e fotos em `docs/original/`.
2. Guardar firmware original funcional para rollback.
3. Usar `builds/NeoCNC-0.0.2.bin`; SHA-256 em `builds/NeoCNC-0.0.2.sha256`.
4. Copiar para a raiz de microSD FAT32 e nomear `NEOCNC02.BIN`. Remover ou renomear qualquer outro `.BIN` da raiz.
5. Desligar a Ender, inserir microSD e ligar para o bootloader instalar.
6. Validar nome `NeoCNC LAB`, menu `Games → Snake`, giro do encoder e clique para sair.

Após a primeira instalação, NeoCNC recebe atualização por serial quando o microSD também aceitar escrita pelo Marlin; consulte `docs/serial-update.md`.
