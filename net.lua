-- Lado principal da fila de trabalho: despacha geração/malha e adota resultados.
-- Limita quantos jobs ficam em voo para o worker não acumular atraso.

local W = require("world")
local M = require("mesher")

local Net = {enabled = false, epoch = 0, genN = 0, meshN = 0,
  inflightGen = {}, inflightMesh = {}, maxGen = 2, maxMesh = 3}

function Net.init(atlas)
  Net.atlas = atlas
  Net.work = love.thread.getChannel("cz-work")
  Net.urgent = love.thread.getChannel("cz-urgent")
  Net.done = love.thread.getChannel("cz-done")
  local ok, err = pcall(function()
    Net.thread = love.thread.newThread("meshworker.lua")
    Net.thread:start()
  end)
  Net.enabled = ok
  if not ok then Net.error = tostring(err) end
  Net.reset(W.seed)
  return ok
end

function Net.reset(seed)
  if not Net.work then return end
  Net.epoch = Net.epoch + 1
  Net.work:clear()
  Net.urgent:clear()
  Net.done:clear()
  Net.inflightGen, Net.inflightMesh = {}, {}
  Net.genN, Net.meshN = 0, 0
  Net.work:push({kind = "setup", seed = seed, epoch = Net.epoch})
end

function Net.dispatchGen(cx, cz)
  if not Net.enabled or Net.genN >= Net.maxGen then return false end
  local k = W.key(cx, cz)
  if Net.inflightGen[k] or W.getChunk(cx, cz) then return false end
  Net.inflightGen[k] = true
  Net.genN = Net.genN + 1
  Net.work:push({kind = "gen", cx = cx, cz = cz, epoch = Net.epoch})
  return true
end

function Net.dispatchMesh(c, sec, isUrgent)
  if not Net.enabled then return false end
  local s0 = c.sections[sec]
  if s0.empty and not isUrgent then
    s0.dirty = false
    return false
  end
  local k = W.key(c.cx, c.cz) * 4 + sec
  if Net.inflightMesh[k] then return false end
  if not isUrgent and Net.meshN >= Net.maxMesh then return false end
  local nb = {}
  local i = 1
  for dz = -1, 1 do
    for dx = -1, 1 do
      local n = W.getChunk(c.cx + dx, c.cz + dz)
      if not n then return false end
      nb[i] = n.bd
      i = i + 1
    end
  end
  local s = c.sections[sec]
  Net.inflightMesh[k] = true
  Net.meshN = Net.meshN + 1
  local ch = isUrgent and Net.urgent or Net.work
  ch:push({kind = "mesh", cx = c.cx, cz = c.cz, sec = sec, version = s.version,
    ao = M.ao, data = nb, epoch = Net.epoch, urgent = isUrgent})
  return true
end

local function setMeshes(s, opaque, no, trans, nt)
  W.dropMesh(s.mesh)
  W.dropMesh(s.tmesh)
  s.mesh = M.makeMesh(opaque, no, Net.atlas)
  s.tmesh = M.makeMesh(trans, nt, Net.atlas)
  s.faces = no + nt
  s.dirty, s.urgent = false, false
end

function Net.pump(maxResults)
  if not Net.enabled then return 0 end
  local n = 0
  while Net.done:getCount() > 0 and n < (maxResults or 4) do
    local r = Net.done:pop()
    n = n + 1
    if r.kind == "gen" then
      local k = W.key(r.cx, r.cz)
      if Net.inflightGen[k] then Net.inflightGen[k] = nil; Net.genN = Net.genN - 1 end
      -- resultado de uma seed antiga cai fora
      if r.epoch == Net.epoch and not W.getChunk(r.cx, r.cz) then
        W.adopt(r.cx, r.cz, r.data, r.maxY)
      end
    elseif r.kind == "mesh" then
      local k = W.key(r.cx, r.cz) * 4 + r.sec
      if Net.inflightMesh[k] then Net.inflightMesh[k] = nil; Net.meshN = Net.meshN - 1 end
      local c = W.getChunk(r.cx, r.cz)
      local s = c and c.sections[r.sec]
      if r.epoch == Net.epoch and s and s.version == r.version then
        setMeshes(s, r.opaque, r.no, r.trans, r.nt)
      end
    end
  end
  return n
end

-- modo síncrono (sem threads): usado só se o worker falhar
function Net.buildSync(c, sec)
  local s0 = c.sections[sec]
  if s0.empty then
    W.dropMesh(s0.mesh); W.dropMesh(s0.tmesh)
    s0.mesh, s0.tmesh, s0.faces = nil, nil, 0
    s0.dirty, s0.urgent = false, false
    return
  end
  local nb = {}
  local i = 1
  for dz = -1, 1 do
    for dx = -1, 1 do
      local n = W.getChunk(c.cx + dx, c.cz + dz)
      nb[i] = n and n.bd
      i = i + 1
    end
  end
  local op, no, tr, nt = M.buildFrom(nb, sec, M.ao)
  setMeshes(c.sections[sec], op, no, tr, nt)
end

return Net
