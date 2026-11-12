-- Sons gerados por código (nada baixado). Se o áudio não abrir, fica mudo.

local S = {enabled = false, src = {}}

local RATE = 22050

local function make(len, fn)
  local n = math.floor(len * RATE)
  local sd = love.sound.newSoundData(n, RATE, 16, 1)
  for i = 0, n - 1 do
    local v = fn(i / RATE, i / n)
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    sd:setSample(i, v)
  end
  return sd
end

function S.init()
  if not love.audio then return end
  local ok = pcall(function()
    local rng = love.math.newRandomGenerator(99)
    local lp = 0
    -- quebrar: ruído grave abafado, decaimento rápido
    local brk = make(0.16, function(t, f)
      local nz = rng:random() * 2 - 1
      lp = lp + (nz - lp) * 0.18
      return lp * 1.6 * math.exp(-f * 5)
    end)
    lp = 0
    -- colocar: batida curta (seno descendente + clique)
    local plc = make(0.08, function(t, f)
      local s = math.sin(2 * math.pi * (220 - 120 * f) * t)
      local click = (t < 0.004) and (rng:random() * 2 - 1) * 0.6 or 0
      return (s * 0.7 + click) * (1 - f) ^ 2
    end)
    -- menu: bipe quadrado curto
    local blip = make(0.05, function(t, f)
      local s = (math.sin(2 * math.pi * 880 * t) > 0) and 0.25 or -0.25
      return s * (1 - f)
    end)
    S.src.break_ = love.audio.newSource(brk, "static")
    S.src.place = love.audio.newSource(plc, "static")
    S.src.blip = love.audio.newSource(blip, "static")
    S.src.blip:setVolume(0.5)
  end)
  S.enabled = ok
end

function S.play(name)
  if not S.enabled then return end
  local s = S.src[name]
  if s then s:stop(); s:play() end
end

return S
