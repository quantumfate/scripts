#!/bin/bash

# Environment variables
export __GL_SHADER_DISK_CACHE="1"
export __GL_SHADER_DISK_CACHE_PATH="/home/quantum/Games/ankama-launcher"
export LD_LIBRARY_PATH="/usr/lib:/usr/lib32:/usr/lib/libfakeroot:/usr/lib64:/home/quantum/.local/share/lutris/runtime/Ubuntu-18.04-i686:/home/quantum/.local/share/lutris/runtime/steam/i386/lib/i386-linux-gnu:/home/quantum/.local/share/lutris/runtime/steam/i386/lib:/home/quantum/.local/share/lutris/runtime/steam/i386/usr/lib/i386-linux-gnu:/home/quantum/.local/share/lutris/runtime/steam/i386/usr/lib:/home/quantum/.local/share/lutris/runtime/Ubuntu-18.04-x86_64:/home/quantum/.local/share/lutris/runtime/steam/amd64/lib/x86_64-linux-gnu:/home/quantum/.local/share/lutris/runtime/steam/amd64/lib:/home/quantum/.local/share/lutris/runtime/steam/amd64/usr/lib/x86_64-linux-gnu:/home/quantum/.local/share/lutris/runtime/steam/amd64/usr/lib"
export TERM="xterm"

# Working Directory
cd /home/quantum/Games/ankama-launcher

# Command
gamemoderun game-performance ./AnkamaLauncher64.AppImage
