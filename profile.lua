-- Instrumentação simples: mede trechos e grava os que passam do limite em profile.log.
local IOLog = require("iolog")
local PR = {on = false, threshold = 0.015, t0 = 0}

function PR.begin() PR.t0 = love.timer.getTime() end

function PR.finish(name, extra)
  if not PR.on then return end
  local dt = love.timer.getTime() - PR.t0
  if dt >= PR.threshold then
    IOLog.append("profile.log", string.format("%.2f %-10s %6.1fms %s\n",
      love.timer.getTime(), name, dt * 1000, extra or ""))
  end
end

function PR.span(name, fn, extra)
  if not PR.on then return fn() end
  local t = love.timer.getTime()
  local r = fn()
  local dt = love.timer.getTime() - t
  if dt >= PR.threshold then
    IOLog.append("profile.log", string.format("%.2f %-10s %6.1fms %s\n",
      love.timer.getTime(), name, dt * 1000, extra or ""))
  end
  return r
end

return PR
