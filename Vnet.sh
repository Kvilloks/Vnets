#!/usr/bin/env bash
# Создание/обновление VNets и подсетей SDN в Proxmox VE
# Пример:
#   ./create_vnets_range.sh --zone Zone1 --vnet 5-10 --octet 55-60
set -Euo pipefail
[[ "${DEBUG:-0}" == "1" ]] && set -x

ZONE="Zone1"
VNET_PREFIX="Vnet"
VNET_RANGE=""        # --vnet 5-10
OCTET_RANGE=""       # --octet 55-60
PREFIX="192.168"     # --prefix 192.168
PREFIXLEN=24         # --prefixlen 24
GW_LAST=1            # --gw 1
DHCP_LAST=35         # --dhcp 35 => .35-.35
SNAT=1               # --snat 0|1
DO_COMMIT=1          # --no-commit чтобы пропустить commit/reload

usage() {
  cat <<EOF
Usage:
  $0 --zone Zone1 --vnet 5-10 --octet 55-60 [--prefix 192.168] [--prefixlen 24] [--gw 1] [--dhcp 35] [--snat 1] [--no-commit]
Диапазоны должны быть одинаковой длины.
EOF
}

# --- args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --zone) ZONE="$2"; shift 2;;
    --vnet) VNET_RANGE="$2"; shift 2;;
    --octet) OCTET_RANGE="$2"; shift 2;;
    --prefix) PREFIX="$2"; shift 2;;
    --prefixlen) PREFIXLEN="$2"; shift 2;;
    --gw) GW_LAST="$2"; shift 2;;
    --dhcp) DHCP_LAST="$2"; shift 2;;
    --snat) SNAT="$2"; shift 2;;
    --no-commit) DO_COMMIT=0; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Неизвестный параметр: $1" >&2; usage; exit 1;;
  esac
done

# --- checks ---
if [[ $EUID -ne 0 ]]; then echo "Запусти от root." >&2; exit 1; fi
command -v pvesh >/dev/null 2>&1 || { echo "Не найден pvesh." >&2; exit 1; }

# Проверка и установка dnsmasq для работы DHCP в SDN
if ! dpkg -s dnsmasq >/dev/null 2>&1; then
  echo "Пакет 'dnsmasq' не найден (нужен для DHCP). Устанавливаем..."
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y dnsmasq >/dev/null 2>&1
  systemctl disable --now dnsmasq >/dev/null 2>&1 || true
  echo "'dnsmasq' успешно установлен и настроен."
fi

[[ -n "$VNET_RANGE" && -n "$OCTET_RANGE" ]] || { echo "Нужно --vnet A-B и --octet C-D."; usage; exit 1; }

