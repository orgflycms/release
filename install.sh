#!/bin/sh
# flycms — установка и обновление:
# curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/install.sh | sudo sh
# Вызов main стоит последним: оборванный конвейер не выполнит часть установки.

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m  %s\033[0m\n' "$1" >&2; }
die() { warn "Ошибка: $1"; exit 1; }

select_arch() {
	case "$1" in
	x86_64 | amd64) printf '%s\n' amd64 ;;
	aarch64 | arm64) printf '%s\n' arm64 ;;
	*) return 1 ;;
	esac
}

supported_system() {
	case "$1:$2:$3" in
	debian:12:bookworm | debian:13:trixie | ubuntu:22.04:jammy | ubuntu:24.04:noble) return 0 ;;
	*) return 1 ;;
	esac
}

checksum_for_asset() {
	# Разбираем только точное имя: чужие пути и повторные строки недопустимы.
	awk -v asset="$2" '
		$2 == asset || $2 == "*" asset {
			count++
			if (NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-fA-F]/) bad = 1
			hash = tolower($1)
		}
		END { if (count != 1 || bad) exit 1; print hash }
	' "$1"
}

verify_download() {
	expected=$(checksum_for_asset "$1" "$3") || return 1
	actual=$(sha256sum "$2") || return 1
	[ "${actual%% *}" = "$expected" ]
}

generate_token() {
	token=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
	[ "${#token}" = 32 ] || return 1
	case "$token" in *[!0-9a-f]*) return 1 ;; esac
	printf '%s\n' "$token"
}

env_has() { grep -Eq "^[[:space:]]*$2[[:space:]]*=" "$1"; }

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

ensure_env() {
	env_has "$1" "$2" || printf '\n%s=%s\n' "$2" "$3" >>"$1"
}

normalize_host() {
	case "$1" in '' | *[[:space:]]*) return 1 ;; esac
	value=$(printf '%s' "$1" | sed 's#^[^:]*://##;s#/*$##')
	[ -n "$value" ] || return 1
	printf '%s\n' "$value"
}

prepare_settings() {
	if [ ! -f "$envfile" ]; then
		host=$(normalize_host "${FLYCMS_HOST:-$(ask 'Домен или публичный IP магазина' "$guess")}") || die "в адресе не должно быть пробелов и переводов строк"
		install_token=$(generate_token) || die "не получить случайный код из /dev/urandom"
		(umask 077; printf 'FLYCMS_HOST=%s\nFLYCMS_INSTALL_TOKEN=%s\n' "$host" "$install_token" >"$envfile")
		[ "$tty_ok" = true ] || warn "Адрес можно изменить в FLYCMS_HOST в $envfile, затем — в настройках магазина."
	fi
	ensure_env "$envfile" FLYCMS_DSN "postgres:///$user?host=/run/postgresql&sslmode=disable"
	ensure_env "$envfile" FLYCMS_FILES "$dir/files"
	ensure_env "$envfile" FLYCMS_PLUGINS "$dir/plugins"
	ensure_env "$envfile" FLYCMS_MARKETPLACE https://flycms.ru/api/v1
	ensure_env "$envfile" FLYCMS_ADDR "${FLYCMS_ADDR:-:80}"
	ensure_env "$envfile" FLYCMS_TLS_ADDR "${FLYCMS_TLS_ADDR-:443}"
	host=$(env_value "$envfile" FLYCMS_HOST '')
	host=$(normalize_host "${host:-$guess}") || die "проверьте пробелы и переводы строк в FLYCMS_HOST"
}

print_install_link() {
	install_token=$(env_value "$envfile" FLYCMS_INSTALL_TOKEN '')
	[ -z "$install_token" ] || printf '\n    Установка: https://%s/install?token=%s\n    Если магазин уже настроен, эта ссылка не нужна.\n' "$host" "$install_token"
}

