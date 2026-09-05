# Установка

```sh
curl -fsSL https://raw.githubusercontent.com/flycms/release/main/install.sh | sudo sh
```

Скрипт:

1. ставит docker, если его нет (`get.docker.com`);
2. спрашивает домен или публичный IP (или берёт `FLYCMS_HOST` из окружения);
3. кладёт в `/opt/flycms` файлы `docker-compose.yml`, `.env` (домен и
   пароль базы), `Caddyfile` и пустую папку `plugins/`;
4. запускает `docker compose up -d` и печатает адрес.

Дальше — визард: откройте `https://<адрес>/install`, он спросит название
магазина, контакт, логин и пароль владельца и нужны ли демо-товары. До визарда
магазин ничего другого не показывает, после — визард закрыт.

## Что где

```
/opt/flycms/
  docker-compose.yml   движок + Postgres + Caddy
  .env                 FLYCMS_HOST, DB_PASSWORD — не менять после первого старта;
                       образец — .env.dist в репозитории
  Caddyfile            https: Let's Encrypt для домена, самоподписанный для IP
  plugins/             по подпапке на плагин
```

Данные — в docker-томах `flycms_pgdata` (база) и `flycms_caddy_data`
(сертификаты).

## Домен и https

Домен, указанный при установке, получает сертификат Let's Encrypt сам —
Caddy выпишет его при первом заходе, нужны открытые 80 и 443 и A-запись на
сервер. По голому IP сертификат самоподписанный: браузер один раз ругнётся,
но пароль по открытому каналу не ходит.

Сменить домен: поправить `FLYCMS_HOST` в `.env` и `Caddyfile`, затем
`docker compose up -d`.

## Переменные движка

Задаются в `docker-compose.yml`, секция `engine`:

- `FLYCMS_DSN` — строка подключения к Postgres;
- `FLYCMS_PLUGINS` — папка плагинов внутри контейнера (`/app/plugins`);
- `FLYCMS_MARKETPLACE` — адрес API маркетплейса (`https://<сайт>/api/v1`);
  по умолчанию маркетплейс flycms;
- `FLYCMS_SECURE=1` — кука админки только по https (за Caddy так и есть).

## Плагины

Готовые — в админке, раздел «Маркетплейс»: кнопка ставит плагин из
каталога и подхватывает его без перезапуска; платный сначала покупается.
Свой — папка `/opt/flycms/plugins/<имя>/` с Go-файлами и
«Плагины → Перечитать». Подробнее — [plugins.md](plugins.md).

## Удаление

```sh
cd /opt/flycms && docker compose down -v && cd / && rm -rf /opt/flycms
```

`-v` удаляет тома вместе с базой — без него данные останутся.
