-- Worker: gera chunks e monta malhas fora da thread principal. O runtime deste
-- aparelho entrega o LuaJIT sem JIT (ligar o JIT provoca segfault), então o
-- trabalho pesado precisa sair da thread que desenha.
jit.off()

local G = require("gen")
local M = require("mesher")

local work = love.thread.getChannel("cz-work")
local urgent = love.thread.getChannel("cz-urgent")
local done = love.thread.getChannel("cz-done")

while true do
  local job
  if urgent:getCount() > 0 then
    job = urgent:pop()
  elseif work:getCount() > 0 then
    job = work:pop()
  else
    job = work:demand()
  end
  if job == "quit" then break end
  if job.kind == "gen" then
    local bd, maxY = G.generate(job.cx, job.cz)
    done:push({kind = "gen", cx = job.cx, cz = job.cz, data = bd, maxY = maxY, epoch = job.epoch})
  elseif job.kind == "mesh" then
    local op, no, tr, nt = M.buildFrom(job.data, job.sec, job.ao)
    done:push({kind = "mesh", cx = job.cx, cz = job.cz, sec = job.sec, version = job.version,
      opaque = op, no = no, trans = tr, nt = nt, epoch = job.epoch, urgent = job.urgent})
  elseif job.kind == "setup" then
    G.setSeed(job.seed)
  end
end
