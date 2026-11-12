-- Mundo: colunas (chunks) de 16x16xH em arrays ffi de bytes, alterações do
-- jogador, gravação/carregamento. A geração fica em gen.lua (roda também no
-- worker de malha); aqui só guardamos os dados e as seções visuais.

local ffi = require("ffi")
local B = require("blocks")
local WC = require("worldcfg")
local G = require("gen")

local W = {}

W.CS, W.H, W.SEC, W.NSEC, W.SEA = WC.CS, WC.H, WC.SEC, WC.NSEC, WC.SEA
local CS, H, CSH = WC.CS, WC.H, WC.CSH

W.chunks = {}          -- chave -> chunk
W.edits = {}           -- chave -> {[idx] = id}  (só o que o jogador mudou)
W.editCount = 0
W.dirtySave = false
W.seed = 1

local function key(cx, cz) return (cx + 32768) * 65536 + (cz + 32768) end
W.key = key

local floor = math.floor

function W.setSeed(seed)
  W.seed = seed
  G.setSeed(seed)
end

function W.height(x, z) return G.height(x, z) end

-- ---------------------------------------------------------------- chunks

function W.getChunk(cx, cz) return W.chunks[key(cx, cz)] end

local function newSections()
  local s = {}
  for i = 0, W.NSEC - 1 do s[i] = {dirty = true, version = 0} end
  return s
end

local function invalidate()
  W.lastKey, W.lastChunk = nil, nil
end

-- adota os bytes gerados (ByteData) como um chunk; aplica as edições do jogador
function W.adopt(cx, cz, bd, maxY)
  local k = key(cx, cz)
  if W.chunks[k] then return W.chunks[k] end
  local data = ffi.cast("uint8_t*", bd:getFFIPointer())
  local ed = W.edits[k]
  if ed then for i, id in pairs(ed) do data[i] = id end end
  local c = {cx = cx, cz = cz, data = data, bd = bd, sections = newSections()}
  -- seções acima do bloco mais alto não têm geometria: nem entram na fila
  if maxY then
    for i = 0, W.NSEC - 1 do
      if i * W.SEC > maxY then c.sections[i].empty = true; c.sections[i].dirty = false end
    end
  end
  W.chunks[k] = c
  invalidate()
  -- o vizinho precisa refazer a borda quando este chunk nasce
  for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
    local n = W.chunks[key(cx + d[1], cz + d[2])]
    if n then
      for i = 0, W.NSEC - 1 do
        n.sections[i].dirty = true
        n.sections[i].version = n.sections[i].version + 1
      end
    end
  end
  return c
end

function W.generate(cx, cz)
  local c = W.getChunk(cx, cz)
  if c then return c end
  local bd, maxY = G.generate(cx, cz)
  return W.adopt(cx, cz, bd, maxY)
end