if [[ ! "$VNET_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then echo "Неверный формат --vnet (A-B)." >&2; exit 1; fi
V_A="${BASH_REMATCH[1]}"; V_B="${BASH_REMATCH[2]}"

if [[ ! "$OCTET_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then echo "Неверный формат --octet (C-D)." >&2; exit 1; fi
O_A="${BASH_REMATCH[1]}"; O_B="${BASH_REMATCH[2]}"

if (( V_B < V_A || O_B < O_A )); then echo "Конец диапазона должен быть >= начала." >&2; exit 1; fi

count_v=$((V_B - V_A + 1))
count_o=$((O_B - O_A + 1))
if (( count_v != count_o )); then
  echo "Диапазоны разной длины: VNet=$count_v, Octet=$count_o." >&2
  exit 1
fi

# Проверим зону
if ! pvesh get "/cluster/sdn/zones/${ZONE}" >/dev/null 2>&1; then
  echo "Зона '${ZONE}' не найдена." >&2; exit 1
fi

echo "Zone=${ZONE}, Vnets=${V_A}-${V_B} (prefix=${VNET_PREFIX}), Octets=${O_A}-${O_B}, Subnet=${PREFIX}.X.0/${PREFIXLEN}, GW=.${GW_LAST}, DHCP=.${DHCP_LAST}-.${DHCP_LAST}, SNAT=${SNAT}"

for idx in $(seq 0 $((count_v - 1))); do
  vnum=$((V_A + idx))
  oct=$((O_A + idx))

  vnet="${VNET_PREFIX}${vnum}"
  subnet="${PREFIX}.${oct}.0/${PREFIXLEN}"
  cidr_enc="${PREFIX}.${oct}.0%2F${PREFIXLEN}"  # URL-encoded CIDR
  gw="${PREFIX}.${oct}.${GW_LAST}"
  dh_kv="start-address=${PREFIX}.${oct}.${DHCP_LAST},end-address=${PREFIX}.${oct}.${DHCP_LAST}"

  echo "==> ${vnet}: ${subnet}, GW ${gw}, DHCP ${PREFIX}.${oct}.${DHCP_LAST}-${PREFIX}.${oct}.${DHCP_LAST}"

  # 1) VNet ensure
  if pvesh get "/cluster/sdn/vnets/${vnet}" >/dev/null 2>&1; then
    echo "VNet ${vnet} уже существует — ок."
  else
    if ! pvesh create /cluster/sdn/vnets --vnet "${vnet}" --zone "${ZONE}"; then
      echo "Ошибка: не удалось создать VNet ${vnet}. Пропускаю." >&2
      continue
    fi
    echo "Создан VNet ${vnet}."
  fi

  # 2) Subnet upsert
  if pvesh set "/cluster/sdn/vnets/${vnet}/subnets/${cidr_enc}" \
      --gateway "${gw}" \
      --snat "${SNAT}" \
      --dhcp-range "${dh_kv}" >/dev/null 2>&1; then
    echo "Обновлена подсеть ${subnet}."
  elif pvesh create "/cluster/sdn/vnets/${vnet}/subnets" \
      --type subnet \
      --subnet "${subnet}" \
      --gateway "${gw}" \
      --snat "${SNAT}" \
      --dhcp-range "${dh_kv}" >/dev/null 2>&1; then
    echo "Добавлена подсеть ${subnet}."
  elif pvesh set "/cluster/sdn/vnets/${vnet}/subnets/${cidr_enc}" \
      --gateway "${gw}" \
      --snat "${SNAT}" \
      --dhcp-range "${dh_kv}" >/dev/null 2>&1; then
    echo "Обновлена подсеть ${subnet} (второй заход)."
  else
    echo "Внимание: не удалось ни создать, ни обновить подсеть ${subnet}." >&2
  fi

  # 3) Настройка Iptables (Интернет + Исключения + Изоляция)
  
  # 1. Разрешаем ВХОДЯЩИЙ трафик (ответы из интернета и серверов)
  if ! iptables -C FORWARD -d "${subnet}" -j ACCEPT >/dev/null 2>&1; then
    iptables -I FORWARD -d "${subnet}" -j ACCEPT
  fi

  # 2. Разрешаем ИСХОДЯЩИЙ трафик (запросы в интернет)
  if ! iptables -C FORWARD -s "${subnet}" -j ACCEPT >/dev/null 2>&1; then
    iptables -I FORWARD -s "${subnet}" -j ACCEPT
  fi

  # 3. БЛОКИРУЕМ доступ ко всей локальной сети (встанет выше пункта 2)
  if ! iptables -C FORWARD -s "${subnet}" -d "${PREFIX}.0.0/16" -j DROP >/dev/null 2>&1; then
    iptables -I FORWARD -s "${subnet}" -d "${PREFIX}.0.0/16" -j DROP
  fi

  # 4. РАЗРЕШАЕМ доступ к шаре 192.168.0.209 (встанет выше пункта 3)
  if ! iptables -C FORWARD -s "${subnet}" -d 192.168.0.209 -j ACCEPT >/dev/null 2>&1; then
    iptables -I FORWARD -s "${subnet}" -d 192.168.0.209 -j ACCEPT
  fi

  # 5. РАЗРЕШАЕМ доступ к серверу 192.168.0.10 (встанет на самый верх, выше пункта 4)
  if ! iptables -C FORWARD -s "${subnet}" -d 192.168.0.10 -j ACCEPT >/dev/null 2>&1; then
    iptables -I FORWARD -s "${subnet}" -d 192.168.0.10 -j ACCEPT
  fi
    # 6. РАЗРЕШАЕМ доступ к самому IP Proxmox (для Docker портов)
  if ! iptables -C FORWARD -s "${subnet}" -d 192.168.0.113 -j ACCEPT >/dev/null 2>&1; then
    iptables -I FORWARD -s "${subnet}" -d 192.168.0.113 -j ACCEPT
  fi
  if ! iptables -C INPUT -s "${subnet}" -d 192.168.0.113 -j ACCEPT >/dev/null 2>&1; then
    iptables -I INPUT -s "${subnet}" -d 192.168.0.113 -j ACCEPT
  fi
done

# --- commit (apply) ---
if [[ "$DO_COMMIT" -eq 1 ]]; then
  echo "Применение конфигурации SDN..."
  if pvesh set /cluster/sdn >/dev/null 2>&1; then
    echo "Конфигурация SDN успешно применена."
  else
    echo "Внимание: не удалось применить конфигурацию SDN." >&2
  fi
else
  echo "Пропуск применения конфигурации SDN (--no-commit)."
fi

echo "Готово."
