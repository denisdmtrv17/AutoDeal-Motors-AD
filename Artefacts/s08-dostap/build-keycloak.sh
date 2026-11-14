#!/usr/bin/env bash
# postroi-keycloak.sh  —  МИС, ТУЕС, Час 8. Keycloak (dev режим) на srv.
#
# Употреба (на srv, като потребител със sudo):
#   sudo ./postroi-keycloak.sh                 # инсталира и пуска
#   sudo KC_URL=http://10.0.0.1:8000/keycloak-26.8.2.tar.gz ./postroi-keycloak.sh
#                                              # ако преподавателят раздава архива локално
#   sudo ./postroi-keycloak.sh status          # услуга, порт, памет
#
# Какво прави: Java 17, системен потребител keycloak, /opt/keycloak,
# systemd услуга keycloak.service (start-dev, порт 8080, всички интерфейси),
# временен админ с еднократна парола, три помощни инструмента:
#   kc-vhod                     вход на kcadm.sh към сървъра (пита за парола)
#   kc-sabitiya <realm> [брой]  последните събития: час, тип, грешка, потребител, IP
#   kc-token <realm> <client> <потребител> [TOTP]  тест на вход през API, показва ролите в токена
#
# Dev режимът е само за лабораторията: HTTP, вградена H2 база, без настройка на hostname.
set -euo pipefail

KC_VER="${KC_VER:-26.8.2}"
KC_URL="${KC_URL:-https://github.com/keycloak/keycloak/releases/download/${KC_VER}/keycloak-${KC_VER}.tar.gz}"
KC_DIR=/opt/keycloak
KC_PORT=8080