listen_url() {
	set -- "$1" "${2:-:80}"
	listen_host=${2%:*}
	listen_port=${2##*:}
	case "$listen_port" in '' | *[!0-9]*) return 1 ;; esac
	[ "$listen_port" -ge 1 ] && [ "$listen_port" -le 65535 ] || return 1
	case "$listen_host" in
	'' | 0.0.0.0) listen_host=127.0.0.1 ;;
	'[::]') listen_host='[::1]' ;;
	\[*\]) case "$listen_host" in *[!0-9a-fA-F:.\[\]]*) return 1 ;; esac ;;
	*:*) return 1 ;;
	*) case "$listen_host" in *[!a-zA-Z0-9._-]*) return 1 ;; esac ;;
	esac
	[ "$2" != "$listen_port" ] || return 1
	printf '%s://%s:%s\n' "$1" "$listen_host" "$listen_port"
}

expired_backups() {
	# Метка подтверждает происхождение пары; чужие и незавершённые копии не трогаем.
	for marker in "$1"/*.installer-backup; do
		[ -f "$marker" ] && [ ! -L "$marker" ] || continue
		stem=${marker##*/}
		stem=${stem%.installer-backup}
		printf '%s\n' "$stem" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9][A-Za-z0-9._+-]*$' || continue
		[ "$(cat "$marker")" = flycms-install-backup-v1 ] || continue
		[ -f "$1/$stem.sql.gz" ] && [ ! -L "$1/$stem.sql.gz" ] || continue
		[ -f "$1/$stem.flycms" ] && [ ! -L "$1/$stem.flycms" ] || continue
		printf '%s\n' "$stem"
	done | LC_ALL=C sort -r | awk 'NR > 5'
}

service_responds() {
	systemctl is-active --quiet flycms || return 1
	pid=$(systemctl show --property=MainPID --value flycms) || return 1
	case "$pid" in '' | 0 | *[!0-9]*) return 1 ;; esac
	# Одного ответа HTTP мало: на том же адресе может отвечать чужой nginx.
	listeners=$(ss -Hltnp "sport = :$health_port") || return 1
	printf '%s\n' "$listeners" | grep -Fq "pid=$pid," || return 1
	code=$(curl -sSk --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' "$health_url/") || return 1
	case "$code" in 200 | 301 | 302 | 303 | 307 | 308 | 401 | 403) return 0 ;; *) return 1 ;; esac
}

wait_ready() {
	deadline=$(($(date +%s) + 300))
	while [ "$(date +%s)" -lt "$deadline" ]; do
		if service_responds; then return 0; fi
		sleep 1
	done
	return 1
}

finish_install() {
	result=$?
	trap - 0
	trap '' HUP INT TERM
	rm -f -- "$bin.new" || warn "не удалось убрать $bin.new"
	if [ "$restore_needed" = true ] && ! systemctl is-active --quiet flycms; then
		warn "Новая версия не запустилась. Возвращаю прежний бинарник: $old_binary"
		if systemctl stop flycms && install -o root -g root -m 755 "$old_binary" "$bin" &&
			systemctl restart flycms && wait_ready; then
			warn "Прежний бинарник возвращён, служба отвечает."
		else
			warn "Прежнюю службу запустить не удалось. Проверьте journalctl -u flycms -n 50 --no-pager."
		fi
		warn "База автоматически НЕ восстановлена. Дамп до обновления: $dump"
		warn "Восстановление: https://github.com/orgflycms/release/blob/main/docs/update.md#восстановление-базы"
	elif [ "$restore_needed" = true ]; then
		warn "Служба активна: новый бинарник оставлен. Проверьте журнал. Копия базы: $dump"
	elif [ "$resume_needed" = true ]; then
		systemctl start flycms || warn "Не удалось снова запустить прежнюю службу."
	fi
	exit "$result"
}

