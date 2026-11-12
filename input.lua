-- Entrada: gamepad do SDL (nomes "a", "leftshoulder"...) quando o controle é
-- reconhecido; senão, números brutos de botão com base BTN_BASE. Teclado no PC.
-- Tudo vira nomes abstratos: a b x y l1 r1 l2 r2 up down left right select start l3.
-- Cada evento recebido é gravado em input.log (pasta de save) para conferir o mapeamento.

local I = {}
local IOLog = require("iolog")

-- Numeração medida neste aparelho, injetando eventos no /dev/input/event1 e lendo
-- o que o LÖVE recebeu (ver README): A(304)=1, B(305)=2, X(307)=3, Y(308)=4,
-- L1(310)=5, R1(311)=6, L2(312)=7, R2(313)=8, D-pad 9..12, SELECT(704)=13,
-- START(705)=14. O LÖVE é 1-based; BTN_BASE=0 vale para esta tabela.
I.BTN_BASE = 0
I.RAW = {a = 1, b = 2, x = 3, y = 4, l1 = 5, r1 = 6, l2 = 7, r2 = 8,
         up = 9, down = 10, left = 11, right = 12, select = 13, start = 14, l3 = 15}
-- nomes do SDL GameController -> nomes abstratos (o SDL deste controle não mapeia
-- SELECT/START: esses dois caem no caminho bruto mesmo no modo gamepad)
I.GP = {a = "a", b = "b", x = "x", y = "y", leftshoulder = "l1", rightshoulder = "r1",
        dpup = "up", dpdown = "down", dpleft = "left", dpright = "right",
        leftstick = "l3", guide = "select"}
-- nomes que o gamepad do SDL não entrega e precisam do número bruto
I.RAW_FALLBACK = {select = true, start = true, l3 = true}
I.KEYS = {space = "a", z = "b", lshift = "b", q = "x", e = "y", c = "l1", x = "r1",
          v = "l2", b = "r2", up = "up", down = "down", left = "left", right = "right",
          ["return"] = "start", escape = "start", backspace = "select", f3 = "up", tab = "l3"}
I.DEAD = 0.22
I.mode = "nenhum"   -- "gamepad" | "bruto" | "nenhum"
I.force = nil        -- "gamepad" | "bruto" (config.txt)

local rawName = {}
local function rebuildRaw()
  rawName = {}
  for n, i in pairs(I.RAW) do rawName[i + I.BTN_BASE] = n end
end
rebuildRaw()

I.pressed = {}
I.last = {}          -- últimos eventos (para a tela de teste)
local logLines = 0
local trigState = {l2 = false, r2 = false}

local function log(s)
  if logLines > 3000 then return end
  logLines = logLines + 1
  IOLog.append("input.log", string.format("%.3f %s\n", love.timer.getTime(), s))
end
I.log = log

local function remember(s)
  table.insert(I.last, 1, s)
  if #I.last > 10 then I.last[11] = nil end
end

local function press(name, src)
  if not name then return end
  I.pressed[name] = true
  if I.onPress then I.onPress(name, src) end
end

function I.setBase(b) I.BTN_BASE = b; rebuildRaw() end

function I.pick()
  I.joy = nil
  for _, j in ipairs(love.joystick.getJoysticks()) do
    if j:getAxisCount() >= 2 or j:getButtonCount() >= 8 then I.joy = j; break end
  end
  if not I.joy then I.mode = "nenhum"; return end
  if I.force then I.mode = I.force
  else I.mode = I.joy:isGamepad() and "gamepad" or "bruto" end
  log(string.format("modo=%s base=%d", I.mode, I.BTN_BASE))
end

function I.joystickadded(j)
  local ok, guid = pcall(j.getGUID, j)
  log(string.format("joystick add nome=%q guid=%s gamepad=%s botoes=%d eixos=%d hats=%d",
    j:getName(), tostring(guid), tostring(j:isGamepad()), j:getButtonCount(), j:getAxisCount(), j:getHatCount()))
  if j:isGamepad() then
    for _, b in ipairs({"a", "b", "x", "y", "leftshoulder", "rightshoulder", "dpup", "start", "back"}) do
      local t, i, h = j:getGamepadMapping(b)
      log(string.format("  map %s -> %s %s %s", b, tostring(t), tostring(i), tostring(h)))
    end
    for _, a in ipairs({"triggerleft", "triggerright", "leftx", "rightx"}) do
      local t, i = j:getGamepadMapping(a)
      log(string.format("  map %s -> %s %s", a, tostring(t), tostring(i)))
    end
  end
  I.pick()
