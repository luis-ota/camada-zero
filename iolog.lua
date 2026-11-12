-- Fila de escrita em thread própria (ver iowriter.lua). Mantém buffers em
-- memória e descarrega a cada poucos segundos; no quit, espera esvaziar.

local IO = {pending = 0, done = 0, buf = {}, errors = {}}

local DIR

function IO.init()
  DIR = love.filesystem.getSaveDirectory()
  IO.outCh = love.thread.getChannel("cz-io-out")
  IO.inCh = love.thread.getChannel("cz-io-in")
  IO.thread = love.thread.newThread("iowriter.lua")
  IO.thread:start()
  IO.t0 = love.timer.getTime()
end

local function send(name, text, mode, tmp)
  if not DIR then return false end
  IO.pending = IO.pending + 1
  local path = DIR .. "/" .. name
  IO.outCh:push({path = tmp and (path .. ".tmp") or path, data = text, mode = mode,
    tmp = tmp, id = IO.pending})
  return true
end

-- grava o arquivo inteiro (save do mundo)
function IO.writeFile(name, text)
  return send(name, text, "w", true)
end

-- acumula e descarrega depois (logs)
function IO.append(name, text)
  local b = (IO.buf[name] or "") .. text
  if #b > 8192 then
    send(name, b, "a", false)
    IO.buf[name] = ""
  else
    IO.buf[name] = b
  end
end

function IO.flushLogs()
  for name, b in pairs(IO.buf) do
    if #b > 0 then send(name, b, "a", false); IO.buf[name] = "" end
  end
end

function IO.drain()
  while IO.inCh:getCount() > 0 do
    local r = IO.inCh:pop()
    IO.done = IO.done + 1
    if not r.ok then
      IO.errors[#IO.errors + 1] = tostring(r.err)
      if #IO.errors > 5 then table.remove(IO.errors, 1) end
    end
  end
end

function IO.update()
  IO.drain()
  if love.timer.getTime() - IO.t0 > 4 then
    IO.t0 = love.timer.getTime()
    IO.flushLogs()
  end
end

-- no quit: manda tudo e espera (a escrita real leva ~10 ms)
function IO.close(timeout)
  IO.flushLogs()
  local limit = love.timer.getTime() + (timeout or 5)
  while IO.done < IO.pending and love.timer.getTime() < limit do
    love.timer.sleep(0.01)
    IO.drain()
  end
  IO.outCh:push("quit")
  return IO.done >= IO.pending
end

return IO
