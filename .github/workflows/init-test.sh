#!/usr/bin/env bash
set -euo pipefail

printf 'DEFINE QLOCAL(INIT.TEST.QUEUE)\nend\n' | runmqsc QM1
