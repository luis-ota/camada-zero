#!/bin/bash
# Roda o Camada Zero fora do EmulationStation (mesmo padrão do voxel-console.sh):
# com o menu vivo, os dois disputam o display e a tela pisca.
# Executado como root via systemd-run (ver CamadaZero.sh). Nunca para o ES com jogo aberto.
L=/opt/system/Tools/PortMaster/runtimes/love_11.5
G=/mnt/jogos/camadazero

BLOQUEIO=""
for p in drastic retroarch mupen64plus ppsspp love.aarch64; do
  if pgrep -x "$p" >/dev/null; then BLOQUEIO="$BLOQUEIO $p"; fi
done
if [ -n "$BLOQUEIO" ]; then
  echo "$(date +%T) saida: jogo aberto:$BLOQUEIO" >> /tmp/cz-launch.log
  exit 0
fi
echo "$(date +%T) inicio pid=$$" >> /tmp/cz-launch.log

# avisa o r36s-idle que tem app no ar: sem isso, um toque no controle faz ele
# subir o EmulationStation por cima do jogo
touch /tmp/r36s-console.lock
trap 'rm -f /tmp/r36s-console.lock' EXIT

mkdir -p /run/user/1002 && chown ark:ark /run/user/1002 && chmod 700 /run/user/1002
chmod 666 /dev/tty0 /dev/tty1 /dev/input/event1 2>/dev/null

systemctl stop emulationstation
sleep 2
printf "\033c" > /dev/tty1

sudo -u ark env LD_LIBRARY_PATH="$L/libs.aarch64" XDG_RUNTIME_DIR=/run/user/1002 SDL_AUDIODRIVER=alsa \
  "$L/love.aarch64" "$G" > /tmp/camadazero.log 2>&1
echo "$(date +%T) love saiu codigo=$?" >> /tmp/cz-launch.log

printf "\033c" > /dev/tty1
echo "$(date +%T) fim, subindo ES" >> /tmp/cz-launch.log
systemctl start emulationstation
# espera o menu subir antes de soltar a trava: sem isso o daemon de descanso
# pode parar o ES no meio da subida e entrar em slideshow
for i in $(seq 1 20); do
  systemctl is-active --quiet emulationstation && break
  sleep 1
done