backup_before_update() {
	old_version=$("$bin" -version) || die "прежний бинарник не сообщает версию"
	case "$old_version" in '' | *[!a-zA-Z0-9._+-]* | [!a-zA-Z0-9]*) old_version=unknown ;; esac
	stem="$(date -u +%Y%m%dT%H%M%SZ)-$old_version"
	dump="$dir/backup/$stem.sql.gz"
	old_binary="$dir/backup/$stem.flycms"
	for target in "$dump" "$old_binary" "$dir/backup/$stem.installer-backup"; do
		[ ! -e "$target" ] && [ ! -L "$target" ] || die "копия $stem уже существует — повторите позже"
	done
	needed=$(runuser -u "$user" -- psql -X -w --dbname="$dsn" -Atc 'SELECT pg_database_size(current_database()) / 1024') || die "не определить размер базы"
	available=$(df -Pk "$dir/backup" | awk 'NR == 2 {print $4}')
	[ "$available" -gt "$needed" ] || die "недостаточно места для копии: свободно $available КиБ, размер базы $needed КиБ"
	say "Сохраняю базу и прежний бинарник: $dir/backup/$stem"
	install -o root -g root -m 600 "$bin" "$old_binary"
	resume_needed=true
	systemctl stop flycms || die "не остановить службу перед копированием базы"
	# Сжатие делает сам pg_dump: один код возврата, без несжатого файла на диске.
	(umask 077; runuser -u "$user" -- pg_dump -w --no-owner --no-acl -Z 6 --dbname="$dsn" >"$dump") || die "pg_dump завершился ошибкой; бинарник не заменён"
	gzip -t "$dump" || die "резервная копия повреждена; бинарник не заменён"
	chmod 600 "$dump"
	printf '%s\n' flycms-install-backup-v1 >"$dir/backup/$stem.installer-backup"
	restore_needed=true
}

configure_pgdg() {
	curl -fsSL -o "$work/pgdg.asc" https://www.postgresql.org/media/keys/ACCC4CF8.asc || die "не скачать ключ PGDG"
	[ ! -L "$source" ] && [ ! -L "$key" ] || die "путь PGDG оказался символической ссылкой"
	install -o root -g root -m 644 "$work/pgdg.asc" "$key"
	printf 'deb [signed-by=%s] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$key" "$VERSION_CODENAME" >"$source"
	chmod 644 "$source"
	if ! apt-get update -qq; then
		printf '# PGDG отключён: apt-get update завершился ошибкой.\n' >"$source"
		die "apt не принял PGDG; источник $source отключён"
	fi
}

check_new_database() {
	# Наличие клиента не означает наличие подходящего локального сервера.
	present=$(runuser -u postgres -- psql -X -w -h /run/postgresql -p 5432 -d postgres -Atc \
		"SELECT EXISTS(SELECT FROM pg_roles WHERE rolname = 'flycms') OR EXISTS(SELECT FROM pg_database WHERE datname = 'flycms')") ||
		die "нужен локальный Postgres на /run/postgresql:5432 с входом peer для postgres; существующий сервер не перенастраивается"
	[ "$present" = f ] || die "роль или база flycms уже существует без $envfile; чужая база не будет использована"
}

check_database_connection() {
	runuser -u "$user" -- psql -X -w --dbname="$dsn" -Atc 'SELECT 1' >/dev/null || die "не войти в базу: проверьте FLYCMS_DSN в $envfile"
}

