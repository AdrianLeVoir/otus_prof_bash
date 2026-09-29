# Домашнее задание: Скрипт для CRON — отчёт о работе веб-сервера

## 1. Стенд

| Параметр | Значение |
|---|---|
| Веб-сервер | Nextcloud (`cloud.levoirlab.su`) за Nginx Proxy Manager на VPS **Rhea** |
| Лог | `proxy-host-12_access.log` (формат NPM, ~7400 записей за 3 дня) |
| Доставка почты | VPS **Nyx** (у хостера Rhea исходящие SMTP-порты 25/465/587 заблокированы) |
| Получатель | `zmey.1123r@mail.ru` |
| Отправитель | `adel_gataullin@list.ru` (smtp.mail.ru:465, TLS) |

## 2. Решение

`webstat.sh` — скрипт для cron; `webstat-mail.sh` — релей доставки почты с Nyx; `report.txt` — реальный отчёт, отправленный на почту.

```bash
# Rhea: скрипт запускается с SKIP_MAIL=1 (порты SMTP закрыты), отчёт сохраняется
/usr/local/bin/webstat.sh /home/adrianl/npm/data/logs/proxy-host-12_access.log
# Nyx: cron @hourly от root
@hourly /usr/local/bin/webstat-mail.sh
```

Пути и почта настраиваются переменными окружения (`LOG_FILE`, `STATE_DIR`, `MAIL_TO`, `MAIL_FROM`); по умолчанию лог — первый аргумент, получатель — `adel_gataullin@list.ru`.

## 3. Как работает

| Требование ТЗ | Реализация |
|---|---|
| Отчёт раз в час | cron `@hourly` на Nyx |
| Топ IP-адресов за период | `parse_ip` (nginx: `$1`; NPM: `[Client …]`) + `sort / uniq -c / sort -rn / head -5` |
| Топ URL за период | `parse_url` (nginx: `sed` по запросу; NPM: `"METHOD proto домен "url""`) |
| Ошибки (4xx/5xx) | `parse_status` + перечисление строк с кодом и timestamp |
| HTTP-коды с количеством | `parse_status` + `sort / uniq -c / sort -rn` |
| Только с прошлого запуска | state-файл `/var/tmp/webstat/last_run` (epoch); строки фильтруются по timestamp из лога |
| Диапазон в письме | тема и первая строка: `Период: 27/Sep/2026:03:05:46 +0300 — 29/Sep/2026:23:01:53 +0300` |
| Защита от параллельного запуска | `flock -n` на lock-файл (`exec 9>`), второй экземпляр выходит |
| Трапы | `trap cleanup EXIT` — чистит temp-отчёт, сохраняет метку запуска даже при ошибке |
| Функции | `acquire_lock`, `cleanup`, `ts2epoch`, `find_log`, `build_report`, `send_report`, `parse_*`, `log`, `die` |
| sed и find | `sed` — парсинг timestamp/URL/кодов, `find` — поиск свежего лога, если заданный недоступен |
| Форматы логов | автодетект: nginx combined и NPM (`[ts] - код код - GET https домен "url" [Client IP]`) |

## 4. Архитектура доставки почты

```
Rhea: webstat.sh (SKIP_MAIL=1) → /var/tmp/webstat/report.last
Nyx : webstat-mail.sh (cron @hourly)
      → SSH root@Rhea:4853 (ключ ed25519): запуск webstat, scp отчёта
      → mail (msmtp → smtp.mail.ru:465 TLS, from adel_gataullin@list.ru)
      → zmey.1123r@mail.ru
```

msmtp-конфиг на Nyx: `/root/.msmtprc` (600, учётка list.ru, лог `/var/log/msmtp.log`).
Блокировка параллельного запуска есть на обоих уровнях: flock в webstat.sh и flock в webstat-mail.sh.

## 5. Реальный отчёт (полный — в report.txt)

```
Период: 27/Sep/2026:03:05:46 +0300 — 29/Sep/2026:23:01:53 +0300
Запросов за период: 7364

== Топ IP-адресов ==
   5483 94.156.179.17      (Dione — свои мониторинги)
    282 185.218.86.25
    267 178.176.169.232    (телефон, Nextcloud-клиент)
    251 130.211.255.225    (сканер)
    131 45.138.12.24       (сканер)

== Топ URL ==
   4542 /ocs/v2.php/apps/notifications/api/v2/notifications
    470 /ocs/v2.php/apps/user_status/api/v1/heartbeat
    446 /index.php/204
    296 /login
    190 /csrftoken

== HTTP-коды ответов ==
   4538 304 / 1261 200 / 445 204 / 414 404 / 340 403 / 204 301 / 134 302 / 12 303 / 11 499 / 3 502 / 2 401

== Ошибки (4xx/5xx) ==
(~580 строк: сканеры /.env /.git/config /.aws/credentials /wp-config.php — NPM режет их 403-ми;
 WebDAV 401/499/502 при загрузке файлов)
```

Доставка подтверждена: `smtpstatus=250` в `/var/log/msmtp.log` на Nyx, отчёт получен на почту.

## 6. Повторный запуск и блокировка

```
С момента прошлого запуска новых запросов нет.        ← окно учитывается (state)
экземпляр уже запущен, выходим                        ← flock при параллельном запуске
```

## 7. Ручная проверка

```bash
# Rhea
sudo SKIP_MAIL=1 /usr/local/bin/webstat.sh /home/adrianl/npm/data/logs/proxy-host-12_access.log
sudo cat /var/tmp/webstat/report.last /var/tmp/webstat/last_run
# Nyx
sudo /usr/local/bin/webstat-mail.sh
sudo grep webstat /var/log/msmtp.log | tail -1
```
