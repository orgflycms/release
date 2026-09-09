#!/bin/sh
# flycms — установка на свой сервер одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/install.sh | sudo sh
#
# Ставит Postgres (если своего на машине нет), кладёт бинарник магазина под
# systemd и поднимает его. Docker не нужен: на сервере работают ровно два
# процесса — магазин и база.
#
# Повторный запуск = обновление: свежий бинарник и перезапуск, база,
# картинки и плагины остаются на месте.
#
# Вопрос про домен задаётся в терминал, даже когда скрипт пришёл по трубе:
# он читает ответ из /dev/tty. Чтобы не спрашивал, задайте FLYCMS_HOST.
set -eu

repo=orgflycms/release
raw="https://raw.githubusercontent.com/$repo/main"
dir=/opt/flycms
bin=/usr/local/bin/flycms
envfile=/etc/flycms.env
unit=/etc/systemd/system/flycms.service
user=flycms
pg=18
version="${FLYCMS_VERSION:-latest}"

say() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m  %s\033[0m\n' "$1"; }
die() {
	printf '\033[31mОшибка:\033[0m %s\n' "$1" >&2
	exit 1
}

[ "$(id -u)" = 0 ] || die "нужны права root — запустите через sudo"
command -v curl >/dev/null || die "нужен curl"
command -v apt-get >/dev/null || die "скрипт умеет Debian и Ubuntu; на другой системе ставьте руками — docs/install.md"
[ -d /run/systemd/system ] || die "нужен systemd"

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) die "сборки под $(uname -m) нет — сейчас это amd64 и arm64" ;;
esac

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

# --- Postgres ------------------------------------------------------------
# Своя база на машине — берём её: чужой кластер трогать нельзя, а магазину
# всё равно, какой версии Postgres, лишь бы он был.
if ! command -v psql >/dev/null; then
	say "Ставлю Postgres $pg"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq ca-certificates curl >/dev/null || die "apt не поставил curl и ca-certificates"

	# Репозиторий PGDG: в Debian и Ubuntu своя версия Postgres отстаёт.
	. /etc/os-release
	[ -n "${VERSION_CODENAME:-}" ] || die "не понять версию системы — ставьте Postgres руками"
	key=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
	install -d "$(dirname "$key")"
	curl -fsSL -o "$key" https://www.postgresql.org/media/keys/ACCC4CF8.asc || die "не скачать ключ PGDG"
	echo "deb [signed-by=$key] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main" >/etc/apt/sources.list.d/pgdg.list
	apt-get update -qq
	apt-get install -y -qq "postgresql-$pg" >/dev/null || die "Postgres $pg не поставился"
fi
systemctl enable --now postgresql >/dev/null 2>&1 || true
command -v pg_isready >/dev/null && pg_isready -q || die "Postgres не отвечает — «systemctl status postgresql»"

# --- пользователь, папки, база -------------------------------------------
id -u "$user" >/dev/null 2>&1 ||
	useradd --system --home-dir "$dir" --shell /usr/sbin/nologin "$user"
mkdir -p "$dir/files" "$dir/plugins"
chown -R "$user:$user" "$dir"

# Пароля к базе нет: Postgres на этой же машине пускает по совпадению
# системного пользователя и роли (peer). Хранить нечего — нечего и потерять.
cd /tmp
has() { su postgres -c "psql -tAc \"select 1 from $1 where $2 = '$user'\"" | grep -q 1; }
has pg_roles rolname || su postgres -c "createuser $user"
has pg_database datname || su postgres -c "createdb -O $user $user"

# --- домен ---------------------------------------------------------------
if [ -f "$envfile" ]; then
	host=$(sed -n 's/^FLYCMS_HOST=//p' "$envfile")
else
	host="${FLYCMS_HOST:-$(ask 'Домен или публичный IP магазина' "$(guess_host)")}"
	cat >"$envfile" <<EOC
# Настройки магазина flycms. После правки: systemctl restart flycms
#
# Домен: на него магазин выписывает сертификат Let's Encrypt. Дальше домен
# меняют в админке («Настройки» → «Адрес магазина»), эта строка остаётся
# стартовым значением.
FLYCMS_HOST=$host
# База на этой же машине, вход по сокету и совпадению имени — пароля нет.
FLYCMS_DSN=postgres:///$user?host=/run/postgresql&sslmode=disable
FLYCMS_FILES=$dir/files
FLYCMS_PLUGINS=$dir/plugins
FLYCMS_MARKETPLACE=https://flycms.ru/api/v1
EOC
	chmod 640 "$envfile"
	chown "root:$user" "$envfile"
fi

# --- бинарник и служба ---------------------------------------------------
asset="flycms-linux-$arch"
if [ "$version" = latest ]; then
	url="https://github.com/$repo/releases/latest/download/$asset"
else
	url="https://github.com/$repo/releases/download/$version/$asset"
fi

say "Скачиваю движок ($asset, $version)"
# Рядом с целью, а не в /tmp: подмена на месте переживает запущенный процесс,
# копирование поверх работающего файла — нет.
trap 'rm -f "$bin.new"' EXIT
curl -fsSL -o "$bin.new" "$url" || die "не скачать $url"
chmod 755 "$bin.new"
"$bin.new" -version >/dev/null 2>&1 || die "скачанный файл не запускается — сборка не для этой системы?"
mv -f "$bin.new" "$bin"
trap - EXIT

curl -fsSL -o "$unit" "$raw/flycms.service" || die "не скачать flycms.service"
systemctl daemon-reload

busy=$(ss -Hltn 'sport = :80 or sport = :443' 2>/dev/null | grep -v "$bin" || true)
if [ -n "$busy" ] && ! systemctl is-active --quiet flycms; then
	warn "80 или 443 уже кем-то заняты — магазин не сможет их слушать."
	warn "Стороннему nginx отдайте один порт: FLYCMS_TLS_ADDR= в $envfile."
fi

say "Запускаю магазин"
systemctl enable flycms >/dev/null 2>&1
systemctl restart flycms

i=0
ready=false
while [ "$i" -lt 60 ]; do
	systemctl is-active --quiet flycms || break
	if curl -fsSk -o /dev/null --max-time 3 https://127.0.0.1/install 2>/dev/null ||
		curl -fsS -o /dev/null --max-time 3 http://127.0.0.1/install 2>/dev/null; then
		ready=true
		break
	fi
	i=$((i + 1))
	sleep 1
done

if [ "$ready" != true ]; then
	echo
	warn "Магазин не ответил за минуту. Что случилось — покажет:"
	warn "    journalctl -u flycms -n 30 --no-pager"
	exit 1
fi

version_now=$("$bin" -version 2>/dev/null || echo "?")
echo
say "Готово. flycms $version_now"
echo
echo "    Магазин: https://$host"
echo "    Админка: https://$host/admin"
echo
echo "  Откройте https://$host/install — визард спросит название, логин и"
echo "  пароль владельца и нужны ли демо-товары. До визарда магазин ничего"
echo "  другого не показывает; после — визард закрыт."
echo
echo "  Домен и сертификат: «Настройки» в админке, карточка «Домен и https»."
echo "  Плагины: раздел «Маркетплейс»; свои — $dir/plugins, по папке на плагин."
echo "  Обновить: повторите эту же команду. Журнал: journalctl -u flycms -f"