# Роли плагинов заводит сам движок (engine/internal/plugin/roles.go), и без
# CREATEROLE плагинам закрыта только база — магазин работает. Поэтому две
# функции ниже лишь предупреждают: ни установку, ни обновление они не
# останавливают.
grant_createrole() {
	role=$(runuser -u "$user" -- psql -X -w --dbname="$dsn" -Atc \
		"SELECT quote_ident(rolname) FROM pg_roles WHERE rolname = current_user AND NOT (rolcreaterole OR rolsuper)") ||
		{ warn "Не проверить право CREATEROLE у роли базы: плагины с доступом к базе могут не работать."; return 0; }
	[ -n "$role" ] || return 0
	if [ "$dsn" = "postgres:///$user?host=/run/postgresql&sslmode=disable" ]; then
		# До Postgres 16 CREATEROLE меняет любые несуперпользовательские роли
		# кластера — сами такое не выдаём. Версия не определилась — как старая.
		server=$(runuser -u postgres -- psql -X -w -h /run/postgresql -p 5432 -d postgres -Atc 'SHOW server_version_num') || server=0
		case "$server" in '' | *[!0-9]*) server=0 ;; esac
		if [ "$server" -lt 160000 ]; then
			warn "На этой версии Postgres право CREATEROLE позволяет менять чужие роли кластера, поэтому установщик его не выдаёт: плагины с доступом к базе работать не будут, остальной магазин работает."
			warn "Если сервер базы отдан только магазину, выдайте его вручную: su postgres -c \"psql -c 'ALTER ROLE $role CREATEROLE'\""
			return 0
		fi
		runuser -u postgres -- psql -X -w -h /run/postgresql -p 5432 -d postgres -qc "ALTER ROLE $role CREATEROLE" && return 0
	fi
	warn "Роли базы $role не хватает права CREATEROLE: плагины с доступом к базе работать не будут, остальной магазин работает."
	warn "Выдайте его от суперпользователя Postgres: ALTER ROLE $role CREATEROLE — до Postgres 16 только на отдельном сервере, см. docs/plugins.md."
}

check_plugin_login() {
	# Роли плагинов входят паролем по TCP на 127.0.0.1 того же порта; у PGDG
	# такая строка в pg_hba.conf стоит по умолчанию. Решает первая подходящая
	# строка, как в самом Postgres. Чужой конфиг не правим и прочитать его
	# можем только у локальной базы.
	[ "$dsn" = "postgres:///$user?host=/run/postgresql&sslmode=disable" ] || return 0
	method=$(runuser -u postgres -- psql -X -w -h /run/postgresql -p 5432 -d postgres -Atc "SELECT auth_method FROM pg_hba_file_rules
		WHERE error IS NULL AND type IN ('host', 'hostnossl', 'hostnogssenc') AND database && ARRAY['all', '$user'] AND user_name && ARRAY['all']
		AND CASE WHEN address IN ('all', 'samehost', 'samenet', 'localhost') THEN true
			WHEN address ~ '^[0-9.]+\$' AND netmask IS NOT NULL THEN ('127.0.0.1'::inet & netmask::inet) = (address::inet & netmask::inet)
			ELSE false END
		ORDER BY line_number LIMIT 1") || return 0
	case "$method" in scram-sha-256 | md5 | password | trust) return 0 ;; esac
	warn "pg_hba.conf не пускает вход по паролю на 127.0.0.1: плагины с доступом к базе не подключатся."
	warn "Нужна строка «host all all 127.0.0.1/32 scram-sha-256» выше запрещающих; установщик этот файл не меняет."
}

ensure_database() {
	state=$(runuser -u postgres -- psql -X -w -h /run/postgresql -p 5432 -d postgres -Atc \
		"SELECT EXISTS(SELECT FROM pg_roles WHERE rolname = 'flycms'), EXISTS(SELECT FROM pg_database WHERE datname = 'flycms')") || die "не войти в локальный Postgres от postgres через peer"
	case "$state" in f\|*) runuser -u postgres -- createuser -w -h /run/postgresql -p 5432 "$user" || die "не создать роль flycms" ;; esac
	case "$state" in *\|f) runuser -u postgres -- createdb -w -h /run/postgresql -p 5432 -O "$user" "$user" || die "не создать базу flycms" ;; esac
}

warn_busy_ports() {
	pid=$(systemctl show --property=MainPID --value flycms 2>/dev/null || printf 0)
	busy=$(ss -Hltnp 'sport = :80 or sport = :443' 2>/dev/null | grep -Fv "pid=${pid:-0}," || true)
	if [ -n "$busy" ]; then
		warn "80 или 443 заняты другим процессом. Для работы за nginx задайте FLYCMS_ADDR=127.0.0.1:8080 и FLYCMS_TLS_ADDR= в $envfile."
	fi
}

