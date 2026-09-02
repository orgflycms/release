# Установка

```sh
curl -fsSL https://raw.githubusercontent.com/sitecms/release/main/install.sh | sudo sh
```

Скрипт:

1. ставит docker, если его нет (`get.docker.com`);
2. спрашивает домен или публичный IP (или берёт `SITECMS_HOST` из окружения);
3. кладёт в `/opt/sitecms` файлы `docker-compose.yml`, `.env` (домен и
   пароль базы), `Caddyfile` и папку `plugins/` с плагином «Промокоды»;
4. запускает `docker compose up -d` и печатает адрес, логин `admin` и пароль.

## Что где

```
/opt/sitecms/
  docker-compose.yml   движок + Postgres + Caddy
  .env                 SITECMS_HOST, DB_PASSWORD — не менять после первого старта
  Caddyfile            https: Let's Encrypt для домена, самоподписанный для IP
  plugins/             по подпапке на плагин
```

Данные — в docker-томах `sitecms_pgdata` (база) и `sitecms_caddy_data`
(сертификаты).

## Домен и https

Домен, указанный при установке, получает сертификат Let's Encrypt сам —
Caddy выпишет его при первом заходе, нужны открытые 80 и 443 и A-запись на
сервер. По голому IP сертификат самоподписанный: браузер один раз ругнётся,
но пароль по открытому каналу не ходит.

Сменить домен: поправить `SITECMS_HOST` в `.env` и `Caddyfile`, затем
`docker compose up -d`.

## Переменные движка

Задаются в `docker-compose.yml`, секция `engine`:

- `SITECMS_DSN` — строка подключения к Postgres;
- `SITECMS_PLUGINS` — папка плагинов внутри контейнера (`/app/plugins`);
- `SITECMS_ADMIN_PASSWORD` — пароль владельца при первом старте вместо
  случайного; после первого старта переменную убрать;
- `SITECMS_SECURE=1` — кука админки только по https (за Caddy так и есть).

## Плагины

Папка `/opt/sitecms/plugins/<имя>/` с Go-файлами. Положили — в админке
«Плагины → Перечитать». Ошибка загрузки показывается там же.
Подробнее — [plugins.md](plugins.md).

## Удаление

```sh
cd /opt/sitecms && docker compose down -v && cd / && rm -rf /opt/sitecms
```

`-v` удаляет тома вместе с базой — без него данные останутся.
