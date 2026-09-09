# Установка

```sh
curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/install.sh | sudo sh
```

Нужен Debian или Ubuntu с systemd, `curl`, права root и свободные порты 80
и 443. Docker не нужен.

Скрипт:

1. ставит Postgres 18 из репозитория PGDG, если своего на машине нет
   (свой любой версии он берёт как есть и чужие базы не трогает);
2. заводит системного пользователя `flycms`, папку `/opt/flycms` с
   `files/` и `plugins/`, роль и базу `flycms` (вход по сокету, без пароля);
3. спрашивает домен или публичный IP (или берёт `FLYCMS_HOST` из окружения)
   и пишет `/etc/flycms.env`;
4. скачивает движок в `/usr/local/bin/flycms` и unit
   `/etc/systemd/system/flycms.service`, поднимает службу и печатает адрес.

Дальше — визард: откройте `https://<адрес>/install`, он спросит название
магазина, контакт, логин и пароль владельца и нужны ли демо-товары. До
визарда магазин ничего другого не показывает, после — визард закрыт.

## Что где

```
/usr/local/bin/flycms            движок, один файл
/etc/flycms.env                  домен, база, папки — правится руками
/etc/systemd/system/flycms.service
/opt/flycms/files/               картинки (пока не задан S3) и сертификаты
/opt/flycms/plugins/             по подпапке на плагин
```

База — обычный кластер Postgres на этой же машине, база и роль `flycms`.
Бэкап магазина: `pg_dump` базы плюс папка `/opt/flycms/files`.

```sh
systemctl status flycms      # что сейчас
journalctl -u flycms -f      # журнал
systemctl restart flycms     # после правки /etc/flycms.env
```

## Домен и https

Движок держит 80 и 443 сам: отдельного веб-сервера в поставке нет. Право
слушать низкие порты даёт systemd, root ему не нужен.

Домен берётся из «Адреса магазина» в настройках (Система → Настройки), а
пока он пуст — из `FLYCMS_HOST`, который спросил установщик. Впишите
`https://ваш-домен`, сохраните и нажмите «Выпустить сертификат» в карточке
«Домен и https»: движок проверит A-запись и получит сертификат у
Let's Encrypt — нужны открытые 80 и 443; продление он берёт на себя. По
голому IP сертификат самоподписанный: браузер один раз ругнётся, но пароль
по открытому каналу не ходит. Выписанное лежит в `/opt/flycms/files/certs`
— папку стоит сохранять: у Let's Encrypt пять сертификатов в неделю на
домен.

Сменить домен: поправить «Адрес магазина» и нажать «Выпустить сертификат»
ещё раз; перезапуск не нужен.

## Переменные движка

Живут в `/etc/flycms.env`, читаются службой при старте:

- `FLYCMS_DSN` — строка подключения к Postgres;
- `FLYCMS_FILES` — папка картинок и сертификатов (`/opt/flycms/files`);
- `FLYCMS_PLUGINS` — папка плагинов (`/opt/flycms/plugins`);
- `FLYCMS_MARKETPLACE` — адрес API маркетплейса (`https://flycms.ru/api/v1`);
- `FLYCMS_HOST` — домен магазина при установке; после первого сохранения
  «Адреса магазина» в настройках не читается;
- `FLYCMS_ADDR`, `FLYCMS_TLS_ADDR` — порты (`:80` и `:443`). Пустой
  `FLYCMS_TLS_ADDR` выключает свой https: так магазин ставят за чужой
  nginx, отдав ему 443 и проксируя на `FLYCMS_ADDR`.

## Уже есть nginx на 80 и 443

Отдайте магазину свой порт и выключите его https:

```sh
printf 'FLYCMS_ADDR=127.0.0.1:8080\nFLYCMS_TLS_ADDR=\n' >>/etc/flycms.env
systemctl restart flycms
```

Дальше `proxy_pass http://127.0.0.1:8080;` — сертификат в этом случае
держит nginx.

## Плагины

Готовые — в админке, раздел «Маркетплейс»: кнопка ставит плагин из
каталога и подхватывает его без перезапуска; платный сначала покупается.
Свой — папка `/opt/flycms/plugins/<имя>/` с Go-файлами и
«Плагины → Перечитать». Подробнее — [plugins.md](plugins.md).

## Удаление

```sh
systemctl disable --now flycms
rm -f /etc/systemd/system/flycms.service /etc/flycms.env /usr/local/bin/flycms
systemctl daemon-reload
su postgres -c 'dropdb flycms; dropuser flycms'
rm -rf /opt/flycms
userdel flycms
```

Postgres остаётся: его могли поставить не ради магазина.
