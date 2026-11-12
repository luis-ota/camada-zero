-- Escrita em segundo plano: love.filesystem.write/append bloqueia a thread
-- principal por centenas de ms neste cartão. O worker usa io puro e o jogo
-- segue rodando; no quit esperamos a fila esvaziar.
local chOut = love.thread.getChannel("cz-io-out")
local chIn = love.thread.getChannel("cz-io-in")

while true do
  local job = chOut:demand()
  if job == "quit" then break end
  local ok, err = true, nil
  local f, e = io.open(job.path, job.mode == "a" and "ab" or "wb")
  if f then
    f:write(job.data)
    f:close()
    if job.tmp then
      local r, re = os.rename(job.path, job.path:gsub("%.tmp$", ""))
      if not r then ok, err = false, re end
    end
  else
    ok, err = false, e
  end
  chIn:push({id = job.id, ok = ok, err = err})
end
