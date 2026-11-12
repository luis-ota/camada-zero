function love.conf(t)
  t.identity = "camadazero"
  t.version = "11.5"
  t.window.title = "Camada Zero"
  t.window.width = 640
  t.window.height = 480
  t.window.depth = 24          -- buffer de profundidade da tela (3D)
  t.window.vsync = 1
  t.modules.physics = false
  t.modules.video = false
  t.modules.touch = false
  t.modules.joystick = true
end
