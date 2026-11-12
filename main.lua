-- Camada Zero: sandbox de blocos em primeira pessoa para o R36S (LÖVE 11.5).
-- Estados: title -> loading -> game <-> pause (-> btntest).

-- Este runtime entrega o LuaJIT com o JIT desligado. Ligar (jit.on) provoca
-- segfault intermitente neste aparelho (medido: 3 quedas com JIT, 175 s estável
-- sem ele), então o jogo NUNCA liga o JIT. O trabalho pesado vai para uma thread.

local B = require("blocks")
local G = require("gen")
local W = require("world")
local M = require("mesher")
local R = require("render")
local P = require("player")
local I = require("input")
local S = require("sfx")
local PR = require("profile")
local IOLog = require("iolog")
local Net = require("net")

local SW, SH = 640, 480
local RED = {0.86, 0.12, 0.20}
local TXT = {0.94, 0.91, 0.86}
local DIM = {0.55, 0.50, 0.52}

local state = "title"
local fonts = {}
local cfg = {sens = 2.4, invert = 0, radius = 3, scale = 1, ao = 1, hud = 1, input = "auto", base = 0}
local player
local gameTime = 0.12        -- hora do dia (0..1)
local DAY_LEN = 600          -- segundos por dia
local slot = 1
local target, targetPrev
local breakT, placeT = 0, 0
local saveTimer = 0
local toast, toastT = nil, 0
local menuSel = 1
local navT = 0
local confirmNew = false
local demo = nil             -- autodemo (arquivo autodemo.flag)
local perf = {frames = 0, t = 0, maxdt = 0, fps = 0, minfps = 999, sum = 0, n = 0}
local clock = 0
local selectHeld = false

-- ---------------------------------------------------------------- config

local function loadCfg()
  local t = love.filesystem.read("config.txt")
  if not t then return end
  for k, v in t:gmatch("(%w+)=(%S+)") do
    if cfg[k] ~= nil then cfg[k] = tonumber(v) or v end
  end
end

