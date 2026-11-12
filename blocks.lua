-- Tipos de bloco e atlas de texturas gerado por código (nada vem de arquivo).
-- Cada bloco aponta para azulejos (tiles) do atlas: topo, lados e base.

local B = {}

B.AIR, B.GRASS, B.DIRT, B.STONE, B.SAND, B.LOG, B.LEAVES, B.GLASS,
B.PLANKS, B.BRICK, B.LAMP, B.WATER, B.BEDROCK = 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12

-- tiles: {topo, lado, base}; kind: "solid" | "glass" | "water"
B.defs = {
  [1]  = {name = "Relva",   tiles = {0, 1, 2}},
  [2]  = {name = "Terra",   tiles = {2, 2, 2}},
  [3]  = {name = "Pedra",   tiles = {3, 3, 3}},
  [4]  = {name = "Areia",   tiles = {4, 4, 4}},
  [5]  = {name = "Tronco",  tiles = {6, 5, 6}},
  [6]  = {name = "Folhas",  tiles = {7, 7, 7}},
  [7]  = {name = "Vidro",   tiles = {8, 8, 8}, kind = "glass"},
  [8]  = {name = "Tábuas",  tiles = {9, 9, 9}},
  [9]  = {name = "Tijolo",  tiles = {10, 10, 10}},
  [10] = {name = "Lâmpada", tiles = {11, 11, 11}, emissive = true},
  [11] = {name = "Água",    tiles = {12, 12, 12}, kind = "water"},
  [12] = {name = "Base",    tiles = {13, 13, 13}, unbreakable = true},
}
B.COUNT = 12

B.hotbar = {1, 2, 3, 4, 5, 8, 9, 7, 6, 10}

-- tabelas rápidas indexadas por id (0..255), usadas pelo gerador de malha
B.opaque, B.solid, B.trans, B.emit = {}, {}, {}, {}
for id = 0, 255 do
  local d = B.defs[id]
  B.opaque[id] = d ~= nil and d.kind == nil           -- esconde faces vizinhas e faz sombra (AO)
  B.solid[id] = d ~= nil and d.kind ~= "water"         -- colide e pode ser mirado
  B.trans[id] = d ~= nil and d.kind ~= nil             -- vai para a passada transparente
  B.emit[id] = d ~= nil and d.emissive or false
end

B.TILE = 16      -- pixels por tile
B.COLS = 8       -- tiles por linha do atlas
B.ROWS = 2

-- ---------------------------------------------------------------- texturas

local function hash(x, y, s)
  local n = math.sin(x * 127.1 + y * 311.7 + s * 74.7) * 43758.5453
  return n - math.floor(n)
end