die() { echo "ГРЕШКА: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "пусни със sudo"

if [[ "${1:-}" == "status" ]]; then
  systemctl --no-pager --lines=0 status keycloak || true
  echo; echo "Порт:"; ss -ltnp | grep ":${KC_PORT} " || echo "  ${KC_PORT} не слуша"
  echo; echo "Памет:"; free -m | head -2
  exit 0
fi

# 1. Памет. Keycloak иска около 700 MB; под 2 GB на srv започват проблеми.
mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
if (( mem_kb < 1900000 )); then
  echo "ВНИМАНИЕ: srv има $((mem_kb/1024)) MB RAM. Изключи srv, дай му поне 2048 MB и пусни скрипта пак."
  exit 1
fi

# 2. Пакети
echo "[1/6] Java и инструменти"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openjdk-17-jre-headless curl python3 >/dev/null

# 3. Потребител и файлове
echo "[2/6] Потребител keycloak и /opt/keycloak"
id keycloak >/dev/null 2>&1 || useradd --system --home-dir "$KC_DIR" --shell /usr/sbin/nologin keycloak
if [[ ! -x "$KC_DIR/bin/kc.sh" ]]; then
  tmp=$(mktemp -d)
  echo "      сваляне: $KC_URL"
  curl -fL --progress-bar -o "$tmp/kc.tgz" "$KC_URL" || die "архивът не се свали"
  tar -xzf "$tmp/kc.tgz" -C /opt
  ln -sfn "/opt/keycloak-${KC_VER}" "$KC_DIR"
  rm -rf "$tmp"
else
  echo "      вече е разархивиран, пропускам"
fi
chown -R keycloak:keycloak "/opt/keycloak-${KC_VER}"

# 4. Временен админ (важи само при първото пускане, после файлът се трие)
echo "[3/6] Временен администратор"
first_run=0
if [[ ! -d "$KC_DIR/data/h2" ]]; then
  first_run=1
  install -d -m 700 /etc/keycloak
  KC_PASS=$(python3 -c 'import secrets; a="ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789"; print("".join(secrets.choice(a) for _ in range(16)))')
  umask 077
  printf 'KC_BOOTSTRAP_ADMIN_USERNAME=admin\nKC_BOOTSTRAP_ADMIN_PASSWORD=%s\n' "$KC_PASS" > /etc/keycloak/bootstrap.env
  umask 022
fi

# 5. systemd
echo "[4/6] Услуга keycloak.service"
cat > /etc/systemd/system/keycloak.service <<EOF
[Unit]
Description=Keycloak (МИС лаборатория, dev режим)
After=network-online.target
Wants=network-online.target

[Service]
User=keycloak
Group=keycloak
EnvironmentFile=-/etc/keycloak/bootstrap.env
Environment=JAVA_OPTS_KC_HEAP=-Xms256m -Xmx768m
ExecStart=${KC_DIR}/bin/kc.sh start-dev --http-host=0.0.0.0 --http-port=${KC_PORT}
Restart=on-failure
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now keycloak >/dev/null 2>&1
systemctl restart keycloak

echo "[5/6] Изчакване да тръгне (до 3 минути)"
for i in $(seq 1 90); do
  if curl -fs "http://127.0.0.1:${KC_PORT}/realms/master/.well-known/openid-configuration" >/dev/null; then
    ok=1; break
  fi
  sleep 2
done
[[ "${ok:-0}" == 1 ]] || die "Keycloak не отговаря. Виж: journalctl -u keycloak -n 50"
rm -f /etc/keycloak/bootstrap.env

# 6. Помощни инструменти
echo "[6/6] kc-vhod, kc-sabitiya, kc-token"
cat > /usr/local/bin/kc-vhod <<EOF
#!/bin/sh
# Вход на kcadm.sh. Пита за паролата. Токенът се пази в ~/.keycloak/kcadm.config
exec ${KC_DIR}/bin/kcadm.sh config credentials --server http://127.0.0.1:${KC_PORT} --realm master --user "\${1:-admin}"
EOF
cat > /usr/local/bin/kc-sabitiya <<EOF
#!/bin/sh
# kc-sabitiya <realm> [брой]  — последните потребителски събития в realm-а
[ -n "\$1" ] || { echo "употреба: kc-sabitiya <realm> [брой]"; exit 1; }
json=\$(${KC_DIR}/bin/kcadm.sh get events -r "\$1" -q max="\${2:-20}" 2>&1) || { echo "\$json"; echo "Не си влязъл или сесията е изтекла. Пусни: kc-vhod"; exit 1; }
printf '%s' "\$json" | python3 -c '
import json, sys, datetime
for e in json.load(sys.stdin):
    t = datetime.datetime.fromtimestamp(e["time"] / 1000).strftime("%Y-%m-%d %H:%M:%S")
    d = e.get("details", {})
    print(t, e["type"], e.get("error", "-"), d.get("username", "-"), e.get("clientId", "-"), e.get("ipAddress", "-"), sep="  ")
'
EOF
chmod 755 /usr/local/bin/kc-vhod /usr/local/bin/kc-sabitiya
cat > /usr/local/bin/kc-token <<EOF
#!/usr/bin/env python3
# kc-token <realm> <client> <потребител> [TOTP код]
# Иска токен с password grant (само за тестове!) и показва какво съдържа или защо е отказан.
# Паролата се пита; за скрипт може да се подаде в променливата KC_TEST_PASS.
import os, sys, json, base64, getpass, urllib.request, urllib.parse, urllib.error
if len(sys.argv) < 4:
    sys.exit("употреба: kc-token <realm> <client> <потребител> [TOTP код]")
realm, client, user = sys.argv[1:4]
data = {"grant_type": "password", "client_id": client, "username": user,
        "password": os.environ.get("KC_TEST_PASS") or getpass.getpass("Парола за " + user + ": "), "scope": "openid"}
if len(sys.argv) > 4:
    data["totp"] = sys.argv[4]
url = "http://127.0.0.1:${KC_PORT}/realms/%s/protocol/openid-connect/token" % realm
try:
    r = json.load(urllib.request.urlopen(url, urllib.parse.urlencode(data).encode()))
except urllib.error.HTTPError as e:
    print("ОТКАЗ", e.code, e.read().decode()); sys.exit(1)
t = r["access_token"].split(".")[1]; t += "=" * (-len(t) % 4)
c = json.loads(base64.urlsafe_b64decode(t))
print("ИЗДАДЕН ТОКЕН (първите 40 знака):", r["access_token"][:40] + "...")
for k in ("iss", "azp", "preferred_username", "realm_access", "iat", "exp"):
    print("  %-20s %s" % (k, c.get(k)))
print("  валиден (секунди)    ", c["exp"] - c["iat"])
EOF
chmod 755 /usr/local/bin/kc-token


ip=$(hostname -I | awk '{print $1}')
echo
echo "Готово. Keycloak ${KC_VER} работи."
echo "  Админ конзола от браузъра на лаптопа:  http://${ip}:${KC_PORT}/admin/"
if (( first_run )); then
  echo "  Временен админ:  admin / ${KC_PASS}"
  echo "  Паролата не е записана никъде. Запиши я сега; в стъпка 2 ще създадеш постоянен админ."
fi
echo "  Проверка:  sudo $0 status"
