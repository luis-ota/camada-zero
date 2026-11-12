-- Desenho 3D: shader GLSL ES simples, matrizes, céu, névoa, recorte por frustum
-- e contorno do bloco mirado. As posições chegam ao shader relativas à câmera
-- (u_off = origem da seção - câmera), o que mantém a precisão longe da origem.

local B = require("blocks")
local W = require("world")

local R = {}

local VS = [[
uniform mat4 u_vp;
uniform vec3 u_off;
uniform float u_fogNear;
uniform float u_fogFar;
uniform float u_day;
uniform float u_hand;
uniform float u_flip;
uniform vec2 u_tile;
varying float v_fog;
vec4 position(mat4 tp, vec4 vp) {
  vec3 p = vp.xyz * 17.0 + u_off;
  float d = length(p);
  v_fog = clamp((d - u_fogNear) / (u_fogFar - u_fogNear), 0.0, 1.0);
  vec4 t = VertexTexCoord * 255.0;
  VaryingTexCoord = vec4((t.xy + mix(vec2(0.004), vec2(0.996), t.zw)) * u_tile, 0.0, 0.0);
  float shade = VertexColor.r;
  float lamp = u_hand * clamp(1.0 - d / 8.0, 0.0, 1.0);
  float l = max(shade * (u_day + lamp), VertexColor.g);
  VaryingColor = vec4(l, l, l, 1.0);
  vec4 c = u_vp * vec4(p, 1.0);
  c.y *= u_flip;
  return c;
}
]]

local FS = [[
uniform vec3 u_fog;
varying float v_fog;
vec4 effect(vec4 col, Image tex, vec2 uv, vec2 sc) {
  vec4 t = Texel(tex, uv);
#ifdef CUTOUT
  if (t.a < 0.05) discard;
#endif
  return vec4(mix(t.rgb * col.rgb, u_fog, v_fog), t.a);
}
]]

R.fov = math.rad(70)
R.near = 0.06
R.radius = 3            -- raio de visão em chunks
R.scale = 1.0           -- escala da resolução interna (1 = 640x480)
R.stats = {sections = 0, faces = 0, draws = 0}

local W_, H_ = 640, 480
local canvas

function R.init(atlas)
  R.atlas = atlas
  R.shader = love.graphics.newShader(FS, VS)
  R.tshader = love.graphics.newShader("#define CUTOUT\n" .. FS, VS)
  for _, s in ipairs({R.shader, R.tshader}) do
    s:send("u_tile", {1 / B.COLS, 1 / B.ROWS})
  end
  -- gradiente do céu: 4 vértices, cores mudam por quadro
  R.skyMesh = love.graphics.newMesh({{0, 0, 0, 0, 1, 1, 1, 1}, {W_, 0, 0, 0, 1, 1, 1, 1},
    {W_, H_, 0, 0, 1, 1, 1, 1}, {0, H_, 0, 0, 1, 1, 1, 1}}, "fan", "dynamic")
  local rng = love.math.newRandomGenerator(4242)
  R.stars = {}
  for i = 1, 140 do
    local a, y = rng:random() * math.pi * 2, rng:random() * 0.95 + 0.05
    local r = math.sqrt(1 - y * y)
    R.stars[i] = {math.cos(a) * r, y, math.sin(a) * r, 0.4 + rng:random() * 0.6}
  end
  R.setScale(R.scale)
end

function R.setScale(s)
  R.scale = s
  if canvas then canvas:release(); canvas = nil end
  if s < 1 then
    canvas = love.graphics.newCanvas(math.floor(W_ * s), math.floor(H_ * s))
    canvas:setFilter("nearest", "nearest")
  end
end

-- ---------------------------------------------------------------- matrizes (linha-maior)

local function mul(a, b)
  local r = {}
  for i = 0, 3 do
    for j = 0, 3 do
      local s = 0
      for k = 0, 3 do s = s + a[i * 4 + k + 1] * b[k * 4 + j + 1] end
      r[i * 4 + j + 1] = s
    end
  end
  return r
end

function R.forward(yaw, pitch)
  local cp = math.cos(pitch)
  return math.sin(yaw) * cp, math.sin(pitch), -math.cos(yaw) * cp
