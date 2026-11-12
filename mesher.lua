-- Gera a malha de uma seção (16x16x16) a partir dos bytes do chunk e dos 8
-- vizinhos. Só faces expostas viram geometria; AO calculada por vértice.
-- Cada vértice ocupa 12 bytes (posição/escala 15, tile+canto, luz).
-- Pode rodar no worker (buildFrom) ou na thread principal (build).

local math = require("math")
local ffi = require("ffi")
local B = require("blocks")
local WC = require("worldcfg")

local M = {}

ffi.cdef [[
typedef struct { uint8_t x, y, z, w; uint8_t tx, ty, cu, cv; uint8_t r, g, b, a; } cz_vert;
]]

M.FORMAT = {
  {"VertexPosition", "byte", 4},
  {"VertexTexCoord", "byte", 4},
  {"VertexColor", "byte", 4},
}

local CS, SEC, H = WC.CS, WC.SEC, WC.H
local CSH = WC.CSH
local MAXF = 16000
local P = 18
local PP = P * P
local PSIZE = P * P * P

local opaque = ffi.new("uint8_t[256]")
local water = ffi.new("uint8_t[256]")
local glass = ffi.new("uint8_t[256]")
local emit = ffi.new("uint8_t[256]")
local tileOf = ffi.new("uint8_t[256][3]")
for id = 0, 255 do
  local d = B.defs[id]
  opaque[id] = B.opaque[id] and 1 or 0
  water[id] = (d and d.kind == "water") and 1 or 0
  glass[id] = (d and d.kind == "glass") and 1 or 0
  emit[id] = B.emit[id] and 1 or 0
  if d then
    tileOf[id][0], tileOf[id][1], tileOf[id][2] = d.tiles[1], d.tiles[2], d.tiles[3]
  end
end

local cache = ffi.new("uint8_t[?]", PSIZE)
local vbOpaque = ffi.new("cz_vert[?]", MAXF * 4)
local vbTrans = ffi.new("cz_vert[?]", MAXF * 4)
local stonePage = ffi.new("uint8_t[?]", CSH * H, B.STONE)  -- vizinho ausente: pedra

local idxAll = ffi.new("uint16_t[?]", MAXF * 6)
for f = 0, MAXF - 1 do
  local b, v = f * 6, f * 4
  idxAll[b], idxAll[b + 1], idxAll[b + 2] = v, v + 1, v + 2
  idxAll[b + 3], idxAll[b + 4], idxAll[b + 5] = v + 2, v + 3, v
end

-- u x v = n; vértices em sentido anti-horário vistos de fora
local FACES = {
  {n = {0, 1, 0},  u = {1, 0, 0},  v = {0, 0, -1}, shade = 1.00, tile = 0},
  {n = {0, -1, 0}, u = {1, 0, 0},  v = {0, 0, 1},  shade = 0.50, tile = 2},
  {n = {1, 0, 0},  u = {0, 0, -1}, v = {0, 1, 0},  shade = 0.80, tile = 1},
  {n = {-1, 0, 0}, u = {0, 0, 1},  v = {0, 1, 0},  shade = 0.80, tile = 1},
  {n = {0, 0, 1},  u = {1, 0, 0},  v = {0, 1, 0},  shade = 0.65, tile = 1},
  {n = {0, 0, -1}, u = {-1, 0, 0}, v = {0, 1, 0},  shade = 0.65, tile = 1},
}
local SU = {-1, 1, 1, -1}
local SV = {-1, -1, 1, 1}
local AO_LEVEL = {[0] = 0.50, 0.66, 0.83, 1.0}

local F = {}
for fi, f in ipairs(FACES) do
  local e = {noff = f.n[1] + f.n[3] * P + f.n[2] * PP, shade = f.shade, tile = f.tile, ny = f.n[2]}
  e.corner = {}
  for c = 1, 4 do
    local su, sv = SU[c], SV[c]
    local px = 0.5 + f.n[1] * 0.5 + su * f.u[1] * 0.5 + sv * f.v[1] * 0.5
    local py = 0.5 + f.n[2] * 0.5 + su * f.u[2] * 0.5 + sv * f.v[2] * 0.5
    local pz = 0.5 + f.n[3] * 0.5 + su * f.u[3] * 0.5 + sv * f.v[3] * 0.5
    e.corner[c] = {
      x = (px >= 1) and 1 or 0, y = (py >= 1) and 1 or 0, z = (pz >= 1) and 1 or 0,
      cu = (su + 1) / 2, cv = (1 - sv) / 2,
      s1 = su * (f.u[1] + f.u[3] * P + f.u[2] * PP),
      s2 = sv * (f.v[1] + f.v[3] * P + f.v[2] * PP),
    }
  end
  F[fi] = e
end

M.ao = true

-- nb: 9 ponteiros uint8_t* na ordem (dz+1)*3 + (dx+1) + 1
local function fillFrom(nb, sec)
  local y0 = sec * SEC
  for py = 0, P - 1 do
    local y = y0 + py - 1
    for pz = 0, P - 1 do
      local lz = pz - 1
      local dz = lz < 0 and -1 or (lz >= CS and 1 or 0)
      local lzz = lz - dz * CS
      local rowBase = (dz + 1) * 3 + 1
      for px = 0, P - 1 do
        local lx = px - 1
        local dx = lx < 0 and -1 or (lx >= CS and 1 or 0)
        local id
        if y < 0 then id = B.BEDROCK
        elseif y >= H then id = 0
        else
          local d = nb[rowBase + dx + 1] or stonePage
          id = d[(lx - dx * CS) + lzz * CS + y * CSH]
        end
        cache[px + pz * P + py * PP] = id
      end
    end
  end
