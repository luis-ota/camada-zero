-- Jogador: física simples (gravidade, pulo, colisão AABB por eixo) e raycast DDA.

local B = require("blocks")
local W = require("world")

local P = {}

P.HW = 0.3          -- meia largura da caixa
P.HEIGHT = 1.75
P.EYE = 1.6
P.GRAVITY = 24
P.JUMP = 7.6
P.WALK = 4.3
P.RUN = 6.6
P.REACH = 5

local floor = math.floor

function P.new(x, y, z)
  return {x = x, y = y, z = z, vx = 0, vy = 0, vz = 0, yaw = 0, pitch = 0, onGround = false, inWater = false}
end

local function boxHits(x0, y0, z0, x1, y1, z1)
  for by = floor(y0), floor(y1) do
    for bz = floor(z0), floor(z1) do
      for bx = floor(x0), floor(x1) do
        if W.isSolid(bx, by, bz) then return true end
      end
    end
  end
  return false
end

function P.collides(p, x, y, z)
  local e = 1e-4
  return boxHits(x - P.HW + e, y + e, z - P.HW + e, x + P.HW - e, y + P.HEIGHT - e, z + P.HW - e)
end

local function moveAxis(p, axis, d)
  if d == 0 then return false end
  local step = 0.45
  local n = math.ceil(math.abs(d) / step)
  local s = d / n
  for _ = 1, n do
    local nx, ny, nz = p.x, p.y, p.z
    if axis == 1 then nx = nx + s elseif axis == 2 then ny = ny + s else nz = nz + s end
    if P.collides(p, nx, ny, nz) then
      -- encosta na face do bloco
      if axis == 1 then
        p.x = s > 0 and (floor(nx + P.HW) - P.HW - 1e-3) or (floor(nx - P.HW) + 1 + P.HW + 1e-3)
      elseif axis == 2 then
        p.y = s > 0 and (floor(ny + P.HEIGHT) - P.HEIGHT - 1e-3) or (floor(ny) + 1 + 1e-4)
      else
        p.z = s > 0 and (floor(nz + P.HW) - P.HW - 1e-3) or (floor(nz - P.HW) + 1 + P.HW + 1e-3)
      end
      if P.collides(p, p.x, p.y, p.z) then
        -- não conseguiu encostar: volta ao último ponto válido
        if axis == 1 then p.x = nx - s elseif axis == 2 then p.y = ny - s else p.z = nz - s end
      end
      return true
    end
    p.x, p.y, p.z = nx, ny, nz
  end
  return false
end

-- mx, mz: entrada de movimento local (-1..1); jump: botão segurado
function P.update(p, dt, mx, mz, jump, run)
  local id = W.get(floor(p.x), floor(p.y + 0.4), floor(p.z))
  p.inWater = id == B.WATER
  local eyeId = W.get(floor(p.x), floor(p.y + P.EYE), floor(p.z))
  p.eyeInWater = eyeId == B.WATER

  local speed = run and P.RUN or P.WALK
  if p.inWater then speed = speed * 0.55 end
  local sy, cy = math.sin(p.yaw), math.cos(p.yaw)
  -- frente = (sin yaw, -cos yaw), direita = (cos yaw, sin yaw)
  local wx = (sy * mz + cy * mx) * speed
  local wz = (-cy * mz + sy * mx) * speed
  -- aceleração suave
  local k = math.min(1, dt * (p.onGround and 14 or 5))
  p.vx = p.vx + (wx - p.vx) * k
  p.vz = p.vz + (wz - p.vz) * k

  if p.inWater then
    p.vy = p.vy - P.GRAVITY * 0.25 * dt
    if jump then p.vy = math.min(p.vy + 30 * dt, 3.2) end
    if p.vy < -3 then p.vy = -3 end
  else
    p.vy = p.vy - P.GRAVITY * dt
    if jump and p.onGround then p.vy = P.JUMP; p.jumped = true end
    if p.vy < -40 then p.vy = -40 end
  end

  moveAxis(p, 1, p.vx * dt)
  moveAxis(p, 3, p.vz * dt)
  local hit = moveAxis(p, 2, p.vy * dt)
  if hit then
    p.onGround = p.vy < 0
    p.vy = 0
  else
    p.onGround = P.collides(p, p.x, p.y - 0.02, p.z)
  end
  -- caiu do mundo (não deveria): volta para cima
  if p.y < -10 then p.y = W.H + 2; p.vy = 0 end
end

-- DDA a partir do olho; devolve bloco {x,y,z} e a célula vazia antes dele {x,y,z}
function P.raycast(p, dx, dy, dz)
  local ox, oy, oz = p.x, p.y + P.EYE, p.z
  local x, y, z = floor(ox), floor(oy), floor(oz)
  local stepX = dx > 0 and 1 or -1
  local stepY = dy > 0 and 1 or -1
  local stepZ = dz > 0 and 1 or -1
  local inf = math.huge
  local tdx = dx ~= 0 and math.abs(1 / dx) or inf
  local tdy = dy ~= 0 and math.abs(1 / dy) or inf
  local tdz = dz ~= 0 and math.abs(1 / dz) or inf
  local tmx = dx ~= 0 and ((dx > 0 and (x + 1 - ox) or (ox - x)) * tdx) or inf
  local tmy = dy ~= 0 and ((dy > 0 and (y + 1 - oy) or (oy - y)) * tdy) or inf
  local tmz = dz ~= 0 and ((dz > 0 and (z + 1 - oz) or (oz - z)) * tdz) or inf
  local px, py, pz = x, y, z
  local t = 0
  while t <= P.REACH do
    local id = W.get(x, y, z)
    if id > 0 and B.solid[id] then
      return {x, y, z}, {px, py, pz}
    end
    px, py, pz = x, y, z
    if tmx < tmy and tmx < tmz then
      x = x + stepX; t = tmx; tmx = tmx + tdx
    elseif tmy < tmz then
      y = y + stepY; t = tmy; tmy = tmy + tdy
    else
      z = z + stepZ; t = tmz; tmz = tmz + tdz
    end
  end
  return nil
end

function P.blockIntersects(p, bx, by, bz)
  return p.x + P.HW > bx and p.x - P.HW < bx + 1 and
         p.y + P.HEIGHT > by and p.y < by + 1 and
         p.z + P.HW > bz and p.z - P.HW < bz + 1
end

return P