end

function R.buildMatrices(yaw, pitch, far)
  local fx, fy, fz = R.forward(yaw, pitch)
  local rx, ry, rz = math.cos(yaw), 0, math.sin(yaw)
  -- u = r x f
  local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
  local view = {
    rx, ry, rz, 0,
    ux, uy, uz, 0,
    -fx, -fy, -fz, 0,
    0, 0, 0, 1,
  }
  local aspect = W_ / H_
  local f = 1 / math.tan(R.fov / 2)
  local n = R.near
  local proj = {
    f / aspect, 0, 0, 0,
    0, f, 0, 0,
    0, 0, (far + n) / (n - far), 2 * far * n / (n - far),
    0, 0, -1, 0,
  }
  R.vp = mul(proj, view)
  R.fwd = {fx, fy, fz}
  -- planos do frustum (Gribb-Hartmann), sem o plano distante
  local m = R.vp
  local planes = {}
  local function plane(s, row)
    local a = m[13] + s * m[row * 4 + 1]
    local b = m[14] + s * m[row * 4 + 2]
    local c = m[15] + s * m[row * 4 + 3]
    local d = m[16] + s * m[row * 4 + 4]
    local l = math.sqrt(a * a + b * b + c * c)
    planes[#planes + 1] = {a / l, b / l, c / l, d / l}
  end
  plane(1, 0); plane(-1, 0); plane(1, 1); plane(-1, 1); plane(1, 2)
  R.planes = planes
end

local function sphereVisible(x, y, z, r)
  for i = 1, #R.planes do
    local p = R.planes[i]
    if p[1] * x + p[2] * y + p[3] * z + p[4] < -r then return false end
  end
  return true
end

-- projeta ponto relativo à câmera; devolve x, y de tela e w (w <= 0: atrás)
function R.project(x, y, z, w)
  local m = R.vp
  local cx = m[1] * x + m[2] * y + m[3] * z + m[4] * w
  local cy = m[5] * x + m[6] * y + m[7] * z + m[8] * w
  local cw = m[13] * x + m[14] * y + m[15] * z + m[16] * w
  if cw <= 1e-4 then return nil end
  return (cx / cw * 0.5 + 0.5) * W_, (0.5 - cy / cw * 0.5) * H_, cw
end

-- ---------------------------------------------------------------- céu

local function mix3(a, b, t)
  return {a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t}
end
local function smooth(e0, e1, x)
  local t = (x - e0) / (e1 - e0)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  return t * t * (3 - 2 * t)
end

local SKY = {
  day = {top = {0.24, 0.35, 0.52}, hor = {0.58, 0.58, 0.64}},
  dusk = {top = {0.20, 0.09, 0.22}, hor = {0.86, 0.30, 0.22}},
  night = {top = {0.010, 0.006, 0.020}, hor = {0.08, 0.02, 0.04}},
}

-- t em [0,1): 0 nascer, 0.25 meio-dia, 0.5 pôr, 0.75 meia-noite
function R.setTime(t)
  local a = t * math.pi * 2
  local s = math.sin(a)
  R.sunDir = {math.cos(a), s, 0.35}
  local dayW = smooth(0.0, 0.35, s)
  local nightW = smooth(0.0, -0.3, s)
  local top = mix3(mix3(SKY.dusk.top, SKY.day.top, dayW), SKY.night.top, nightW)
  local hor = mix3(mix3(SKY.dusk.hor, SKY.day.hor, dayW), SKY.night.hor, nightW)
  R.skyTop, R.skyHor = top, hor
  R.night = nightW
  R.day = 0.16 + 0.84 * smooth(-0.25, 0.3, s)
end

local function drawSky(pitch)
  local top, hor = R.skyTop, R.skyHor
  -- o horizonte desce/sobe com a inclinação da câmera
  local f = 1 / math.tan(R.fov / 2)
  local hy = H_ * 0.5 + math.tan(pitch) * f * H_ * 0.5
  local t1 = math.max(-H_, math.min(2 * H_, hy - H_ * 0.9))
  local m = R.skyMesh
  love.graphics.setColor(1, 1, 1)
  -- faixa superior: topo -> horizonte; abaixo do horizonte, cor do horizonte (névoa)
  love.graphics.clear(hor[1], hor[2], hor[3], 1, false, true)
  m:setVertex(1, 0, t1, 0, 0, top[1], top[2], top[3], 1)
  m:setVertex(2, W_, t1, 0, 0, top[1], top[2], top[3], 1)
  m:setVertex(3, W_, hy, 0, 0, hor[1], hor[2], hor[3], 1)
  m:setVertex(4, 0, hy, 0, 0, hor[1], hor[2], hor[3], 1)
  love.graphics.setColor(top)
  if t1 > 0 then love.graphics.rectangle("fill", 0, 0, W_, t1) end
  love.graphics.setColor(1, 1, 1)
  love.graphics.draw(m)

  -- estrelas
  if R.night > 0.05 then
    love.graphics.setPointSize(1)
    for i = 1, #R.stars do
      local s = R.stars[i]
      local x, y = R.project(s[1], s[2], s[3], 0)
      if x and x >= 0 and x < W_ and y >= 0 and y < H_ then
        love.graphics.setColor(0.9, 0.85, 0.9, s[4] * R.night)
        love.graphics.points(x, y)
      end
    end
  end
  -- sol (creme com halo vermelho) e lua (oposta)
  local d = R.sunDir
  local x, y = R.project(d[1], d[2], d[3], 0)
  if x then
    love.graphics.setColor(0.95, 0.35, 0.30, 0.25)
    love.graphics.circle("fill", x, y, 30)
    love.graphics.setColor(1.0, 0.92, 0.82, 1)
    love.graphics.circle("fill", x, y, 16)
  end
  x, y = R.project(-d[1], -d[2], -d[3], 0)
  if x then
    love.graphics.setColor(0.80, 0.80, 0.86, 0.9)
    love.graphics.circle("fill", x, y, 10)
    love.graphics.setColor(top[1], top[2], top[3], 0.9)
    love.graphics.circle("fill", x + 4, y - 2, 8)
  end
  love.graphics.setColor(1, 1, 1)
end

-- ---------------------------------------------------------------- mundo

local visible = {}
local tvis = {}

-- cam: {x, y, z, yaw, pitch}; target: bloco mirado ou nil
function R.drawWorld(cam, target, underwater)
  local radius = R.radius
  local far = (radius + 0.5) * W.CS
  R.buildMatrices(cam.yaw, cam.pitch, far + 16)

  if canvas then
    love.graphics.setCanvas({canvas, depth = true})
    love.graphics.push()
    love.graphics.scale(R.scale)
  end
  local flip = canvas and -1 or 1

  drawSky(cam.pitch)

  local fogNear, fogFar = far * 0.72, far * 1.02
  local fog = R.skyHor
  if underwater then fogNear, fogFar, fog = 0, 10, {0.06, 0.14, 0.20} end
  for _, s in ipairs({R.shader, R.tshader}) do
    s:send("u_vp", "row", R.vp)
    s:send("u_fogNear", fogNear)
    s:send("u_fogFar", fogFar)
    s:send("u_fog", fog)
    s:send("u_day", R.day)
    s:send("u_hand", R.night * 0.75)
    s:send("u_flip", flip)
  end

  -- seleção das seções visíveis
  local ccx, ccz = math.floor(cam.x / W.CS), math.floor(cam.z / W.CS)
  local nv, nt = 0, 0
  local faces = 0
  local r2 = (radius + 0.75) * (radius + 0.75) * W.CS * W.CS
  for dz = -radius, radius do
    for dx = -radius, radius do
      local c = W.getChunk(ccx + dx, ccz + dz)
      if c then
        local ox, oz = c.cx * W.CS - cam.x, c.cz * W.CS - cam.z
        local mx, mz = ox + 8, oz + 8
        if mx * mx + mz * mz <= r2 then
          for sec = 0, W.NSEC - 1 do
            local s = c.sections[sec]
            if s.mesh or s.tmesh then
              local oy = sec * W.SEC - cam.y
              if sphereVisible(mx, oy + 8, mz, 14) then
                if s.mesh then
                  nv = nv + 1
                  visible[nv] = s; s.ox, s.oy, s.oz = ox, oy, oz
                  faces = faces + (s.faces or 0)
                end
                if s.tmesh then
                  nt = nt + 1
                  tvis[nt] = s; s.ox, s.oy, s.oz = ox, oy, oz
                  s.dist = mx * mx + (oy + 8) * (oy + 8) + mz * mz
                end
              end
            end
          end
        end
      end
    end
  end
  for i = nv + 1, #visible do visible[i] = nil end
  for i = nt + 1, #tvis do tvis[i] = nil end

  love.graphics.setDepthMode("lequal", true)
  love.graphics.setMeshCullMode("back")
  love.graphics.setShader(R.shader)
  for i = 1, nv do
    local s = visible[i]
    R.shader:send("u_off", {s.ox, s.oy, s.oz})
    love.graphics.draw(s.mesh)
  end
  -- transparentes de trás para a frente, sem recorte de face (água vista de baixo)
  table.sort(tvis, function(a, b) return a.dist > b.dist end)
  love.graphics.setMeshCullMode("none")
  love.graphics.setShader(R.tshader)
  for i = 1, nt do
    local s = tvis[i]
    R.tshader:send("u_off", {s.ox, s.oy, s.oz})
    love.graphics.draw(s.tmesh)
  end
  love.graphics.setShader()
  love.graphics.setDepthMode()
  R.stats.sections, R.stats.faces, R.stats.draws = nv, faces, nv + nt

  if target then R.drawOutline(target, cam) end
  if underwater then
    love.graphics.setColor(0.05, 0.15, 0.25, 0.35)
    love.graphics.rectangle("fill", 0, 0, W_, H_)
    love.graphics.setColor(1, 1, 1)
  end

  if canvas then
    love.graphics.pop()
    love.graphics.setCanvas()
    love.graphics.setColor(1, 1, 1)
    love.graphics.draw(canvas, 0, 0, 0, 1 / R.scale, 1 / R.scale)
  end
end

-- contorno: 12 arestas recortadas no plano próximo e projetadas em 2D
local EDGES = {{1, 2}, {2, 3}, {3, 4}, {4, 1}, {5, 6}, {6, 7}, {7, 8}, {8, 5}, {1, 5}, {2, 6}, {3, 7}, {4, 8}}
function R.drawOutline(t, cam)
  local e = 0.004
  local x0, y0, z0 = t[1] - cam.x - e, t[2] - cam.y - e, t[3] - cam.z - e
  local x1, y1, z1 = x0 + 1 + 2 * e, y0 + 1 + 2 * e, z0 + 1 + 2 * e
  local P = {{x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}, {x0, y0, z1},
             {x0, y1, z0}, {x1, y1, z0}, {x1, y1, z1}, {x0, y1, z1}}
  local m = R.vp
  local C = {}
  for i = 1, 8 do
    local p = P[i]
    C[i] = {
      m[1] * p[1] + m[2] * p[2] + m[3] * p[3] + m[4],
      m[5] * p[1] + m[6] * p[2] + m[7] * p[3] + m[8],
      m[13] * p[1] + m[14] * p[2] + m[15] * p[3] + m[16],
    }
  end
  local s = canvas and R.scale or 1
  love.graphics.setLineWidth(math.max(1, 2 * s))
  love.graphics.setColor(0.95, 0.15, 0.22, 0.95)
  local near = 0.02
  for _, ed in ipairs(EDGES) do
    local a, b = C[ed[1]], C[ed[2]]
    if not (a[3] < near and b[3] < near) then
      if a[3] < near then
        local k = (near - a[3]) / (b[3] - a[3])
        a = {a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, near}
      elseif b[3] < near then
        local k = (near - b[3]) / (a[3] - b[3])
        b = {b[1] + (a[1] - b[1]) * k, b[2] + (a[2] - b[2]) * k, near}
      end
      love.graphics.line((a[1] / a[3] * 0.5 + 0.5) * W_, (0.5 - a[2] / a[3] * 0.5) * H_,
                         (b[1] / b[3] * 0.5 + 0.5) * W_, (0.5 - b[2] / b[3] * 0.5) * H_)
    end
  end
  love.graphics.setColor(1, 1, 1)
  love.graphics.setLineWidth(1)
end

return R