-- liberar malha pode travar o driver por dezenas de ms; espalha ao longo dos quadros
W.garbage = {}
function W.dropMesh(m)
  if m then W.garbage[#W.garbage + 1] = m end
end

function W.collect(n)
  for _ = 1, (n or 2) do
    local m = table.remove(W.garbage)
    if not m then break end
    m:release()
  end
end

function W.unload(c)
  for i = 0, W.NSEC - 1 do
    local s = c.sections[i]
    W.dropMesh(s.mesh)
    W.dropMesh(s.tmesh)
  end
  W.chunks[key(c.cx, c.cz)] = nil
  invalidate()
end

-- ---------------------------------------------------------------- acesso

function W.get(x, y, z)
  if y < 0 then return B.BEDROCK end
  if y >= H then return B.AIR end
  local cx, cz = floor(x / CS), floor(z / CS)
  local k = key(cx, cz)
  local c
  if k == W.lastKey then c = W.lastChunk else
    c = W.chunks[k]
    W.lastKey, W.lastChunk = k, c
  end
  if not c then return -1 end
  return c.data[(x - cx * CS) + (z - cz * CS) * CS + y * CSH]
end

function W.isSolid(x, y, z)
  local id = W.get(x, y, z)
  if id < 0 then return true end -- chunk ausente: trata como parede
  return B.solid[id]
end

function W.isLoaded(cx, cz) return W.chunks[key(cx, cz)] ~= nil end

-- urgente: refeita na hora (bloco editado). Não urgente: o streaming refaz
-- dentro do orçamento do quadro (bordas entre chunks).
local function markDirty(cx, cz, sec, urgent)
  local c = W.chunks[key(cx, cz)]
  if c and c.sections[sec] then
    local s = c.sections[sec]
    s.dirty = true
    s.version = s.version + 1
    if urgent then s.urgent = true end
  end
end

function W.set(x, y, z, id)
  if y < 0 or y >= H then return false end
  local cx, cz = floor(x / CS), floor(z / CS)
  local c = W.chunks[key(cx, cz)]
  if not c then return false end
  local lx, lz = x - cx * CS, z - cz * CS
  local i = lx + lz * CS + y * CSH
  c.data[i] = id
  local k = key(cx, cz)
  local ed = W.edits[k]
  if not ed then ed = {}; W.edits[k] = ed end
  if ed[i] == nil then W.editCount = W.editCount + 1 end
  ed[i] = id
  W.dirtySave = true
  invalidate()
  local sec = floor(y / W.SEC)
  c.sections[sec].empty = false
  markDirty(cx, cz, sec, true)
  local ly = y - sec * W.SEC
  if ly == 0 and sec > 0 then markDirty(cx, cz, sec - 1) end
  if ly == W.SEC - 1 and sec < W.NSEC - 1 then markDirty(cx, cz, sec + 1) end
  if lx == 0 then markDirty(cx - 1, cz, sec) end
  if lx == CS - 1 then markDirty(cx + 1, cz, sec) end
  if lz == 0 then markDirty(cx, cz - 1, sec) end
  if lz == CS - 1 then markDirty(cx, cz + 1, sec) end
  return true
end

function W.topSolid(x, z)
  for y = H - 1, 0, -1 do
    local id = W.get(x, y, z)
    if id > 0 and B.solid[id] then return y end
  end
  return 0
end

function W.reset(seed)
  for _, c in pairs(W.chunks) do W.unload(c) end
  W.chunks, W.edits, W.editCount = {}, {}, 0
  invalidate()
  W.setSeed(seed)
end

-- ---------------------------------------------------------------- gravação

local SAVE = "mundo.txt"
W.SAVE = SAVE

-- state: {x, y, z, yaw, pitch, time, slot}
function W.save(state)
  local out = {"CAMADAZERO 1", "seed " .. W.seed,
    string.format("player %.3f %.3f %.3f %.4f %.4f", state.x, state.y, state.z, state.yaw, state.pitch),
    string.format("time %.5f", state.time), "slot " .. state.slot, "edits"}
  for k, ed in pairs(W.edits) do
    local cx, cz = floor(k / 65536) - 32768, k % 65536 - 32768
    local parts = {}
    for i, id in pairs(ed) do parts[#parts + 1] = i .. ":" .. id end
    if #parts > 0 then out[#out + 1] = cx .. " " .. cz .. " " .. table.concat(parts, ",") end
  end
  local text = table.concat(out, "\n") .. "\n"
  -- gravação em thread própria (tmp + rename); se ela não existir, cai no love.filesystem
  local ok, err
  if W.writer then
    ok = W.writer(SAVE, text)
  else
    ok, err = love.filesystem.write(SAVE .. ".tmp", text)
    if ok then
      local dir = love.filesystem.getSaveDirectory()
      if not os.rename(dir .. "/" .. SAVE .. ".tmp", dir .. "/" .. SAVE) then
        love.filesystem.write(SAVE, text)
      end
    end
  end
  if not ok then return false, err end
  W.dirtySave = false
  return true
end

function W.hasSave()
  return love.filesystem.getInfo(SAVE) ~= nil
end

function W.load()
  local text = love.filesystem.read(SAVE)
  if not text then return nil end
  local state = {}
  local inEdits = false
  local seed
  local edits, count = {}, 0
  for line in text:gmatch("[^\n]+") do
    if inEdits then
      local cx, cz, rest = line:match("^(%-?%d+) (%-?%d+) (.*)$")
      if cx then
        local k = key(tonumber(cx), tonumber(cz))
        local ed = {}
        for i, id in rest:gmatch("(%d+):(%d+)") do ed[tonumber(i)] = tonumber(id); count = count + 1 end
        edits[k] = ed
      end
    else
      local k, v = line:match("^(%a+) ?(.*)$")
      if k == "seed" then seed = tonumber(v)
      elseif k == "player" then
        local x, y, z, yaw, pitch = v:match("(%S+) (%S+) (%S+) (%S+) (%S+)")
        state.x, state.y, state.z = tonumber(x), tonumber(y), tonumber(z)
        state.yaw, state.pitch = tonumber(yaw), tonumber(pitch)
      elseif k == "time" then state.time = tonumber(v)
      elseif k == "slot" then state.slot = tonumber(v)
      elseif k == "edits" then inEdits = true end
    end
  end
  if not seed then return nil end
  W.reset(seed)
  W.edits, W.editCount = edits, count
  W.dirtySave = false
  return state
end

return W
