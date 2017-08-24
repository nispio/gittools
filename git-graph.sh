#!/bin/bash
set -euo pipefail

graph="log --graph --color --format='%C(yellow)%h%Creset %Cgreen%ae:%Creset %s'"
eval "git $graph" | sed 's/@[^ ]*://' | less -xFR
