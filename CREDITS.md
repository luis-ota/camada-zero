# Pesquisa e créditos

Este jogo foi escrito do zero. Nenhuma linha de código, textura, som ou nome de
outro projeto entrou no build; a pesquisa abaixo serviu para escolher o caminho
técnico (e para decidir o que **não** usar).

## Projetos avaliados

| Projeto | Licença | LÖVE | 3D/GLES 2 | GPU fraca | Assets de Minecraft? | Decisão |
|---|---|---|---|---|---|---|
| [groverburger/g3d](https://github.com/groverburger/g3d) | MIT | 11.x | shader `g3d.vert` com matrizes, mesh 3D; compatível com GLSL ES | sim, leve | não (só OBJ/PNG de exemplo) | estudado para convenções de matriz/shader; não copiado |
| [groverburger/g3d_voxel](https://github.com/groverburger/g3d_voxel) | MIT | 11.x | sim; remesh por chunk em thread, FFI + ByteData | sim | não (tem um `texturepack.png` próprio) | estudado o conceito de remesh/ffi; a malha, o worker e o atlas deste jogo são próprios |
| [groverburger/lovecraft](https://github.com/groverburger/lovecraft) | MIT | 11.2 | engine própria + cpml | não medido | **sim** — `assets/terrain.png`, `gui.png`, `items.png` são texturas do Minecraft (terrain.png traz TNT, plantinhas etc.; conferido visualmente) | descartado: mesmo com licença MIT, os assets são do Minecraft e o README do próprio autor diz que o código é antigo |
| [Keyslam/Lovox](https://github.com/Keyslam/Lovox) | sem licença | ? | módulos de voxel | ? | ? | descartado por falta de licença |
| [3dreamengine/3DreamEngine](https://github.com/3dreamengine/3DreamEngine) | MIT | 11.x | PBR, pesado para GLES 2/1 GB | não | não | descartado por peso/complexidade para o Mali-G31 |
| [Vulpovile/Blocks3D](https://github.com/Vulpovile/Blocks3D) | GPL-2.0 | ? | g3d | ? | ? | não usado (GPL e escopo diferente) |

Observação sobre o `g3d_voxel`: ele usa `love.thread` com passagem de ByteData e
um vertex struct de 20 bytes; a ideia foi útil, mas a implementação deste jogo
é independente (12 bytes/vértice, AO por vértice, fila urgente para edições,
geração no worker, atlas 16×16 pintado em Lua).

## O que foi realmente reaproveitado

- Nada de código. As dependências são apenas LÖVE 11.5 e o runtime do
  PortMaster (`love.aarch64` + `libs.aarch64`), já instalados no aparelho.
- O padrão de launcher (`camadazero-console.sh` / `CamadaZero.sh`) segue o
  formato do `experimentos/voxel/voxel-console.sh` deste mesmo repositório,
  incluindo a trava `/tmp/r36s-console.lock`.

## Assets

- Texturas: geradas pixel a pixel em `blocks.lua` (`buildAtlas`) no `load`.
- Sons: sintetizados em `sfx.lua` (ruído filtrado, seno e onda quadrada).
- Nenhum arquivo de imagem, áudio, fonte ou modelo externo.

## Licença do jogo

MIT, Copyright (c) 2026 Luis — ver `LICENSE` nesta pasta (o mesmo texto do
`LICENSE` da raiz do repositório).