local function saveCfg()
  local out = {}
  for k, v in pairs(cfg) do out[#out + 1] = k .. "=" .. tostring(v) end
  table.sort(out)
  IOLog.writeFile("config.txt", table.concat(out, "\n") .. "\n")
end

local function applyCfg()
  R.radius = cfg.radius
  if R.scale ~= cfg.scale then R.setScale(cfg.scale) end
  M.ao = cfg.ao == 1
  I.setBase(cfg.base)
  I.force = (cfg.input == "gamepad" or cfg.input == "bruto") and cfg.input or nil
  I.pick()
end

local function readDemo()
  local t = love.filesystem.read("autodemo.flag")
  if not t then return nil end
  local d = {mode = "walk", seconds = 0, timescale = 1, t = 0}
  for k, v in t:gmatch("(%w+)=(%S+)") do d[k] = tonumber(v) or v end
  return d
end

local function say(s, t) toast, toastT = s, t or 2.5 end

-- ---------------------------------------------------------------- mundo / streaming

local offsets = {}
local function buildOffsets(r)
  offsets = {}
  for dz = -r, r do
    for dx = -r, r do offsets[#offsets + 1] = {dx, dz, dx * dx + dz * dz} end
  end
  table.sort(offsets, function(a, b) return a[3] < b[3] end)
end

local function neighborsReady(cx, cz)
  for dz = -1, 1 do
    for dx = -1, 1 do
      if not W.getChunk(cx + dx, cz + dz) then return false end
    end
  end
  return true
end

local pending = 0
local streamStats = {ms = 0, gens = 0, builds = 0}

-- despacha geração e malha para o worker; nada pesado roda aqui
local function stream()
  local t0 = love.timer.getTime()
  streamStats.gens, streamStats.builds = 0, 0
  local pcx, pcz = math.floor(player.x / W.CS), math.floor(player.z / W.CS)
  -- Chebyshev: toda seção montada tem os 8 vizinhos gerados
  local genR = cfg.radius + 1
  local meshR = cfg.radius
  pending = 0
  if Net.enabled then
    Net.pump()
    -- 1. edições (urgentes)
    for _, o in ipairs(offsets) do
      if math.max(math.abs(o[1]), math.abs(o[2])) <= meshR then
        local c = W.getChunk(pcx + o[1], pcz + o[2])
        if c then
          for sec = 0, W.NSEC - 1 do
            if c.sections[sec].urgent and Net.dispatchMesh(c, sec, true) then
              streamStats.builds = streamStats.builds + 1
            end
          end
        end
      end
    end
    -- 2. gera o que falta (mais perto primeiro)
    for _, o in ipairs(offsets) do
      if math.max(math.abs(o[1]), math.abs(o[2])) <= genR then
        local cx, cz = pcx + o[1], pcz + o[2]
        if not W.getChunk(cx, cz) then
          pending = pending + 1
          if Net.dispatchGen(cx, cz) then streamStats.gens = streamStats.gens + 1 end
        end
      end
    end
    -- 3. malhas pendentes
    for _, o in ipairs(offsets) do
      if math.max(math.abs(o[1]), math.abs(o[2])) <= meshR then
        local c = W.getChunk(pcx + o[1], pcz + o[2])
        if c then
          for sec = 0, W.NSEC - 1 do
            local s = c.sections[sec]
            if s.dirty then
              if s.empty then s.dirty = false else
                pending = pending + 1
                if Net.dispatchMesh(c, sec) then streamStats.builds = streamStats.builds + 1 end
              end
            end
          end
        end
      end
    end
  else
    -- fallback sem worker (só se a thread não puder ser criada)
    for _, o in ipairs(offsets) do
      local cx, cz = pcx + o[1], pcz + o[2]
      if math.max(math.abs(o[1]), math.abs(o[2])) <= genR then
        local c = W.getChunk(cx, cz)
        if not c then
          pending = pending + 1
          if love.timer.getTime() - t0 < 0.006 then
            W.generate(cx, cz); streamStats.gens = streamStats.gens + 1
          end
        elseif math.max(math.abs(o[1]), math.abs(o[2])) <= meshR then
          for sec = 0, W.NSEC - 1 do
            if c.sections[sec].dirty then
              pending = pending + 1
              if love.timer.getTime() - t0 < 0.006 then
                Net.buildSync(c, sec); streamStats.builds = streamStats.builds + 1
              end
            end
          end
        end
      end
    end
  end
  -- descarrega o que ficou longe (as alterações continuam em W.edits)
  local lim = cfg.radius + 3
  for _, c in pairs(W.chunks) do
    if math.abs(c.cx - pcx) > lim or math.abs(c.cz - pcz) > lim then W.unload(c) end
  end
  streamStats.ms = (love.timer.getTime() - t0) * 1000
end

-- despacha já as seções tocadas por uma edição (urgente, fura a fila normal)
local function rebuildUrgent(x, z)
  local cx, cz = math.floor(x / W.CS), math.floor(z / W.CS)
  for dz = -1, 1 do
    for dx = -1, 1 do
      local c = W.getChunk(cx + dx, cz + dz)
      if c then
        for sec = 0, W.NSEC - 1 do
          local s = c.sections[sec]
          if s.urgent then
            if Net.enabled then Net.dispatchMesh(c, sec, true) else Net.buildSync(c, sec) end
          end
        end
      end
    end
  end
end

local function findSpawn()
  -- procura chão plano e escolhe o rumo com a vista mais aberta (terreno mais baixo)
  for r = 0, 120 do
    for dz = -r, r do
      for dx = -r, r do
        if math.max(math.abs(dx), math.abs(dz)) == r then
          local x, z = 8 + dx * 3, 8 + dz * 3
          local h = W.height(x, z)
          if h > W.SEA + 2 and h < 30 then
            local lo, hi = h, h
            for oz = -2, 2 do
              for ox = -2, 2 do
                local hh = W.height(x + ox, z + oz)
                if hh < lo then lo = hh elseif hh > hi then hi = hh end
              end
            end
            local clear = true
            if hi - lo <= 3 then
              for oz = -4, 4 do
                for ox = -4, 4 do
                  if G.treeAt(x + ox, z + oz) then clear = false end
                end
              end
            end
            if hi - lo <= 3 and clear then
              -- média da altura em 4 rumos, a 7 blocos
              local dirs = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
              local best, bestYaw = 1e9, 0
              for i, d in ipairs(dirs) do
                local sum = 0
                for k = 2, 8 do sum = sum + W.height(x + d[1] * k, z + d[2] * k) end
                if sum < best then
                  best = sum
                  bestYaw = (i == 1 and 0) or (i == 2 and math.pi / 2) or (i == 3 and math.pi) or (-math.pi / 2)
                end
              end
              return x + 0.5, h + 1.01, z + 0.5, bestYaw
            end
          end
        end
      end
    end
  end
  return 8.5, W.H - 4, 8.5, 0
end

W.writer = function(name, text) return IOLog.writeFile(name, text) end

local function saveGame()
  if not player then return false end
  local t0 = love.timer.getTime()
  local ok, err = W.save({x = player.x, y = player.y, z = player.z, yaw = player.yaw,
    pitch = player.pitch, time = gameTime, slot = slot})
  if not ok then say("Erro ao salvar: " .. tostring(err), 4) end
  local ms = (love.timer.getTime() - t0) * 1000
  if ms > 50 then IOLog.append("profile.log", string.format("%.2f save %.0fms\n", love.timer.getTime(), ms)) end
  return ok
end

-- modo de teste: carimba uma fileira de blocos e um buraco à frente do jogador,
-- usando o mesmo W.set do jogo normal (prova de gravação/leitura)
function stampWorld()
  local fx, fz = math.sin(player.yaw), -math.cos(player.yaw)
  local rx, rz = math.cos(player.yaw), math.sin(player.yaw)
  local bx, bz = player.x + fx * 3, player.z + fz * 3
  local ids = {B.BRICK, B.PLANKS, B.PLANKS, B.BRICK, B.BRICK, B.PLANKS}
  for i = -2, 3 do
    local x = math.floor(bx + rx * i)
    local z = math.floor(bz + rz * i)
    local y = W.topSolid(x, z) + 1
    local ok = W.set(x, y, z, ids[i + 3])
    I.log(string.format("stamp %d,%d,%d=%d ok=%s", x, y, z, ids[i + 3], tostring(ok)))
    if i == 0 then
      W.set(x, y + 1, z, B.LAMP)
      I.log(string.format("stamp lampada %d,%d,%d", x, y + 1, z))
    end
  end
  local hx = math.floor(player.x + fx * 2 + rx * 2)
  local hz = math.floor(player.z + fz * 2 + rz * 2)
  local hy = W.topSolid(hx, hz)
  W.set(hx, hy, hz, B.AIR)
  W.set(hx, hy - 1, hz, B.AIR)
  I.log(string.format("stamp buraco %d,%d,%d", hx, hy, hz))
  rebuildUrgent(math.floor(bx), math.floor(bz))
  rebuildUrgent(hx, hz)
  player.pitch = -0.18
  saveGame()
end

local function startWorld(continue)
  local st
  if continue then st = W.load() end
  if st then
    Net.reset(W.seed)
    player = P.new(st.x or 8.5, st.y or 40, st.z or 8.5)
    player.yaw, player.pitch = st.yaw or 0, st.pitch or 0
    gameTime = (demo and demo.time) or st.time or 0.12
    slot = st.slot or 1
  else
    local seed = (demo and demo.seed) or love.math.random(1, 999999)
    W.reset(seed)
    Net.reset(seed)
    local x, y, z, yaw = findSpawn()
    player = P.new(x, y, z)
    player.yaw = yaw
    gameTime, slot = (demo and demo.time) or 0.12, 1
    saveGame()
  end
  buildOffsets(cfg.radius + 2)
  state = "loading"
  saveTimer = 0
end

local function exitToTitle()
  I.log("exitToTitle")
  saveGame()
  for _, c in pairs(W.chunks) do W.unload(c) end
  W.chunks = {}
  player = nil
  state, menuSel, confirmNew = "title", 1, false
  collectgarbage()
end

local function quitGame()
  I.log("quitGame motivo=" .. tostring(debug.traceback("", 2):gsub("\n", " | ")))
  if player then saveGame() end
  love.event.quit()
end

-- ---------------------------------------------------------------- ações

local function doBreak()
  if not target then return end
  local id = W.get(target[1], target[2], target[3])
  local d = B.defs[id]
  if not d or d.unbreakable then return end
  W.set(target[1], target[2], target[3], B.AIR)
  rebuildUrgent(target[1], target[3])
  S.play("break_")
  if demo then I.log(string.format("demo quebrou %d,%d,%d (%s)", target[1], target[2], target[3], d.name)) end
end

local function doPlace()
  if not target or not targetPrev then return end
  local x, y, z = targetPrev[1], targetPrev[2], targetPrev[3]
  local cur = W.get(x, y, z)
  if cur ~= B.AIR and cur ~= B.WATER then return end
  if P.blockIntersects(player, x, y, z) then say("Sem espaço: você está aí", 1.2); return end
  local id = B.hotbar[slot]
  if W.set(x, y, z, id) then
    rebuildUrgent(x, z)
    S.play("place")
    if demo then I.log(string.format("demo colocou %d,%d,%d (%s)", x, y, z, B.defs[id].name)) end
  end
end

local function changeSlot(d)
  slot = (slot - 1 + d) % #B.hotbar + 1
  say(B.defs[B.hotbar[slot]].name, 1.2)
end

-- ---------------------------------------------------------------- autodemo

local function demoControl(dt)
  local d = demo
  d.t = d.t + dt
  d.wantAct = nil
  local t = d.t
  local c = {lx = 0, ly = 0, rx = 0, ry = 0, jump = false, run = false}
  if d.mode == "still" or d.mode == "stamp" then return c end
  if d.mode == "build" then
    -- leque de blocos no chão à frente, depois dois buracos no meio
    local steps = {
      {1.0, -0.55, -0.50, 10}, {1.7, -0.55, -0.25, 7}, {2.4, -0.55, 0.0, 9},
      {3.1, -0.55, 0.25, 8}, {3.8, -0.55, 0.50, 5}, {4.6, -0.95, 0.0, 0},
      {5.2, -0.95, 0.02, 0}, {6.0, -0.45, 0.0, 0},
    }
    d.baseYaw = d.baseYaw or player.yaw
    for i, s in ipairs(steps) do
      if not d["done" .. i] and t >= s[1] then
        d["done" .. i] = true
        player.pitch, player.yaw = s[2], d.baseYaw + s[3]
        d.wantAct, d.wantSlot = s[4] > 0 and "place" or "break", s[4]
      end
    end
    return c
  end
  -- "walk": anda, vira, pula, quebra e coloca em ciclos de 8 s
  local phase = t % 8
  if phase < 5 then
    c.ly = -1
    c.rx = 0.35 * math.sin(t * 0.41) + 0.15
    player.pitch = player.pitch + (-0.12 + 0.18 * math.sin(t * 0.7) - player.pitch) * math.min(1, dt * 2)
    local sp = math.sqrt(player.vx ^ 2 + player.vz ^ 2)
    d.stuck = (sp < 1.0) and (d.stuck or 0) + dt or 0
    if d.stuck > 0.25 or (t % 3.0) < 0.05 then c.jump = true end
    if d.stuck > 2.5 then player.yaw = player.yaw + 1.2; d.stuck = 0 end
  else
    player.pitch = player.pitch + (-0.7 - player.pitch) * math.min(1, dt * 5)
    local k = math.floor((phase - 5) / 0.6)
    if k ~= d.lastK then
      d.lastK = k
      if k == 1 or k == 2 then d.wantAct = "break"
      elseif k == 3 then d.wantAct, d.wantSlot = "place", 9
      elseif k == 4 then d.wantAct = "place" end
    end
  end
  return c
end

local function perfTick(dt)
  local t0 = love.timer.getTime()
  perf.frames = perf.frames + 1
  perf.t = perf.t + dt
  if dt > perf.maxdt then perf.maxdt = dt end
  if perf.t >= 1 then
    perf.fps = perf.frames / perf.t
    if state == "game" and clock > 3 then
      perf.minfps = math.min(perf.minfps, perf.fps)
      perf.sum, perf.n = perf.sum + perf.fps, perf.n + 1
    end
    if demo then
      local nch = 0
      for _ in pairs(W.chunks) do nch = nch + 1 end
      IOLog.append("perf.log", string.format(
        "t=%.1f estado=%s fps=%.1f maxdt=%.1fms lua=%.0fKB secoes=%d faces=%d chunks=%d pend=%d pos=%.1f,%.1f,%.1f\n",
        clock, state, perf.fps, perf.maxdt * 1000, collectgarbage("count"), R.stats.sections, R.stats.faces, nch,
        pending, player and player.x or 0, player and player.y or 0, player and player.z or 0))
    end
    if PR.on then
      local ms = (love.timer.getTime() - t0) * 1000
      if ms > 50 then IOLog.append("profile.log", string.format("%.2f perf %.0fms\n", love.timer.getTime(), ms)) end
    end
    perf.frames, perf.t, perf.maxdt = 0, 0, 0
    -- capturas pelo próprio LÖVE (útil no PC; no aparelho usamos drmcap)
    if demo and demo.shot and state == "game" then
      perf.shotT = (perf.shotT or 0) + 1
      if perf.shotT % demo.shot == 0 then
        love.graphics.captureScreenshot(string.format("demo-%03d.png", perf.shotT))
      end
    end
  end
end

-- ---------------------------------------------------------------- LÖVE

local hb
function love.load()
  hb = io.open("/tmp/cz-heartbeat.log", "w")
  if hb then hb:write("load\n"); hb:flush() end
  love.graphics.setDefaultFilter("nearest", "nearest")
  fonts.small = love.graphics.newFont(12)
  fonts.med = love.graphics.newFont(18)
  fonts.big = love.graphics.newFont(46)
  IOLog.init()
  loadCfg()
  demo = readDemo()
  B.buildAtlas()
  R.init(B.atlas)
  Net.init(B.atlas)
  S.init()
  applyCfg()
  IOLog.writeFile("input.log", "")
  PR.on = love.filesystem.getInfo("profile.on") ~= nil
  IOLog.writeFile("profile.log", "")
  local jitok, jit = pcall(require, "jit")
  if jitok then
    local st = {jit.status()}
    local t0 = love.timer.getTime()
    local acc = 0
    for i = 1, 2000000 do acc = acc + i % 7 end
    local t1 = love.timer.getTime()
    I.log(string.format("jit=%s jit_status=%s bench2M=%.1fms acc=%d", tostring(jit.version), tostring(st[1]), (t1-t0)*1000, acc))
  end
  I.log("worker=" .. tostring(Net.enabled) .. (Net.error and (" erro=" .. Net.error) or ""))
  I.log("inicio love " .. table.concat({love.getVersion()}, ".") .. " " .. table.concat({love.graphics.getRendererInfo()}, " | "))
  if demo then
    IOLog.writeFile("perf.log", "")
    I.log("autodemo modo=" .. tostring(demo.mode) .. " seg=" .. tostring(demo.seconds))
  end
  I.onPress = function(name)
    if name == "select" then selectHeld = true end
  end
end

function love.threaderror(t, msg)
  I.log("ERRO NA THREAD: " .. tostring(msg))
  Net.enabled = false
  Net.error = tostring(msg)
  love.filesystem.write("error.log", "thread: " .. tostring(msg) .. "\n" .. debug.traceback())
end

function love.joystickadded(j) I.joystickadded(j) end
function love.joystickremoved(j) I.joystickremoved(j) end
function love.joystickpressed(j, b) I.joystickpressed(j, b) end
function love.gamepadpressed(j, b) I.gamepadpressed(j, b) end
function love.joystickaxis(j, a, v) I.joystickaxis(j, a, v) end
function love.keypressed(k)
  if k == "f12" then love.graphics.captureScreenshot("tela-" .. os.time() .. ".png") end
  I.keypressed(k)
end

local function menuNav(n)
  local _, ly = I.sticks()
  navT = navT - love.timer.getDelta()
  local d = 0
  if I.pressed.up then d = -1 elseif I.pressed.down then d = 1
  elseif navT <= 0 and math.abs(ly) > 0.6 then d = ly > 0 and 1 or -1; navT = 0.22 end
  if math.abs(ly) < 0.3 and not (I.pressed.up or I.pressed.down) then navT = 0 end
  if d ~= 0 then menuSel = (menuSel - 1 + d) % n + 1; S.play("blip") end
end

local function titleItems()
  local it = {}
  if W.hasSave() then it[#it + 1] = {"Continuar", "cont"} end
  it[#it + 1] = {"Novo mundo", "new"}
  it[#it + 1] = {"Sair", "quit"}
  return it
end

local function pauseItems()
  return {
    {"Voltar ao jogo", "resume"},
    {string.format("Sensibilidade: %.1f", cfg.sens), "sens"},
    {"Inverter olhar vertical: " .. (cfg.invert == 1 and "sim" or "não"), "invert"},
    {"Distância de visão: " .. cfg.radius .. " chunks", "radius"},
    {string.format("Resolução 3D: %d%%", cfg.scale * 100), "scale"},
    {"Sombra nos cantos (AO): " .. (cfg.ao == 1 and "sim" or "não"), "ao"},
    {"Teste de botões", "btntest"},
    {"Salvar e voltar ao título", "title"},
    {"Salvar e sair", "quit"},
  }
end

local function adjust(id, d)
  if id == "sens" then cfg.sens = math.max(0.6, math.min(5, cfg.sens + 0.2 * d))
  elseif id == "invert" then cfg.invert = 1 - cfg.invert
  elseif id == "radius" then
    cfg.radius = math.max(1, math.min(5, cfg.radius + d)); buildOffsets(cfg.radius + 2)
  elseif id == "scale" then
    local opts = {0.5, 0.75, 1}
    local k = 3
    for i, v in ipairs(opts) do if math.abs(v - cfg.scale) < 0.01 then k = i end end
    cfg.scale = opts[(k - 1 + d) % 3 + 1]
  elseif id == "ao" then
    cfg.ao = 1 - cfg.ao
    for _, c in pairs(W.chunks) do for s = 0, W.NSEC - 1 do c.sections[s].dirty = true end end
  else return end
  applyCfg(); saveCfg(); S.play("blip")
end

local function updateGame(dt)
  local tP = love.timer.getTime()
  local lx, ly, rx, ry = I.sticks()
  local tA = love.timer.getTime()
  local jump, run = I.isDown("a"), I.isDown("b")
  if demo then
    demo.runT = (demo.runT or 0) + dt
    if demo.mode == "stamp" and not demo.stamped and demo.runT >= (demo.at or 0) then
      stampWorld(); demo.stamped = true
    end
    local c = demoControl(dt)
    lx, ly, rx, ry, jump, run = c.lx, c.ly, c.rx, c.ry, c.jump, c.run
  end
  local sens = cfg.sens
  player.yaw = player.yaw + rx * sens * dt
  local inv = cfg.invert == 1 and -1 or 1
  player.pitch = player.pitch - ry * sens * 0.8 * dt * inv
  if player.pitch > 1.5 then player.pitch = 1.5 elseif player.pitch < -1.5 then player.pitch = -1.5 end

  P.update(player, dt, lx, -ly, jump, run)
  local tB = love.timer.getTime()

  local fx, fy, fz = R.forward(player.yaw, player.pitch)
  target, targetPrev = P.raycast(player, fx, fy, fz)

  if demo and demo.wantAct then
    if demo.wantSlot and demo.wantSlot > 0 then
      for k, id in ipairs(B.hotbar) do if id == demo.wantSlot then slot = k end end
    end
    I.log(string.format("demo acao=%s alvo=%s prev=%s pitch=%.2f yaw=%.2f slot=%d", demo.wantAct,
      target and table.concat(target, ",") or "nil", targetPrev and table.concat(targetPrev, ",") or "nil",
      player.pitch, player.yaw, slot))
    if demo.wantAct == "place" then doPlace() else doBreak() end
    demo.wantAct = nil
  end

  -- quebrar (R1/R2) e colocar (L1/L2), com repetição se segurar
  breakT, placeT = breakT - dt, placeT - dt
  if I.pressed.r1 or I.pressed.r2 then doBreak(); breakT = 0.35
  elseif (I.isDown("r1") or I.isDown("r2")) and breakT <= 0 then doBreak(); breakT = 0.25 end
  if I.pressed.l1 or I.pressed.l2 then doPlace(); placeT = 0.35
  elseif (I.isDown("l1") or I.isDown("l2")) and placeT <= 0 then doPlace(); placeT = 0.25 end
  if I.pressed.x or I.pressed.left then changeSlot(-1) end
  if I.pressed.y or I.pressed.right then changeSlot(1) end
  if I.pressed.up then cfg.hud = 1 - cfg.hud; saveCfg() end
  local tC = love.timer.getTime()

  gameTime = (gameTime + dt / DAY_LEN * (demo and demo.timescale or 1)) % 1
  saveTimer = saveTimer + dt
  if saveTimer >= 60 then
    saveTimer = 0
    if saveGame() then say("Mundo salvo", 1.5) end
  end
  stream()
  if PR.on then
    local tD = love.timer.getTime()
    if tD - tP > 0.2 then
      IOLog.append("profile.log", string.format("%.2f %-8s total=%.0fms in=%.0f pes=%.0f acao=%.0f stream=%.0f\n",
        tD, "fases", (tD - tP) * 1000, (tA - tP) * 1000, (tB - tA) * 1000, (tC - tB) * 1000, (tD - tC) * 1000))
    end
  end
end

local lastUpd = 0
function love.update(dt)
  local tU = love.timer.getTime()
  local rawdt = dt
  if dt > 1 / 15 then dt = 1 / 15 end
  clock = clock + dt
  I.update()
  if PR.on and rawdt > 0.05 then
    IOLog.append("profile.log", string.format("%.2f frame dt=%.0fms estado=%s\n", love.timer.getTime(), rawdt * 1000, state))
  end
  perfTick(love.timer.getDelta())
  if toastT > 0 then toastT = toastT - dt end

  -- SELECT + START: salva e sai, de qualquer tela
  if I.pressed.start and (I.isDown("select") or selectHeld and I.pressed.select) then
    quitGame(); I.endFrame(); return
  end

  if demo and demo.runT and demo.seconds > 0 and demo.runT > demo.seconds then
    I.log(string.format("demo fim t=%.1f pos=%.1f,%.1f,%.1f", demo.runT, player.x, player.y, player.z))
    quitGame(); I.endFrame(); return
  end

  if state == "title" then
    local items = titleItems()
    if demo and clock > 1.5 then
      local want = (W.hasSave() and demo.new ~= 1) and "cont" or "new"
      startWorld(want == "cont")
    elseif confirmNew then
      if I.pressed.a then startWorld(false); confirmNew = false
      elseif I.pressed.b then confirmNew = false end
    else
      menuNav(#items)
      if menuSel > #items then menuSel = 1 end
      if I.pressed.a or (I.pressed.start and not I.isDown("select")) then
        local id = items[menuSel][2]
        S.play("blip")
        if id == "cont" then startWorld(true)
        elseif id == "new" then
          if W.hasSave() then confirmNew = true else startWorld(false) end
        elseif id == "quit" then love.event.quit() end
      end
    end
  elseif state == "loading" then
    stream()
    local pcx, pcz = math.floor(player.x / W.CS), math.floor(player.z / W.CS)
    local ready = true
    for dz = -1, 1 do
      for dx = -1, 1 do
        local c = W.getChunk(pcx + dx, pcz + dz)
        if not c then ready = false else
          for s = 0, W.NSEC - 1 do if c.sections[s].dirty then ready = false end end
        end
      end
    end
    if ready then
      -- se nasceu dentro de bloco (mundo alterado), sobe até ficar livre
      local guard = 0
      while P.collides(player, player.x, player.y, player.z) and guard < 64 do
        player.y = player.y + 1; guard = guard + 1
      end
      state = "game"
      clock = 0
      if demo then
        demo.runT = 0
        demo.stamped = false
        if demo.mode == "stamp" and (demo.at or 0) <= 0 then stampWorld(); demo.stamped = true end
      end
    end
  elseif state == "game" then
    if I.pressed.start then state = "pause"; menuSel = 1; S.play("blip")
    else updateGame(dt) end
  elseif state == "pause" then
    local items = pauseItems()
    menuNav(#items)
    local id = items[menuSel][2]
    if I.pressed.left then adjust(id, -1) elseif I.pressed.right then adjust(id, 1) end
    if I.pressed.b or (I.pressed.start and not I.isDown("select")) then state = "game"
    elseif I.pressed.a then
      if id == "resume" then state = "game"
      elseif id == "btntest" then state = "btntest"; I.last = {}; clock = 0
      elseif id == "title" then exitToTitle()
      elseif id == "quit" then quitGame()
      else adjust(id, 1) end
    end
    stream()
  elseif state == "btntest" then
    -- sai segurando START por 1 s
    if I.isDown("start") then perf.holdStart = (perf.holdStart or 0) + dt else perf.holdStart = 0 end
    if perf.holdStart > 1 then state = "pause"; perf.holdStart = 0 end
  end
  if not I.isDown("select") then selectHeld = false end
  I.endFrame()
  lastUpd = love.timer.getTime() - tU
  IOLog.update()
  W.collect(2)
  if hb and love.timer.getTime() - (perf.hbT or 0) > 1 then
    perf.hbT = love.timer.getTime()
    hb:write(string.format("t=%.1f estado=%s clock=%.1f pos=%s\n", love.timer.getTime(), state, clock,
      player and string.format("%.2f", player.y) or "-"))
    hb:flush()
  end
  if PR.on and (lastUpd > 0.2 or rawdt - lastUpd > 0.2) then
    IOLog.append("profile.log", string.format("%.2f %-8s upd=%.0fms total=%.0fms estado=%s stream=%.0fms build=%d gen=%d\n",
      love.timer.getTime(), "lento", lastUpd * 1000, rawdt * 1000, state, streamStats.ms, streamStats.builds, streamStats.gens))
  end
end

function love.quit()
  if hb then hb:write("quit evento\n"); hb:flush() end
  I.log("love.quit estado=" .. state)
  if player and (state == "game" or state == "pause" or state == "btntest") then saveGame() end
  IOLog.close(5)
  return false
end

-- ---------------------------------------------------------------- desenho

local function shadowText(s, x, y, col, font)
  love.graphics.setFont(font or fonts.small)
  love.graphics.setColor(0, 0, 0, 0.75)
  love.graphics.print(s, x + 1, y + 1)
  love.graphics.setColor(col or TXT)
  love.graphics.print(s, x, y)
end

local function centered(s, y, col, font)
  font = font or fonts.med
  shadowText(s, math.floor((SW - font:getWidth(s)) / 2), y, col, font)
end

local function drawWires(t)
  love.graphics.setLineWidth(1)
  for k = 1, 7 do
    local pts = {}
    local y0 = 60 + k * 52
    for i = 0, 32 do
      local x = i * 20
      local y = y0 + math.sin(i * 0.35 + t * (0.4 + k * 0.07) + k) * (10 + k * 3) + math.sin(i * 0.11 - t * 0.3) * 18
      pts[#pts + 1], pts[#pts + 2] = x, y
    end
    local a = 0.10 + 0.06 * math.sin(t + k)
    love.graphics.setColor(RED[1], RED[2], RED[3], a)
    love.graphics.line(pts)
  end
  love.graphics.setColor(1, 1, 1, 0.035)
  for y = 0, SH, 3 do love.graphics.line(0, y, SW, y) end
end

local function drawMenu(items, y0)
  for i, it in ipairs(items) do
    local sel = i == menuSel
    local s = it[1]
    local w = fonts.med:getWidth(s)
    local x = math.floor((SW - w) / 2)
    local y = y0 + (i - 1) * 30
    if sel then
      love.graphics.setColor(RED[1], RED[2], RED[3], 0.85)
      love.graphics.rectangle("fill", x - 16, y - 2, w + 32, 26)
    end
    shadowText(s, x, y, sel and {1, 1, 1} or TXT, fonts.med)
  end
end

local function drawTitle()
  love.graphics.clear(0.035, 0.02, 0.035)
  drawWires(love.timer.getTime())
  local title = "CAMADA ZERO"
  local w = fonts.big:getWidth(title)
  love.graphics.setFont(fonts.big)
  love.graphics.setColor(RED[1], RED[2], RED[3], 0.7)
  love.graphics.print(title, (SW - w) / 2 + 3, 92)
  love.graphics.setColor(TXT)
  love.graphics.print(title, (SW - w) / 2, 90)
  centered("um mundo de blocos desconectado", 148, DIM, fonts.small)
  if confirmNew then
    centered("Apagar o mundo salvo e criar outro?", 230, TXT)
    centered("A: sim     B: não", 270, RED)
  else
    drawMenu(titleItems(), 220)
  end
  centered("A escolhe  ·  SELECT+START sai", SH - 30, DIM, fonts.small)
end

local function drawHotbar()
  local n = #B.hotbar
  local size, gap = 34, 4
  local total = n * size + (n - 1) * gap
  local x0, y0 = math.floor((SW - total) / 2), SH - size - 10
  for i, id in ipairs(B.hotbar) do
    local x = x0 + (i - 1) * (size + gap)
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", x, y0, size, size)
    love.graphics.setColor(1, 1, 1)
    local d = B.defs[id]
    love.graphics.draw(B.atlas, B.quads[d.tiles[2]], x + 3, y0 + 3, 0, 28 / B.TILE, 28 / B.TILE)
    if i == slot then
      love.graphics.setLineWidth(3)
      love.graphics.setColor(RED)
      love.graphics.rectangle("line", x - 1, y0 - 1, size + 2, size + 2)
      love.graphics.setLineWidth(1)
    end
  end
  love.graphics.setColor(1, 1, 1)
end

local function drawCrosshair()
  local cx, cy = SW / 2, SH / 2
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.rectangle("fill", cx - 8, cy - 2, 16, 4)
  love.graphics.rectangle("fill", cx - 2, cy - 8, 4, 16)
  love.graphics.setColor(0.95, 0.92, 0.90, 0.95)
  love.graphics.rectangle("fill", cx - 7, cy - 1, 14, 2)
  love.graphics.rectangle("fill", cx - 1, cy - 7, 2, 14)
end

local function drawHud()
  drawCrosshair()
  drawHotbar()
  if cfg.hud == 1 then
    local hh = math.floor(gameTime * 24 + 6) % 24
    local mm = math.floor((gameTime * 24 * 60 + 360) % 60)
    local lines = {
      string.format("%d fps", love.timer.getFPS()),
      string.format("x %.1f  y %.1f  z %.1f", player.x, player.y, player.z),
      string.format("%02d:%02d  seções %d  faces %d", hh, mm, R.stats.sections, R.stats.faces),
    }
    if pending > 0 then lines[#lines + 1] = "carregando " .. pending end
    if demo then lines[#lines + 1] = "AUTODEMO " .. demo.mode end
    for i, s in ipairs(lines) do shadowText(s, 8, 6 + (i - 1) * 15) end
  end
  if toast and toastT > 0 then
    local a = math.min(1, toastT * 2)
    love.graphics.setFont(fonts.med)
    local w = fonts.med:getWidth(toast)
    love.graphics.setColor(0, 0, 0, 0.5 * a)
    love.graphics.rectangle("fill", (SW - w) / 2 - 10, SH - 82, w + 20, 26)
    love.graphics.setColor(TXT[1], TXT[2], TXT[3], a)
    love.graphics.print(toast, (SW - w) / 2, SH - 79)
  end
end

local function drawPause()
  love.graphics.setColor(0.03, 0.01, 0.03, 0.78)
  love.graphics.rectangle("fill", 0, 0, SW, SH)
  centered("PAUSA", 40, RED, fonts.big)
  drawMenu(pauseItems(), 120)
  centered("D-pad ←/→ ajusta  ·  A escolhe  ·  B/START volta  ·  SELECT+START sai", SH - 30, DIM, fonts.small)
end

local function drawBtnTest()
  love.graphics.clear(0.03, 0.02, 0.04)
  centered("TESTE DE BOTÕES", 30, RED, fonts.med)
  local j = I.joy
  local y = 70
  local function line(s) shadowText(s, 40, y); y = y + 16 end
  if j then
    local ok, guid = pcall(j.getGUID, j)
    line("controle: " .. j:getName())
    line("guid: " .. tostring(guid))
    line("modo: " .. I.mode .. "   BTN_BASE: " .. I.BTN_BASE .. "   gamepad SDL: " .. tostring(j:isGamepad()))
    local held = {}
    for b = 1, j:getButtonCount() do if j:isDown(b) then held[#held + 1] = tostring(b) end end
    line("botões brutos seguros: " .. table.concat(held, " "))
    local ax = {}
    for a = 1, j:getAxisCount() do ax[#ax + 1] = string.format("%d:%+.2f", a, j:getAxis(a)) end
    line("eixos: " .. table.concat(ax, "  "))
  else
    line("nenhum controle encontrado")
  end
  y = y + 8
  line("ações seguras: ")
  local names = {"a", "b", "x", "y", "l1", "r1", "l2", "r2", "up", "down", "left", "right", "select", "start", "l3"}
  local on = {}
  for _, n in ipairs(names) do if I.isDown(n) then on[#on + 1] = n end end
  line("  " .. table.concat(on, " "))
  y = y + 8
  line("últimos eventos:")
  for _, s in ipairs(I.last) do line("  " .. s) end
  centered("segure START 1 s para voltar", SH - 30, DIM, fonts.small)
end

local function drawLoading()
  love.graphics.clear(0.035, 0.02, 0.035)
  drawWires(love.timer.getTime())
  centered("gerando o mundo...", 210, TXT, fonts.med)
  local n = 0
  for _ in pairs(W.chunks) do n = n + 1 end
  centered(string.format("chunks: %d   seed: %d", n, W.seed), 245, DIM, fonts.small)
end

function love.draw()
  local tD = love.timer.getTime()
  if state == "title" then drawTitle()
  elseif state == "loading" then drawLoading()
  elseif state == "btntest" then drawBtnTest()
  else
    R.setTime(gameTime)
    R.drawWorld({x = player.x, y = player.y + P.EYE, z = player.z, yaw = player.yaw, pitch = player.pitch},
      target, player.eyeInWater)
    drawHud()
    if state == "pause" then drawPause() end
  end
  if PR.on then
    local dd = love.timer.getTime() - tD
    if dd > 0.2 then
      IOLog.append("profile.log", string.format("%.2f %-8s draw=%.0fms estado=%s\n",
        love.timer.getTime(), "lento", dd * 1000, state))
    end
  end
end

-- erro: mostra a mensagem, grava error.log e sai com qualquer botão (o launcher devolve o menu)
function love.errorhandler(msg)
  msg = tostring(msg)
  local trace = debug.traceback("Erro: " .. msg, 2)
  pcall(love.filesystem.write, "error.log", trace)
  local eh = io.open("/tmp/cz-heartbeat.log", "a")
  if eh then eh:write("ERRO: " .. trace .. "\n"); eh:close() end
  print(trace)
  if not love.window or not love.graphics or not love.event then return end
  if not love.window.isOpen() then pcall(love.window.setMode, 640, 480) end
  love.graphics.reset()
  local font = love.graphics.newFont(12)
  local t0 = love.timer.getTime()
  return function()
    love.event.pump()
    for e, a in love.event.poll() do
      if e == "quit" then return 1 end
      if (e == "keypressed" or e == "joystickpressed" or e == "gamepadpressed") and love.timer.getTime() - t0 > 1.5 then return 1 end
    end
    if love.timer.getTime() - t0 > 60 then return 1 end
    love.graphics.origin()
    love.graphics.clear(0.08, 0.0, 0.02)
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(trace .. "\n\nAperte qualquer botão para sair.", 20, 20, 600)
    love.graphics.present()
    love.timer.sleep(0.05)
  end
end
