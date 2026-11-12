#!/bin/bash
# Atalho do menu Ports: abre o Camada Zero com o EmulationStation parado (ver camadazero-console.sh).
sudo systemd-run --unit=camadazero --collect /usr/local/bin/camadazero-console.sh
