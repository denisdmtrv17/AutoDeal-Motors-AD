#!/usr/bin/env bash
# mfa-po-rolya.sh  —  МИС, ТУЕС, Час 8.
# Налага втори фактор (TOTP) за всеки с дадена realm роля, при вход през браузъра.
# Прави копие на вградения поток "browser", в под-потока с OTP сменя условието
# "потребителят вече има OTP" с "потребителят има ролята", и прави копието активно.
#
# Употреба (на srv, след kc-vhod):
#   ./mfa-po-rolya.sh <realm> <роля>          напр.  ./mfa-po-rolya.sh medlab admins
# Връщане назад:
#   /opt/keycloak/bin/kcadm.sh update realms/<realm> -s browserFlow=browser
set -euo pipefail
REALM="${1:?употреба: $0 <realm> <роля>}"
ROLE="${2:?употреба: $0 <realm> <роля>}"
FLOW="browser-mfa-${ROLE}"
K=/opt/keycloak/bin/kcadm.sh

$K get "roles/${ROLE}" -r "$REALM" >/dev/null 2>&1 || { echo "Няма realm роля '${ROLE}' в '${REALM}' (или не си влязъл: kc-vhod)"; exit 1; }

if $K get "authentication/flows" -r "$REALM" --fields alias --format csv --noquotes | grep -qx "$FLOW"; then
  echo "Потокът ${FLOW} вече съществува; само го правя активен."
else
  $K create authentication/flows/browser/copy -r "$REALM" -s "newName=${FLOW}" >/dev/null
  ex_json=$($K get "authentication/flows/${FLOW}/executions" -r "$REALM")
  # Намира под-потока, в който е OTP формата, и условията в него
  read -r SUBFLOW OTP_ID CONDS < <(printf '%s' "$ex_json" | python3 -c '
import json, sys, urllib.parse
ex = json.load(sys.stdin)
parent = None; sub = None; otp = None; conds = []
for i, e in enumerate(ex):
    if e.get("authenticationFlow") and e["level"] == 1:
        parent = e
    if e.get("providerId") == "auth-otp-form":
        sub, otp = parent, e
        break
for e in ex:
    if sub and e["level"] == 2 and e.get("providerId", "").startswith("conditional-"):
        # само условията от същия под-поток
        idx_sub = ex.index(sub); idx_e = ex.index(e); idx_otp = ex.index(otp)
        nxt = [j for j in range(idx_sub + 1, len(ex)) if ex[j]["level"] <= 1]
        end = nxt[0] if nxt else len(ex)
        if idx_sub < idx_e < end:
            conds.append(e["id"])
print(urllib.parse.quote(sub["displayName"]), otp["id"], ",".join(conds) or "-")
')
  if [[ "$CONDS" != "-" ]]; then for c in ${CONDS//,/ }; do $K delete "authentication/executions/${c}" -r "$REALM"; done; fi
  $K create "authentication/flows/${SUBFLOW}/executions/execution" -r "$REALM" -s provider=conditional-user-role >/dev/null
  COND_ID=$($K get "authentication/flows/${FLOW}/executions" -r "$REALM" --fields id,providerId --format csv --noquotes | awk -F, '$2=="conditional-user-role"{print $1}')
  $K update "authentication/flows/${FLOW}/executions" -r "$REALM" -b "{\"id\":\"${COND_ID}\",\"requirement\":\"REQUIRED\"}"
  $K update "authentication/flows/${FLOW}/executions" -r "$REALM" -b "{\"id\":\"${OTP_ID}\",\"requirement\":\"REQUIRED\"}"
  $K create "authentication/executions/${COND_ID}/config" -r "$REALM" -s "alias=rolya-${ROLE}" -s "config={\"condUserRole\":\"${ROLE}\",\"negate\":\"false\"}" >/dev/null
fi

$K update "realms/${REALM}" -s "browserFlow=${FLOW}"
echo "Готово. Активен поток за браузър: ${FLOW}. TOTP е задължителен за роля '${ROLE}'."
echo "Провери в конзолата: Authentication -> ${FLOW} (трябва да е маркиран Default / Used by browser flow)."
$K get "authentication/flows/${FLOW}/executions" -r "$REALM" --fields displayName,requirement,level --format csv --noquotes | sed -n '/2FA\|OTP\|Condition - user role/p'
