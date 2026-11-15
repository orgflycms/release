#!/bin/sh
# flycms — обновление Postgres стандартной установки до версии, которую ставит
# install.sh:
# curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/postgres-upgrade.sh | sudo sh
# Магазин на время переноса остановлен. Прежний кластер не удаляется: при
# любой неудаче магазин возвращается на него.
# Вызов main стоит последним: оборванный конвейер не выполнит часть работы.

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m  %s\033[0m\n' "$1" >&2; }
die() { warn "Ошибка: $1"; exit 1; }

# До какой версии обновляем. Та же константа — pg в install.sh; менять парой.
pg=18

env_value() {
	# Не исполняем файл от root: DSN с амперсандом тоже остаётся строкой.
	awk -v key="$2" -v fallback="$3" '
		$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
			value = $0
			sub(/^[^=]*=[[:space:]]*/, "", value)
			sub(/[[:space:]]*$/, "", value)
			quote = substr(value, 1, 1)
			if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote)
				value = substr(value, 2, length(value) - 2)
			found = 1
		}
		END { if (found) print value; else print fallback }
	' "$1"
}

supported_system() {
	case "$1:$2:$3" in
	debian:12:bookworm | debian:13:trixie | ubuntu:22.04:jammy | ubuntu:24.04:noble) return 0 ;;
	*) return 1 ;;
	esac
}

# Строка pg_lsclusters: версия, имя, порт, состояние, владелец, папка данных.
cluster_on_port() { pg_lsclusters -h | awk -v port="$1" '$3 == port'; }
cluster_exists() { pg_lsclusters -h | awk -v ver="$1" -v name="$2" '$1 == ver && $2 == name { found = 1 } END { exit !found }'; }
cluster_state() { pg_lsclusters -h | awk -v ver="$1" -v name="$2" '$1 == ver && $2 == name { print $3, $4 }'; }

# Версия сервера, на котором сейчас база магазина, глазами самого магазина.
shop_postgres() { runuser -u "$user" -- psql -X -w --dbname="$dsn" -Atc 'SHOW server_version_num' 2>/dev/null; }

# Сколько строк в таблицах магазина: сверяем до и после переноса. Счёт точный
# — магазин остановлен, а статистики у нового кластера ещё нет.
shop_rows() {
	runuser -u "$user" -- psql -X -w --dbname="$dsn" -Atc "SELECT coalesce(sum((xpath('/row/n/text()',
		query_to_xml(format('SELECT count(*) AS n FROM %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint), 0)
		FROM pg_tables WHERE schemaname = current_schema()" 2>/dev/null
}

configure_pgdg() {
	. /etc/os-release
	supported_system "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" ||
		die "Postgres $pg ставится сам только на Debian 12/13 и Ubuntu 22.04/24.04; поставьте пакет postgresql-$pg и повторите"
	key=/usr/share/keyrings/flycms-pgdg.asc
	source=/etc/apt/sources.list.d/flycms-pgdg.list
	[ ! -L "$source" ] && [ ! -L "$key" ] || die "путь PGDG оказался символической ссылкой"
	apt-get install -y -qq ca-certificates >/dev/null || die "не поставить ca-certificates"
	curl -fsSL -o "$work/pgdg.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc || die "не скачать ключ PGDG"
	install -o root -g root -m 644 "$work/pgdg.asc" "$key"
	printf 'deb [signed-by=%s] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$key" "$VERSION_CODENAME" >"$source"
	chmod 644 "$source"
	if ! apt-get update -qq; then
		printf '# PGDG отключён: apt-get update завершился ошибкой.\n' >"$source"
		die "apt не принял PGDG; источник $source отключён"
	fi
}

# Служба магазина поднялась: её процесс слушает порт. Слушать он начинает
# после входа в базу и миграций, поэтому отдельный запрос по HTTP не нужен.
shop_started() {
	base=$(systemctl show --property=NRestarts --value flycms 2>/dev/null) || base=0
	systemctl start flycms || return 1
	deadline=$(($(date +%s) + 120))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if systemctl is-failed --quiet flycms; then return 1; fi
		now=$(systemctl show --property=NRestarts --value flycms 2>/dev/null) || now=$base
		[ "$now" = "$base" ] || return 1
		pid=$(systemctl show --property=MainPID --value flycms 2>/dev/null) || pid=0
		case "$pid" in '' | 0 | *[!0-9]*) ;; *)
			if ss -Hltnp 2>/dev/null | grep -Fq "pid=$pid,"; then return 0; fi ;;
		esac
		sleep 1
	done
	return 1
}