local function clamp01(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

-- cada função recebe (x, y) do pixel dentro do tile (0..15) e devolve r, g, b, a
local painters = {}

painters[0] = function(x, y) -- relva, topo: musgo escuro azul-esverdeado com pontos ferrugem
  local n = hash(x, y, 1)
  local v = 0.80 + n * 0.30
  if hash(x, y, 9) > 0.93 then return 0.55 * v, 0.24 * v, 0.18 * v, 1 end
  return 0.20 * v, 0.36 * v, 0.30 * v, 1
end

painters[2] = function(x, y) -- terra: marrom arroxeado com grãos
  local n = hash(x, y, 2)
  local v = 0.78 + n * 0.32
  if hash(x, y, 12) > 0.90 then v = v * 0.7 end
  return 0.36 * v, 0.25 * v, 0.22 * v, 1
end

painters[1] = function(x, y) -- relva, lado: terra com franja de musgo irregular
  local edge = 3 + math.floor(hash(x, 0, 3) * 3)
  if y < edge then return painters[0](x, y) end
  return painters[2](x, y)
end

painters[3] = function(x, y) -- pedra: cinza frio com fissuras diagonais
  local n = hash(x, y, 4)
  local v = 0.82 + n * 0.22
  local crack = ((x + y * 2) % 11 == 0 and hash(x, y, 5) > 0.35) or ((x * 3 - y) % 13 == 0 and hash(x, y, 6) > 0.5)
  if crack then v = v * 0.62 end
  return 0.40 * v, 0.41 * v, 0.45 * v, 1
end

painters[4] = function(x, y) -- areia: bege pálido com ondulação
  local n = hash(x, y, 7)
  local wave = math.sin((x + y * 0.5) * 0.9) * 0.04
  local v = 0.90 + n * 0.12 + wave
  return 0.78 * v, 0.70 * v, 0.56 * v, 1
end

painters[5] = function(x, y) -- tronco, lado: casca em faixas verticais
  local stripe = (x % 4 == 0) and 0.72 or 1
  local n = hash(x, math.floor(y / 3), 8)
  local v = (0.80 + n * 0.25) * stripe
  return 0.30 * v, 0.22 * v, 0.20 * v, 1
end

painters[6] = function(x, y) -- tronco, topo: anéis
  local dx, dy = x - 7.5, y - 7.5
  local r = math.sqrt(dx * dx + dy * dy)
  if r > 7 then return painters[5](x, y) end
  local ring = (math.floor(r) % 2 == 0) and 0.86 or 1
  local v = ring * (0.92 + hash(x, y, 10) * 0.1)
  return 0.62 * v, 0.48 * v, 0.38 * v, 1
end

painters[7] = function(x, y) -- folhas: carmim escuro, manchas
  local n = hash(x, y, 11)
  local m = hash(math.floor(x / 2), math.floor(y / 2), 13)
  local v = 0.62 + n * 0.25 + m * 0.25
  if n > 0.88 then v = v * 0.45 end
  return 0.62 * v, 0.12 * v, 0.16 * v, 1
end

painters[8] = function(x, y) -- vidro: moldura fina, centro vazio, um reflexo
  if x == 0 or y == 0 or x == 15 or y == 15 then return 0.80, 0.84, 0.88, 1 end
  if x + y == 12 or x + y == 13 then return 0.90, 0.92, 0.95, 0.55 end
  return 0, 0, 0, 0
end

painters[9] = function(x, y) -- tábuas: placas horizontais com pregos
  local board = math.floor(y / 4)
  local base = 0.85 + hash(board, 0, 14) * 0.2
  local v = base * (0.92 + hash(x, y, 15) * 0.1)
  if y % 4 == 3 then v = v * 0.6 end
  local joint = (board % 2 == 0) and 5 or 12
  if x == joint then v = v * 0.7 end
  return 0.54 * v, 0.38 * v, 0.28 * v, 1
end

painters[10] = function(x, y) -- tijolo: vermelho-vinho com argamassa escura
  local row = math.floor(y / 4)
  local off = (row % 2 == 0) and 0 or 4
  if y % 4 == 3 or (x + off) % 8 == 7 then return 0.20, 0.18, 0.20, 1 end
  local v = 0.82 + hash(x, y, 16) * 0.22
  return 0.52 * v, 0.14 * v, 0.14 * v, 1
end

painters[11] = function(x, y) -- lâmpada: núcleo claro com anel vermelho
  local dx, dy = x - 7.5, y - 7.5
  local r = math.sqrt(dx * dx + dy * dy)
  if x == 0 or y == 0 or x == 15 or y == 15 then return 0.25, 0.08, 0.10, 1 end
  if r < 4 then return 1.00, 0.95, 0.88, 1 end
  if r < 6 then return 0.95, 0.35, 0.32, 1 end
  return 0.80, 0.18, 0.20, 1
end

painters[12] = function(x, y) -- água: azul petróleo translúcido
  local w = math.sin(x * 0.8 + y * 0.35) * 0.06 + hash(x, y, 17) * 0.06
  return 0.12 + w, 0.26 + w, 0.36 + w, 0.72
end

painters[13] = function(x, y) -- base (indestrutível): quase preto com riscos vermelhos
  local n = hash(x, y, 18)
  if (x * 5 + y * 3) % 17 == 0 then return 0.40, 0.06, 0.08, 1 end
  local v = 0.10 + n * 0.08
  return v, v, v * 1.1, 1
end

function B.buildAtlas()
  local T = B.TILE
  local img = love.image.newImageData(T * B.COLS, T * B.ROWS)
  for tile = 0, B.COLS * B.ROWS - 1 do
    local p = painters[tile]
    local ox, oy = (tile % B.COLS) * T, math.floor(tile / B.COLS) * T
    for y = 0, T - 1 do
      for x = 0, T - 1 do
        local r, g, b, a = 1, 0, 1, 1
        if p then r, g, b, a = p(x, y) end
        img:setPixel(ox + x, oy + y, clamp01(r), clamp01(g), clamp01(b), clamp01(a))
      end
    end
  end
  B.atlasData = img
  local atlas = love.graphics.newImage(img)
  atlas:setFilter("nearest", "nearest")
  atlas:setWrap("clamp", "clamp")
  B.atlas = atlas
  -- quads 2D para ícones da barra de blocos
  B.quads = {}
  for tile = 0, B.COLS * B.ROWS - 1 do
    B.quads[tile] = love.graphics.newQuad((tile % B.COLS) * T, math.floor(tile / B.COLS) * T, T, T, img:getWidth(), img:getHeight())
  end
  return atlas
end

return B
