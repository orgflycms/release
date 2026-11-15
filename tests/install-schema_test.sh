#!/bin/sh
# Только предварительная проверка: main и команды установки не запускаются.
set -eu
script=${1:-./install.sh}
eval "$(sed '$d' "$script")"
report='schema_conflict: база магазина на версии схемы 9; сначала FLYCMS_VERSION=v0.2.0'
code=0
out=$(check_schema 2>&1) || code=$?
if [ "$code" != 1 ]; then
	printf 'FAIL: старая схема не остановила обновление: %s %s\n' "$code" "$out"
	exit 1
fi
case "$out" in *'FLYCMS_VERSION=v0.2.0'*) ;; *) echo 'FAIL: нет инструкции'; exit 1 ;; esac
case "$out" in *'продолжает работать на прежней версии'*) ;; *) echo 'FAIL: нет состояния магазина'; exit 1 ;; esac
report='schema: 20'
[ -z "$(check_schema)" ] || { echo 'FAIL: совместимая схема отклонена'; exit 1; }
report='status: valid'
[ -z "$(check_schema)" ] || { echo 'FAIL: старый бинарник без проверки схемы отклонён'; exit 1; }
echo 'ok: несовместимая схема останавливает обновление до остановки службы'