end

function I.joystickremoved(j)
  log("joystick removido " .. j:getName())
  I.pick()
end

function I.joystickpressed(j, b)
  local name = rawName[b]
  log(string.format("bruto botao=%d -> %s (modo %s)", b, tostring(name), I.mode))
  if j ~= I.joy then return end
  if I.mode == "bruto" then
    remember(string.format("bruto %d = %s", b, tostring(name)))
    press(name, "bruto")
  elseif I.mode == "gamepad" then
    if name and I.RAW_FALLBACK[name] then
      remember(string.format("bruto %d = %s", b, tostring(name)))
      press(name, "gamepad+bruto")
    end
  end
end

function I.gamepadpressed(j, b)
  local name = I.GP[b]
  log(string.format("gamepad %s -> %s", b, tostring(name)))
  if I.mode == "gamepad" and j == I.joy then
    remember(string.format("sdl %s = %s", b, tostring(name)))
    press(name, "gamepad")
  end
end

function I.joystickaxis(j, axis, value)
  if math.abs(value) > 0.9 then log(string.format("eixo %d = %.2f", axis, value)) end
end

function I.keypressed(k)
  local name = I.KEYS[k]
  if name then press(name, "teclado") end
end

function I.isDown(name)
  local j = I.joy
  if j then
    if I.mode == "gamepad" then
      if name == "l2" then if j:getGamepadAxis("triggerleft") > 0.5 then return true end
      elseif name == "r2" then if j:getGamepadAxis("triggerright") > 0.5 then return true end
      else
        for sdl, n in pairs(I.GP) do
          if n == name and j:isGamepadDown(sdl) then return true end
        end
        if I.RAW_FALLBACK[name] then
          local ri = I.RAW[name]
          if ri and j:isDown(ri + I.BTN_BASE) then return true end
        end
      end
    elseif I.mode == "bruto" then
      local i = I.RAW[name]
      if i and j:isDown(i + I.BTN_BASE) then return true end
    end
  end
  for k, n in pairs(I.KEYS) do
    if n == name and love.keyboard.isDown(k) then return true end
  end
  return false
end

local function dead(x, y)
  local m = math.sqrt(x * x + y * y)
  if m < I.DEAD then return 0, 0 end
  local s = math.min(1, (m - I.DEAD) / (1 - I.DEAD)) / m
  return x * s, y * s
end

-- analógico esquerdo e direito, já com zona morta
function I.sticks()
  local lx, ly, rx, ry = 0, 0, 0, 0
  local j = I.joy
  if j then
    if I.mode == "gamepad" then
      lx, ly = j:getGamepadAxis("leftx"), j:getGamepadAxis("lefty")
      rx, ry = j:getGamepadAxis("rightx"), j:getGamepadAxis("righty")
    elseif I.mode == "bruto" then
      lx, ly = j:getAxis(1), j:getAxis(2)
      if j:getAxisCount() >= 4 then rx, ry = j:getAxis(3), j:getAxis(4) end
    end
  end
  lx, ly = dead(lx, ly)
  rx, ry = dead(rx, ry)
  local kb = love.keyboard.isDown
  if kb("a") then lx = -1 elseif kb("d") then lx = 1 end
  if kb("w") then ly = -1 elseif kb("s") then ly = 1 end
  if kb("j") then rx = -1 elseif kb("l") then rx = 1 end
  if kb("i") then ry = -1 elseif kb("k") then ry = 1 end
  return lx, ly, rx, ry
end

-- gatilhos analógicos viram "apertou" ao cruzar a metade
function I.update()
  local j = I.joy
  if j and I.mode == "gamepad" then
    for name, ax in pairs({l2 = "triggerleft", r2 = "triggerright"}) do
      local d = j:getGamepadAxis(ax) > 0.5
      if d and not trigState[name] then
        log("gatilho " .. ax .. " -> " .. name)
        remember("sdl " .. ax .. " = " .. name)
        press(name, "gamepad")
      end
      trigState[name] = d
    end
  end
end

function I.endFrame()
  for k in pairs(I.pressed) do I.pressed[k] = nil end
end

return I
