# Обновление

```sh
curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/install.sh | sudo sh
```

Та же команда, что и при установке. Скрипт видит, что магазин уже стоит:
скачивает свежий движок, обновляет unit и перезапускает службу. Домен,
пароль базы и данные не трогаются — миграции догоняют схему при старте,
папки `files/` и `plugins/` лежат снаружи бинарника.

Версия сейчас:

```sh
flycms -version
```

## Конкретная версия

```sh
curl -fsSL https://raw.githubusercontent.com/orgflycms/release/main/install.sh | sudo FLYCMS_VERSION=v0.1.0 sh
```

Так же делается откат: список версий — в
[релизах](https://github.com/orgflycms/release/releases).

## Если что-то пошло не так

```sh
systemctl status flycms
journalctl -u flycms -n 50 --no-pager
```

Движок пишет, что не так с базой или с плагином. Сломанный плагин магазин
не останавливает — он помечается в «Плагинах» с текстом ошибки.