# Возврат на прежний кластер: новый, созданный этим запуском, удаляется,
# прежнему возвращаются порт и автозапуск. Сам pg_upgradecluster прежние
# данные не меняет — только переводит кластер на другой порт и в ручной запуск.
restore_cluster() {
	warn "Возвращаю магазин на прежний кластер Postgres $old/$name."
	systemctl stop flycms 2>/dev/null || true
	if cluster_exists "$pg" "$name"; then
		pg_dropcluster --stop "$pg" "$name" || warn "Новый кластер $pg/$name не удалён: pg_dropcluster --stop $pg $name"
	fi
	pg_ctlcluster "$old" "$name" stop >/dev/null 2>&1 || true
	pg_conftool "$old" "$name" set port "$port" || warn "Порт $port прежнему кластеру не возвращён."
	if [ -f "$work/start.conf" ]; then
		install -o postgres -g postgres -m 644 "$work/start.conf" "/etc/postgresql/$old/$name/start.conf" ||
			warn "Автозапуск прежнего кластера не возвращён: /etc/postgresql/$old/$name/start.conf"
	fi
	# systemd читает start.conf при своей перечитке — как и после pg_upgradecluster.
	systemctl daemon-reload || true
	pg_ctlcluster "$old" "$name" start || warn "Прежний кластер не запустился: pg_lsclusters, journalctl -u postgresql@$old-$name"
}

finish() {
	result=$?
	trap - 0
	trap '' HUP INT TERM
	if [ "$result" != 0 ] && [ "$moving" = true ]; then
		restore_cluster
		if [ "$(shop_postgres)" = "$found" ] && shop_started; then
			warn "Магазин работает на прежнем Postgres $old. Данные не изменены."
		else
			warn "Магазин на прежнем кластере не запустился. Проверьте pg_lsclusters и journalctl -u flycms -n 50 --no-pager."
		fi
	elif [ "$result" != 0 ] && [ "$stopped" = true ]; then
		systemctl start flycms || warn "Не удалось снова запустить магазин: systemctl start flycms"
	fi
	exit "$result"
}

