#!/bin/sh
# Проверка на подставных командах: кластеры и службу тест не меняет.
set -eu
script=${1:-./postgres-upgrade.sh}
work=$(mktemp -d /var/tmp/flycms-pg-test-XXXX)
printf 'Журналы теста: %s\n' "$work"

# Только участок переноса: подготовку пакетов и настоящий main не запускаем.
transfer=$(sed -n '/^	say "Останавливаю магазин и переношу базу:/,/^	stopped=false/p' "$script")
[ -n "$transfer" ] || { echo 'FAIL: участок переноса не найден'; exit 1; }
(
	pg=18 old=16 name=review_w6_nonexistent port=5432
	stopped=false moving=false
	say() { :; }
	die() { printf 'FAIL: %s\n' "$1"; exit 1; }
	systemctl() { :; }
	# Заказ появился перед остановкой: в работающем магазине было 10 строк,
	# после остановки и переноса — 11. Их нужно сравнить с одним снимком.
	shop_rows() { if [ "$stopped" = true ]; then echo 11; else echo 10; fi; }
	pg_upgradecluster() { :; }
	cluster_state() { echo '5432 online'; }
	shop_postgres() { echo 180003; }
	shop_started() { :; }
	eval "$transfer"
)
echo 'ok: строки считаются после остановки магазина'

# Служба могла принять заказ на новом кластере и упасть до проверки
# готовности. Откат обязан сохранить этот кластер для восстановления заказа.
restore=$(sed -n '/^restore_cluster() {/,/^}/p' "$script")
(
	pg=18 old=16 name=review_w6_nonexistent port=5432
	destroyed=false new_stopped=false manual=false
	warn() { :; }
	systemctl() { :; }
	cluster_exists() { return 0; }
	pg_dropcluster() { destroyed=true; }
	pg_ctlcluster() { if [ "$1:$3" = '18:stop' ]; then new_stopped=true; fi; }
	pg_conftool() { :; }
	install() { [ "$(cat "$work/new-start.conf")" = manual ]; manual=true; }
	eval "$restore"
	restore_cluster
	if [ "$destroyed" != false ] || [ "$new_stopped" != true ] || [ "$manual" != true ]; then
		echo 'FAIL: откат уничтожает новый кластер или оставляет его автозапуск'
		exit 1
	fi
)
echo 'ok: откат сохраняет новый кластер и отключает его автозапуск'

for failure in stop autostart; do
	(
		pg=18 old=16 name=review_w6_nonexistent port=5432
		old_started=false
		warn() { :; }
		systemctl() { :; }
		cluster_exists() { return 0; }
		cluster_state() { echo '5432 online'; }
		pg_dropcluster() { echo 'FAIL: неожиданный вызов удаления'; exit 1; }
		pg_ctlcluster() {
			if [ "$1:$3:$failure" = '18:stop:stop' ]; then return 1; fi
			if [ "$1:$3" = '16:start' ]; then old_started=true; fi
		}
		pg_conftool() { :; }
		install() { [ "$failure" != autostart ]; }
		eval "$restore"
		code=0
		restore_cluster || code=$?
		if [ "$code" = 0 ] || [ "$old_started" != false ]; then
			echo "FAIL: небезопасный откат после ошибки $failure"
			exit 1
		fi
	)
done
echo 'ok: при ошибке остановки или автозапуска новый кластер не подменяется прежним'

(
	pg=18 old=16 name=review_w6_nonexistent port=5432
	old_started=false
	warn() { :; }
	systemctl() { :; }
	cluster_exists() { return 0; }
	cluster_state() { echo '5432 down'; }
	pg_dropcluster() { echo 'FAIL: неожиданный вызов удаления'; exit 1; }
	pg_ctlcluster() {
		if [ "$1:$3" = '18:stop' ]; then return 2; fi
		if [ "$1:$3" = '16:start' ]; then old_started=true; fi
	}
	pg_conftool() { :; }
	install() { :; }
	eval "$restore"
	restore_cluster
	[ "$old_started" = true ] || { echo 'FAIL: уже остановленный новый кластер помешал возврату'; exit 1; }
)
echo 'ok: уже остановленный новый кластер не мешает возврату'
