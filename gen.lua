-- Geração de terreno por ruído. Roda igual na thread principal e no worker.
-- generate() devolve um ByteData com CS*CS*H bytes (índice x + z*CS + y*CSH).

local math = require("math")
local ffi = require("ffi")
local B = require("blocks")
local WC = require("worldcfg")

local G = {}
local CS, H, SEA, CSH = WC.CS, WC.H, WC.SEA, WC.CSH
local floor = math.floor

local ox1, oz1, ox2, oz2, ox3, oz3, SEED = 0, 0, 0, 0, 0, 0, 1

function G.seed() return SEED end

function G.setSeed(seed)
  SEED = seed
  -- deslocamentos determinísticos a partir da seed (sem love.math: o worker
  -- não tem os módulos love.* além de thread/filesystem)
  ox1 = (seed * 37.13) % 4096
  oz1 = (seed * 91.77) % 4096
  ox2 = (seed * 13.91) % 4096
  oz2 = (seed * 57.31) % 4096
  ox3 = (seed * 71.53) % 4096
  oz3 = (seed * 29.97) % 4096
end

local function ihash(x, z, s)
  local n = math.sin(x * 12.9898 + z * 78.233 + (s % 10007) * 37.719) * 43758.5453
  return n - floor(n)
end

-- ruído de valor 2D suave, determinístico e sem love.math
local function vhash(ix, iz, s)
  local n = math.sin(ix * 127.1 + iz * 311.7 + s * 0.017) * 43758.5453
  return n - floor(n)
end

local function vnoise(x, z, s)
  local ix, iz = floor(x), floor(z)
  local fx, fz = x - ix, z - iz
  local u = fx * fx * (3 - 2 * fx)
  local v = fz * fz * (3 - 2 * fz)
  local a = vhash(ix, iz, s)
  local b = vhash(ix + 1, iz, s)
  local c = vhash(ix, iz + 1, s)
  local d = vhash(ix + 1, iz + 1, s)
  local ab = a + (b - a) * u
  local cd = c + (d - c) * u
  return ab + (cd - ab) * v
end

function G.height(x, z)
  local base = vnoise(x * 0.011 + ox1, z * 0.011 + oz1, SEED)
  local hills = vnoise(x * 0.038 + ox2, z * 0.038 + oz2, SEED + 101)
  local detail = vnoise(x * 0.13 + ox3, z * 0.13 + oz3, SEED + 202)
  local h = 7 + base * 20 + (hills - 0.5) * 7 * (0.35 + base) + (detail - 0.5) * 1.6
  h = floor(h)
  if h < 2 then h = 2 elseif h > H - 9 then h = H - 9 end
  return h
end

local function isTree(x, z, h)
  if h <= SEA + 1 or h > 33 then return false end
  return ihash(x, z, SEED) < 0.018
end

function G.treeAt(x, z)
  local h = G.height(x, z)
  return isTree(x, z, h)
end

-- devolve ByteData; quem chama guarda a referência (o ponteiro depende dela)
function G.generate(cx, cz)
  local bd = love.data.newByteData(CSH * H)
  local data = ffi.cast("uint8_t*", bd:getFFIPointer())
  local bx, bz = cx * CS, cz * CS
  local maxY = 0
  local heights = {}
  for lz = -2, CS + 1 do
    for lx = -2, CS + 1 do
      heights[(lz + 2) * (CS + 4) + (lx + 2)] = G.height(bx + lx, bz + lz)
    end
  end
  local function hAt(lx, lz) return heights[(lz + 2) * (CS + 4) + (lx + 2)] end

  for lz = 0, CS - 1 do
    for lx = 0, CS - 1 do
      local h = hAt(lx, lz)
      local beach = h <= SEA + 1
      local top, under
      if beach then top, under = B.SAND, B.SAND
      elseif h > 33 then top, under = B.STONE, B.STONE
      else top, under = B.GRASS, B.DIRT end
      if h > maxY then maxY = h end
      if SEA > maxY then maxY = SEA end
      local col = lx + lz * CS
      data[col] = B.BEDROCK
      for y = 1, h do
        local id
        if y == h then id = top
        elseif y >= h - 3 then id = under
        else id = B.STONE end
        data[col + y * CSH] = id
      end
      for y = h + 1, SEA do data[col + y * CSH] = B.WATER end
    end
  end

  for lz = -2, CS + 1 do
    for lx = -2, CS + 1 do
      local wx, wz = bx + lx, bz + lz
      local h = hAt(lx, lz)
      if isTree(wx, wz, h) then
        local th = 4 + floor(ihash(wx, wz, SEED + 7) * 2.99)
        local topY = h + th
        if topY + 1 > maxY then maxY = topY + 1 end
        for y = h + 1, topY do
          if lx >= 0 and lx < CS and lz >= 0 and lz < CS then
            data[lx + lz * CS + y * CSH] = B.LOG
          end
        end
        for y = topY - 2, topY + 1 do
          local r = (y >= topY) and 1 or 2
          for dz = -r, r do
            for dx = -r, r do
              local corner = math.abs(dx) == r and math.abs(dz) == r
              if not (corner and (r == 1 or ihash(wx + dx, wz + dz, y) < 0.6)) then
                local x, z = lx + dx, lz + dz
                if x >= 0 and x < CS and z >= 0 and z < CS and y < H then
                  local i = x + z * CS + y * CSH
                  if data[i] == B.AIR then data[i] = B.LEAVES end
                end
              end
            end
          end
        end
      end
    end
  end
  return bd, maxY
end

return G