main() {
	set -eu
	umask 022
	envfile=/etc/flycms.env
	user=flycms
	port=5432
	local_dsn="postgres:///$user?host=/run/postgresql&sslmode=disable"
	[ "$(id -u)" = 0 ] || die "нужны права root — запустите через sudo"
	[ -d /run/systemd/system ] || die "нужен systemd"
	[ -f "$envfile" ] || die "нет $envfile — магазин на этом сервере не установлен"
	for command in curl apt-get systemctl runuser psql ss pg_lsclusters pg_upgradecluster pg_dropcluster pg_ctlcluster pg_conftool; do
		command -v "$command" >/dev/null || die "не найдена команда $command"
	done
	dsn=$(env_value "$envfile" FLYCMS_DSN "$local_dsn")
	[ "$dsn" = "$local_dsn" ] ||
		die "в FLYCMS_DSN своя база: этот скрипт обновляет только стандартную установку. Обновите сервер базы средствами его хозяина"

	set -- $(cluster_on_port "$port")
	[ $# -ge 6 ] || die "на порту $port нет кластера Postgres из пакетов (pg_lsclusters)"
	old=$1 name=$2 state=$4 data=$6
	case "$old" in '' | *[!0-9]*) die "версия кластера «$old» — не число; обновите Postgres вручную" ;; esac
	if [ "$old" -ge "$pg" ]; then
		say "Postgres уже $old — обновлять нечего."
		return 0
	fi
	[ "$state" = online ] || die "кластер $old/$name не запущен (состояние $state)"
	found=$(shop_postgres) || die "не войти в базу магазина: проверьте FLYCMS_DSN в $envfile"
	[ "$((found / 10000))" = "$old" ] || die "магазин ходит не в кластер $old/$name на порту $port"
	! cluster_exists "$pg" "$name" || die "кластер $pg/$name уже существует; перенос в него — вручную, см. docs/update.md"
	had_main=false
	! cluster_exists "$pg" main || had_main=true
	need=$(du -sk "$data" | awk '{print $1}')
	free=$(df -Pk "${data%/*/*}" | awk 'NR == 2 {print $4}')
	[ "$free" -gt "$need" ] || die "недостаточно места для второго кластера: свободно $free КиБ, прежний занимает $need КиБ"

	work=$(mktemp -d /var/tmp/flycms-postgres-XXXX) || die "не создать временную папку"
	stopped=false
	moving=false
	trap finish 0
	trap 'exit 1' HUP INT TERM
	trap '' HUP

	if [ ! -x "/usr/lib/postgresql/$pg/bin/postgres" ]; then
		say "Ставлю пакет postgresql-$pg (магазин пока работает)"
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq || die "apt не обновил список пакетов"
		apt-cache show "postgresql-$pg" >/dev/null 2>&1 || configure_pgdg
		apt-get install -y -qq "postgresql-$pg" >/dev/null || die "пакет postgresql-$pg не поставился"
	fi
	# Старые postgresql-common вместе с пакетом создают пустой кластер main.
	# Он занял бы место переносимого — удаляем, но только созданный сейчас.
	if [ "$had_main" = false ] && cluster_exists "$pg" main; then
		pg_dropcluster --stop "$pg" main || die "не удалить пустой кластер $pg/main, созданный пакетом"
	fi

	say "Останавливаю магазин и переношу базу: Postgres $old → $pg"
	rows=$(shop_rows) || die "не посчитать строки в базе магазина"
	[ ! -f "/etc/postgresql/$old/$name/start.conf" ] || cp -p "/etc/postgresql/$old/$name/start.conf" "$work/start.conf"
	stopped=true
	systemctl stop flycms || die "не остановить службу магазина"
	moving=true
	pg_upgradecluster -v "$pg" "$old" "$name" >"$work/pg_upgradecluster.log" 2>&1 ||
		die "pg_upgradecluster завершился ошибкой; журнал: $work/pg_upgradecluster.log"

	say "Проверяю новый кластер"
	[ "$(cluster_state "$pg" "$name")" = "$port online" ] || die "кластер $pg/$name не запущен на порту $port"
	moved=$(shop_postgres) || die "магазин не входит в базу нового кластера"
	[ "$((moved / 10000))" = "$pg" ] || die "на порту $port отвечает Postgres $((moved / 10000)), а не $pg"
	[ "$(shop_rows)" = "$rows" ] || die "число строк в таблицах магазина после переноса другое (было $rows)"
	shop_started || die "магазин не запустился на Postgres $pg; journalctl -u flycms -n 50 --no-pager"
	moving=false
	stopped=false

	say "Готово. Магазин работает на Postgres $pg."
	printf '\n    Прежний кластер %s/%s остановлен и сохранён (порт %s, ручной запуск).\n' "$old" "$name" "$(cluster_state "$old" "$name" | awk '{print $1}')"
	printf '    Убедитесь, что магазин работает, и удалите его: pg_dropcluster %s %s\n' "$old" "$name"
	printf '    Журнал переноса: %s/pg_upgradecluster.log\n' "$work"
}

main "$@"
