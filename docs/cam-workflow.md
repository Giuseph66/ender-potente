# Fluxo de corte de PCB

Como uma placa sai do CAD e vira corte na NeoCNC.

```text
KiCad/EasyEDA → Gerber + Excellon → FlatCAM/pcb2gcode → .nc → NeoCNC Control → cartão → M23/M24
```

## Por que não SVG

SVG não carrega o que a fresagem precisa: qual camada é cobre, diâmetro de cada
furo e a geometria de aperture. Isolação de trilha é um *offset* do polígono de
cobre pelo raio da fresa — não é a linha central de um traço desenhado. O
importador de SVG existente (`DESENHO XY`) continua servindo para gravação e
corte mecânico; para placa, a entrada é G-code de CAM.

Formatos por operação:

| Arquivo | Origem | Operação |
| --- | --- | --- |
| Gerber RS-274X (`.gtl`/`.gbl`) | camada de cobre | isolação |
| Excellon (`.drl`/`.xln`) | furação | drill |
| Gerber de contorno (`.gko`, Edge.Cuts) | contorno | recorte |
| `.nc`/`.gcode` | saída do FlatCAM/pcb2gcode | é o que o app lê hoje |

## O que o app faz com o arquivo

`CORTE / CAM` importa `.nc`, `.gcode`, `.ngc`, `.tap` e normaliza:

- polegadas (`G20`) convertidas para milímetros;
- trechos relativos (`G91`) reescritos em coordenadas absolutas;
- arcos `G2`/`G3` preservados (o firmware tem `ARC_SUPPORT`) e achatados só
  para o preview e para o cálculo de limites;
- Z deslocado pelo valor de **ALTURA DA PLACA**.

Antes de permitir o envio ele recusa o que a máquina não executaria: XY
negativo, trabalho maior que a mesa, Z acima do curso e — o caso mais comum —
Z negativo.

### O deslocamento de Z

O CAM entrega o mergulho contado a partir da superfície do cobre, então
`G1 Z-0.1` significa "0,1 mm abaixo da superfície". O Marlin, com o endstop de
software mínimo ativo, recusa Z negativo. O campo **ALTURA DA PLACA** soma a
altura medida da placa sobre a mesa a todos os Z do arquivo, levando o plano de
corte para o valor real do eixo.

Medir: zerar o Z com a fresa encostando no cobre, ler o valor em `M114` e usar
esse número.

## Envio

O envio usa o protocolo binário do Marlin (`M28 B1` + BFT), o mesmo que o
`tools/upload_serial.py` usa para firmware. O arquivo é gravado no cartão e a
máquina executa dali com `M23`/`M24`, com progresso lido por `M27`.

Isso existe porque streaming linha a linha custa um round-trip serial por
segmento. Uma isolação de PCB tem milhares de segmentos curtos: o planner
esvazia entre os movimentos, a fresa para dentro do cobre a cada segmento e
marca a placa. Rodando do cartão a máquina lê no próprio ritmo, e o trabalho
sobrevive a uma desconexão USB ou ao PC suspender.

## Ferramenta

`SPINDLE_FEATURE` liga a microrretífica por `M3`/`M5` na saída FAN0 (PA0), que
pilota o relé. Não há PWM nesse pino (`FAN_SOFT_PWM_REQUIRED`), então `M3 S...`
é liga e desliga — a rotação é ajustada na própria retífica.

`SPINDLE_LASER_ACTIVE_STATE` é `HIGH`: o MOSFET conduz com o gate em nível
alto e o pino nasce em nível baixo, então a ferramenta fica desligada no boot.
**Confira isso com a retífica desconectada antes do primeiro uso.**

## Limitação conhecida

A máquina não troca ferramenta sozinha. Um arquivo com mais de uma ferramenta
gera aviso: separe isolação, furação e recorte em arquivos distintos e troque a
fresa entre eles.

## Planicidade

Cobre tem 35 µm e a profundidade de isolação fica entre 0,05 e 0,15 mm — menos
que o empeno típico da mesa. Sem compensação, metade da placa não corta e a
outra metade fresa fibra de vidro.

A compensação ainda não está implementada. O caminho é um mapa de altura da
*placa* (grade de `G30`, ou sonda de continuidade no cobre), guardado no app e
somado ao Z ponto a ponto na geração do arquivo. O `G29` do Marlin não serve:
ele mapeia a mesa, não a placa.