ask() {
	if [ "$tty_ok" != true ]; then printf '%s' "$2"; return; fi
	printf '\n%s [%s]: ' "$1" "$2" >/dev/tty
	read -r reply </dev/tty || reply=''
	printf '%s' "${reply:-$2}"
}

main() {
	set -eu
	umask 022
	repo=orgflycms/release
	dir=/opt/flycms
	bin=/usr/local/bin/flycms
	envfile=/etc/flycms.env
	unit=/etc/systemd/system/flycms.service
	user=flycms
	pg=18
	version=${FLYCMS_VERSION:-latest}
	[ "$(id -u)" = 0 ] || die "нужны права root — запустите через sudo"
	[ -d /run/systemd/system ] || die "нужен systemd"
	for command in curl apt-get systemctl runuser sha256sum od gzip; do
		command -v "$command" >/dev/null || die "не найдена команда $command"
	done
	arch=$(select_arch "$(uname -m)") || die "сборки есть только для amd64 и arm64"
	[ ! -L "$envfile" ] && [ ! -L "$bin" ] && [ ! -L "$bin.new" ] && [ ! -L "$unit" ] || die "путь установки оказался символической ссылкой"
	[ ! -e "$bin" ] || [ -f "$envfile" ] || die "есть бинарник без $envfile — проверьте прежнюю установку вручную"
	updating=false
	[ ! -f "$bin" ] || updating=true

	work=$(mktemp -d /var/tmp/flycms-install-XXXX) || die "не создать временную папку"
	resume_needed=false
	restore_needed=false
	trap finish_install 0
	trap 'exit 1' HUP INT TERM
	if [ "$updating" = true ]; then trap '' HUP; fi
	say "Временные файлы: $work (доступ только root)"

	# Привязываем все загрузки к одному тегу, даже если latest сменится в пути.
	if [ "$version" = latest ]; then
		latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest") || die "не определить последний релиз"
		version=${latest##*/}
	fi
	case "$version" in '' | latest | *[!a-zA-Z0-9._+-]* | [!a-zA-Z0-9]*) die "некорректный тег релиза" ;; esac
	release="https://github.com/$repo/releases/download/$version"
	asset="flycms-linux-$arch"
	say "Скачиваю и проверяю движок ($asset, $version)"
	curl -fsSL -o "$bin.new" "$release/$asset" || die "не скачать бинарник $version"
	curl -fsSL -o "$work/SHA256SUMS" "$release/SHA256SUMS" || die "в релизе нет SHA256SUMS; прежний бинарник сохранён"
	verify_download "$work/SHA256SUMS" "$bin.new" "$asset" || die "контрольная сумма не совпала или SHA256SUMS повреждён; прежний бинарник сохранён"
	chmod 755 "$bin.new"
	got=$("$bin.new" -version) || die "проверенный файл не запускается на этой системе"
	[ "$got" = "$version" ] || die "версия бинарника $got не совпадает с тегом $version"
	if [ ! -f "$unit" ]; then
		curl -fsSL -o "$work/flycms.service" "https://raw.githubusercontent.com/$repo/$version/flycms.service" || die "в теге $version нет flycms.service"
		[ -s "$work/flycms.service" ] || die "получен пустой flycms.service"
	fi

	if ! command -v psql >/dev/null; then
		. /etc/os-release
		supported_system "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" || die "для установки Postgres нужны Debian 12/13 или Ubuntu 22.04/24.04; либо установите PostgreSQL самостоятельно"
	fi
	if ! command -v ss >/dev/null || ! command -v psql >/dev/null; then
		export DEBIAN_FRONTEND=noninteractive
		apt-get update -qq || die "apt не обновил список пакетов; установка остановлена"
		apt-get install -y -qq ca-certificates iproute2 >/dev/null || die "не поставить ca-certificates и iproute2"
	fi
	if ! command -v psql >/dev/null; then
		say "Ставлю Postgres $pg"
		key=/usr/share/keyrings/flycms-pgdg.asc
		source=/etc/apt/sources.list.d/flycms-pgdg.list
		configure_pgdg
		apt-get install -y -qq "postgresql-$pg" >/dev/null || die "Postgres $pg не поставился"
		systemctl enable --now postgresql >/dev/null || die "не запустить Postgres"
	fi

	if [ ! -f "$envfile" ]; then check_new_database; fi
	id -u "$user" >/dev/null 2>&1 || useradd --system --home-dir "$dir" --shell /usr/sbin/nologin "$user"
	for folder in "$dir" "$dir/files" "$dir/plugins" "$dir/certs" "$dir/backup"; do
		[ ! -L "$folder" ] || die "папка $folder оказалась символической ссылкой"
	done
	# Служба пишет в дочерние папки, но не может подменить корневую папку копий.
	install -d -o root -g root -m 755 "$dir"
	install -d -o "$user" -g "$user" -m 755 "$dir/files" "$dir/plugins"
	install -d -o "$user" -g "$user" -m 700 "$dir/certs"
	install -d -o root -g root -m 700 "$dir/backup"
	chown -hR "$user:$user" "$dir/files" "$dir/plugins" "$dir/certs"
	tty_ok=false
	if ( : </dev/tty ) 2>/dev/null; then tty_ok=true; fi
	guess=$(hostname -I 2>/dev/null | awk '{print $1}')
	guess=${guess:-адрес-сервера}
	prepare_settings
	chmod 640 "$envfile"
	chown "root:$user" "$envfile"
	dsn=$(env_value "$envfile" FLYCMS_DSN '')
	if [ "$updating" = false ] && [ "$dsn" = "postgres:///$user?host=/run/postgresql&sslmode=disable" ]; then ensure_database; fi
	check_database_connection
	grant_createrole
	check_plugin_login
	addr=$(env_value "$envfile" FLYCMS_ADDR :80)
	tls_addr=$(env_value "$envfile" FLYCMS_TLS_ADDR :443)
	health_url=$(listen_url http "$addr") || die "неверный FLYCMS_ADDR: $addr"
	if [ -n "$tls_addr" ]; then
		health_url=$(listen_url https "$tls_addr") || die "неверный FLYCMS_TLS_ADDR: $tls_addr"
	fi
	health_port=${health_url##*:}
	warn_busy_ports

	if [ "$updating" = true ]; then backup_before_update; fi
	# Служба остановлена: install не пишет поверх исполняемого процесса.
	install -o root -g root -m 755 "$bin.new" "$bin" || die "не установить бинарник"
	if [ ! -f "$unit" ]; then install -o root -g root -m 644 "$work/flycms.service" "$unit"; fi
	systemctl daemon-reload || die "systemd не перечитал настройки"
	systemctl enable flycms >/dev/null || die "не включить службу"
	say "Запускаю магазин"
	systemctl restart flycms || die "служба не запустилась"
	wait_ready || die "служба не ответила на своём порту за 300 секунд; journalctl -u flycms -n 50 --no-pager"
	restore_needed=false
	resume_needed=false
	if [ "$updating" = true ]; then
		expired_backups "$dir/backup" >"$work/expired-backups"
		while IFS= read -r expired; do
			# Удаляем только подтверждённые пары этого установщика, после успешного запуска.
			rm -f -- "$dir/backup/$expired.sql.gz" "$dir/backup/$expired.flycms" "$dir/backup/$expired.installer-backup"
		done <"$work/expired-backups"
		say "Копия до обновления: $dump; прежний бинарник: $old_binary"
	fi
	say "Готово. flycms $version"
	printf '\n    Магазин: https://%s\n    Админка: https://%s/admin\n' "$host" "$host"
	print_install_link
	printf '\n    Журнал: journalctl -u flycms -f\n    Обновление: повторите ту же команду.\n'
}

main "$@"