end

local Lbuf = {1, 1, 1, 1}
local function emitFace(vb, nf, e, x, y, z, id, ci, useAO, waterTop)
  local base = nf * 4
  local t = tileOf[id][e.tile]
  local tx, ty = t % B.COLS, math.floor(t / B.COLS)
  local em = emit[id] == 1 and 255 or 0
  local nci = ci + e.noff
  local l = Lbuf
  for c = 1, 4 do
    local lv = 1
    if useAO then
      local s1 = opaque[cache[nci + e.corner[c].s1]]
      local s2 = opaque[cache[nci + e.corner[c].s2]]
      local cc = opaque[cache[nci + e.corner[c].s1 + e.corner[c].s2]]
      local a = (s1 == 1 and s2 == 1) and 0 or (3 - s1 - s2 - cc)
      lv = AO_LEVEL[a]
    end
    l[c] = lv
  end
  local start = (l[1] + l[3] < l[2] + l[4]) and 1 or 0
  for i = 0, 3 do
    local c = (i + start) % 4 + 1
    local k = e.corner[c]
    local v = vb[base + i]
    v.x = (x + k.x) * 15
    local yy = (y + k.y) * 15
    if waterTop and k.y == 1 then yy = yy - 2 end
    v.y = yy
    v.z = (z + k.z) * 15
    v.w = 0
    v.tx, v.ty, v.cu, v.cv = tx, ty, k.cu, k.cv
    v.r = math.floor(e.shade * l[c] * 255 + 0.5)
    v.g = em
    v.b = 0
    v.a = 255
  end
end

local function bytesFrom(vb, nf)
  if nf == 0 then return nil end
  local bd = love.data.newByteData(nf * 4 * 12)
  ffi.copy(bd:getFFIPointer(), vb, nf * 4 * 12)
  return bd
end

-- monta a partir de 9 buffers (ByteData com getFFIPointer)
function M.buildFrom(nbData, sec, useAO)
  local nb = {}
  for i = 1, 9 do
    nb[i] = nbData[i] and ffi.cast("uint8_t*", nbData[i]:getFFIPointer()) or nil
  end
  fillFrom(nb, sec)
  local no, nt = 0, 0
  for y = 0, SEC - 1 do
    for z = 0, CS - 1 do
      for x = 0, CS - 1 do
        local ci = (x + 1) + (z + 1) * P + (y + 1) * PP
        local id = cache[ci]
        if id ~= 0 then
          local isOp = opaque[id] == 1
          local isW = water[id] == 1
          for fi = 1, 6 do
            local e = F[fi]
            local n = cache[ci + e.noff]
            local draw
            if isOp then draw = opaque[n] == 0
            elseif isW then draw = n == 0
            else draw = (n ~= id) and opaque[n] == 0 end
            if draw then
              if isOp then
                if no < MAXF then emitFace(vbOpaque, no, e, x, y, z, id, ci, useAO, false); no = no + 1 end
              else
                if nt < MAXF then
                  emitFace(vbTrans, nt, e, x, y, z, id, ci, false, isW and cache[ci + PP] ~= id)
                  nt = nt + 1
                end
              end
            end
          end
        end
      end
    end
  end
  return bytesFrom(vbOpaque, no), no, bytesFrom(vbTrans, nt), nt
end

-- cria a malha na thread principal (precisa do atlas)
function M.makeMesh(vdata, nf, atlas)
  if nf == 0 or not vdata then return nil end
  local idata = love.data.newByteData(nf * 6 * 2)
  ffi.copy(idata:getFFIPointer(), idxAll, nf * 6 * 2)
  local mesh = love.graphics.newMesh(M.FORMAT, nf * 4, "triangles", "static")
  mesh:setVertices(vdata)
  mesh:setVertexMap(idata, "uint16")
  mesh:setTexture(atlas)
  idata:release()
  return mesh
end

-- caminho síncrono (fallback/teste): usa o próprio mundo
local function chunkData(cx, cz)
  local c = require("world").getChunk(cx, cz)
  return c and c.bd
end

function M.build(c, sec, atlas)
  local nb = {}
  local i = 1
  for dz = -1, 1 do
    for dx = -1, 1 do
      nb[i] = (dx == 0 and dz == 0) and c.bd or chunkData(c.cx + dx, c.cz + dz)
      i = i + 1
    end
  end
  local op, no, tr, nt = M.buildFrom(nb, sec, M.ao)
  local s = c.sections[sec]
  if s.mesh then s.mesh:release() end
  if s.tmesh then s.tmesh:release() end
  s.mesh = M.makeMesh(op, no, atlas)
  s.tmesh = M.makeMesh(tr, nt, atlas)
  s.faces = no + nt
  s.dirty, s.urgent = false, false
  return no + nt
end

return M
