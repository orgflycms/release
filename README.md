# sitecms

Интернет-магазин на своём сервере, который расширяется плагинами. Ставится
одной командой, работает в docker compose: движок, Postgres и Caddy с https.

Товары, корзина, заказы, админка. Плагины — папки с Go-кодом, которые ядро
читает на лету: положили папку, нажали «Перечитать» — раздел появился в
админке. Первый плагин, «Промокоды», лежит в открытом репозитории
[sitecms/plugins](https://github.com/sitecms/plugins) — там же контракт и
инструкция, как написать свой.

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/sitecms/release/main/install.sh | sudo sh
```

Скрипт спросит домен или IP, поставит docker, если его нет, положит
`docker-compose.yml` в `/opt/sitecms` и поднимет магазин. В конце покажет
адрес, логин `admin` и пароль — один раз.

Нужен Linux с systemd и `curl`. Подробности, домен, плагины и удаление — в
[docs/install.md](docs/install.md).

## Обновление

```sh
cd /opt/sitecms && docker compose pull && docker compose up -d
```

Данные при обновлении не трогаются: миграции догоняют схему при старте.
Подробности — [docs/update.md](docs/update.md).

## Плагины

Папка `/opt/sitecms/plugins/`: по подпапке на плагин. Скрипт установки
кладёт туда «Промокоды». Как написать свой —
[docs/plugins.md](docs/plugins.md).

## Что внутри

- Go, стандартная библиотека: `net/http`, `html/template`
- Postgres 17 в соседнем контейнере
- Плагины исполняет [Yaegi](https://github.com/traefik/yaegi) — интерпретатор
  Go, тот же, что в Traefik
- Сервер-рендеринг, без SPA и без сборщика JS; стили и шрифты вшиты в бинарник

## Этот репозиторий

Здесь документация, `install.sh` и `docker-compose.yml`. Образы движка —
в [пакетах](https://github.com/sitecms/engine/pkgs/container/engine).
Исходный код ядра закрыт; плагины и их контракт открыты.

Нашли ошибку или нужна функция — [issues](https://github.com/sitecms/release/issues).
