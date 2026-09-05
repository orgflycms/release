#!/bin/sh
# flycms — установка на свой сервер одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/flycms/release/main/install.sh | sudo sh
#
# Ставит docker (если нет), кладёт compose в /opt/flycms и поднимает
# магазин. Плагины — из маркетплейса в админке. Повторный запуск обновляет
# образы и перезапускает службы, данные не трогает.
#
# Вопрос про адрес задаётся в терминал, даже когда скрипт пришёл по трубе:
# он читает ответ из /dev/tty. Чтобы не спрашивал, задайте FLYCMS_HOST.
set -eu

repo=flycms/release
dir=/opt/flycms
raw="https://raw.githubusercontent.com/$repo/main"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
die() {
	printf '\033[31mОшибка:\033[0m %s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" = 0 ] || die "нужны права root — запустите через sudo"
command -v curl >/dev/null || die "нужен curl"

tty_ok=false
[ -e /dev/tty ] && [ -r /dev/tty ] && tty_ok=true
ask() { # ask «вопрос» «умолчание»
	if [ "$tty_ok" != true ]; then
		printf '%s' "$2"
		return
	fi
	printf '\n%s [%s]: ' "$1" "$2" >/dev/tty
	read -r reply </dev/tty || reply=""
	printf '%s' "${reply:-$2}"
}

guess_host() {
	ip=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
	[ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	printf '%s' "${ip:-адрес-сервера}"
}

# --- docker --------------------------------------------------------------
if ! command -v docker >/dev/null; then
	say "Ставлю docker"
	curl -fsSL https://get.docker.com | sh || die "docker не поставился"
fi
docker compose version >/dev/null 2>&1 || die "нужен docker compose v2"

# --- адрес ---------------------------------------------------------------
mkdir -p "$dir/plugins"
cd "$dir"

if [ -f .env ]; then
	# Повторный запуск: домен и пароль базы уже есть, менять их нельзя —
	# пароль зашит в данные Postgres.
	. ./.env
	host="${FLYCMS_HOST:-}"
fi
if [ -z "${host:-}" ]; then
	host="${FLYCMS_HOST:-$(ask 'Домен или публичный IP магазина' "$(guess_host)")}"
	password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 24)
	printf 'FLYCMS_HOST=%s\nDB_PASSWORD=%s\n' "$host" "$password" >.env
	chmod 600 .env
fi

# --- файлы ---------------------------------------------------------------
say "Скачиваю docker-compose.yml"
curl -fsSL -o docker-compose.yml "$raw/docker-compose.yml" || die "не скачать docker-compose.yml"

# Домену Caddy выпишет сертификат у Let's Encrypt сам. По голому IP выписать
# нечего — берётся самоподписанный (tls internal), браузер один раз ругнётся.
case "$host" in
*[a-zA-Z]*) tls="" ;;
*) tls="tls internal" ;;
esac
cat >Caddyfile <<EOC
{\$FLYCMS_HOST} {
	$tls
	reverse_proxy engine:8080
}
EOC

# --- запуск --------------------------------------------------------------
say "Поднимаю магазин"
docker compose pull -q
docker compose up -d --remove-orphans

say "Жду, пока движок поднимется"
i=0
while [ "$i" -lt 60 ]; do
	docker compose logs engine 2>/dev/null | grep -q "сервер запущен" && break
	i=$((i + 1))
	sleep 1
done

echo
say "Готово."
echo
echo "    Магазин: https://$host"
echo "    Админка: https://$host/admin"
echo
if docker compose logs engine 2>/dev/null | grep -q "не установлен"; then
	echo "  Откройте https://$host/install — визард спросит название, логин"
	echo "  и пароль владельца и нужны ли демо-товары. До этого магазин"
	echo "  ничего другого не показывает."
else
	echo "  Вход прежний: логин и пароль задавались в визарде установки."
fi
echo
echo "  Плагины: раздел «Маркетплейс» в админке; свои — $dir/plugins, по папке на плагин."
echo "  Обновить: cd $dir && docker compose pull && docker compose up -d"
