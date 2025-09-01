#!/usr/bin/env bash
# shellcheck shell=bash
#===============================================================================
# Instalador idempotente do Zabbix Agent 2 (versão 7.0) com:
# - Detecção de distro/família e arquitetura
# - Instalação de repositório oficial e agente + plugins (quando disponíveis)
# - Fallback por download direto (APT/DNF/Zypper)
# - Validação de portas e seleção automática de servidor ativo
# - Escrita de configuração completa e segura
# - Habilitação e start do serviço via systemd
#
# Compatibilidade (famílias suportadas por este instalador):
#   - Debian/Ubuntu
#   - RHEL/AlmaLinux/Rocky/CentOS Stream/Oracle Linux
#   - SUSE/SLES
# NÃO SUPORTADO por este instalador (use outro método): Fedora, Amazon Linux, openSUSE.
#
# Parametrização por ambiente:
#   ZBX_SERVERS   : lista de FQDNs separada por vírgula (default: zbxdc1.claranet.com.br,zbxdc2.claranet.com.br,zbxdc3.claranet.com.br)
#   ZBX_PORT      : porta de ServerActive do Zabbix (default: 10051) APENAS CLARANET
#   ZBX_LISTEN    : porta do agente (default: ZBX_PORT-1)
#   ZBX_DEBUG     : nível de debug do agente (0..5, default: 3)
#   ZBX_METADATA  : HostMetadata (default: linux)
#
# Log: /tmp/install_zabbix.log
#===============================================================================

set -Eeuo pipefail

LOGFILE="/tmp/install_zabbix.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "==== Início da instalação do Zabbix Agent $(date) ===="

# root
if [[ $EUID -ne 0 ]]; then
  echo "ERRO: Este script precisa ser executado como root."
  exit 1
fi

# ---------- DETECÇÃO DE SO ----------
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${ID,,}"
  ID_LIKE_LC="${ID_LIKE,,}"
  VERSION_ID_FULL="$VERSION_ID"  # manter completo (10)
  VERSION_ID_MAJOR="${VERSION_ID%%.*}"
  VERSION_CODENAME="${VERSION_CODENAME:-}"
else
  echo "ERRO: /etc/os-release não encontrado."
  exit 1
fi

family=""
case "$DISTRO" in
  ubuntu|debian) family="debian" ;;
  rhel|centos|rocky|almalinux|ol|oracle) family="rhel" ;;
  sles|suse|sle*) family="suse" ;;
  fedora) family="fedora" ;;
  amzn|amazon) family="amazon" ;;
  opensuse*|tumbleweed|leap) family="opensuse" ;;
  *) ;;
esac

# Tenta por ID_LIKE quando ID não bate (20)
if [[ -z "$family" ]]; then
  if [[ "${ID_LIKE_LC:-}" == *"debian"* ]]; then family="debian"; fi
  if [[ "${ID_LIKE_LC:-}" == *"rhel"* || "${ID_LIKE_LC:-}" == *"fedora"* ]]; then family="${family:-rhel}"; fi
  if [[ "${ID_LIKE_LC:-}" == *"suse"* ]]; then family="suse"; fi
fi

if [[ -z "$family" ]]; then
  echo "ERRO: família de distribuição não suportada (ID=$DISTRO ID_LIKE=${ID_LIKE:-n/a})."
  exit 1
fi

# Bloqueia alvos não suportados por este instalador (evita 404/caminho errado)
if [[ "$family" == "fedora" || "$family" == "amazon" || "$family" == "opensuse" ]]; then
  echo "ERRO: $DISTRO não é suportado por este instalador via repositório oficial Zabbix 7.0."
  echo "Sugestões: usar pacotes do próprio OS, container do agente, ou adaptar para outro repo."
  exit 1
fi

# Define gerenciador disponível (2)
pkg_mgr=""
if command -v apt-get >/dev/null 2>&1; then
  pkg_mgr="apt"
elif command -v dnf >/dev/null 2>&1; then
  pkg_mgr="dnf"
elif command -v yum >/dev/null 2>&1; then
  pkg_mgr="yum"
elif command -v zypper >/dev/null 2>&1; then
  pkg_mgr="zypper"
else
  echo "ERRO: Nenhum gerenciador de pacotes suportado encontrado."
  exit 1
fi

echo "Distribuição: $DISTRO (família: $family), Versão: $VERSION_ID_FULL, Gerenciador: $pkg_mgr"

# ---------- PRÉ-REQUISITOS ----------
apt_updated=0
dnf_madecache=0
zypper_refreshed=0

install_pkgs() {
  local pkgs=("$@")
  case "$pkg_mgr" in
    apt)
      if [[ $apt_updated -eq 0 ]]; then
        apt-get update
        apt_updated=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      if [[ $dnf_madecache -eq 0 ]]; then
        dnf clean all -y || true
        dnf makecache -y || true
        dnf_madecache=1
      fi
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum clean all -y || true
      yum makecache -y || yum makecache fast || true
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      if [[ $zypper_refreshed -eq 0 ]]; then
        zypper --gpg-auto-import-keys refresh || true
        zypper_refreshed=1
      fi
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
  esac
}

need_install=()
# fetcher
if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  case "$family" in
    debian|suse|rhel) need_install+=("wget") ;;
  esac
fi
# nc
if ! command -v nc >/dev/null 2>&1; then
  case "$family" in
    debian|suse) need_install+=("netcat-openbsd") ;;
    rhel)        need_install+=("nmap-ncat") ;;
  esac
fi
if ((${#need_install[@]})); then
  echo "Instalando pré-requisitos: ${need_install[*]}"
  install_pkgs "${need_install[@]}"
fi

# download + HEAD
download_to() {
  local url="$1" dest="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -O "$dest" --tries=3 --timeout=15 "$url"
  else
    curl -fsSL --retry 3 --retry-delay 3 -o "$dest" "$url"
  fi
}
url_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsIL -L --retry 2 --retry-delay 2 --max-time 10 "$url" >/dev/null
  else
    wget --spider -q "$url"
  fi
}

# ---------- ESPAÇO EM DISCO ----------
MIN_DISK_MB=100
AVAILABLE_MB=$(df --output=avail / | tail -1)
AVAILABLE_MB=$((AVAILABLE_MB / 1024))
echo "Espaço disponível na raiz: ${AVAILABLE_MB}MB"
if (( AVAILABLE_MB < MIN_DISK_MB )); then
  echo "ERRO: Espaço em disco insuficiente (mínimo ${MIN_DISK_MB}MB)."
  exit 1
fi

# ---------- CHECAGEM DE PORTA ----------
check_port() {
  local host="$1" port="$2"
  if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q ' -z'; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  # fallback: tenta conectar em background e mata após 3s
  ( bash -lc "exec 3<>/dev/tcp/${host}/${port}" ) & local pid=$!
  sleep 3
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    return 1
  else
    wait "$pid" >/dev/null 2>&1
    return $?
  fi
}

ZABBIX_SERVERS=(zbxdc1.claranet.com.br zbxdc2.claranet.com.br zbxdc3.claranet.com.br)
ZABBIX_PORT=10051
LISTEN_PORT=$((ZABBIX_PORT - 1))
ZABBIX_SERVER=""

echo "Procurando servidor Zabbix ativo na porta $ZABBIX_PORT..."
for srv in "${ZABBIX_SERVERS[@]}"; do
  echo "Testando $srv..."
  if check_port "$srv" "$ZABBIX_PORT"; then
    echo "Servidor ativo encontrado: $srv"
    ZABBIX_SERVER="$srv"
    break
  else
    echo "Sem resposta de $srv"
  fi
done

if [[ -z "$ZABBIX_SERVER" ]]; then
  echo "ERRO: Nenhum servidor Zabbix ativo encontrado na porta $ZABBIX_PORT."
  exit 1
fi

# ---------- ARQUITETURA ----------
ARCH="$(uname -m)"
ARCH_NORM="x86_64"
case "$ARCH" in
  x86_64|amd64) ARCH_NORM="x86_64" ;;
  aarch64|arm64) ARCH_NORM="aarch64" ;;
  ppc64le) ARCH_NORM="ppc64le" ;;
  s390x) ARCH_NORM="s390x" ;;
  i386|i486|i586|i686) ARCH_NORM="i386" ;;
  armv7l|armv6l) ARCH_NORM="armhf" ;;
  *) ARCH_NORM="$ARCH" ;;
esac
echo "Arquitetura detectada: $ARCH (normalizada: $ARCH_NORM)"
if [[ "$ARCH_NORM" == "i386" || "$ARCH_NORM" == "armhf" ]]; then
  echo "ERRO: arquitetura ${ARCH} não suportada por este instalador (Zabbix Agent2 7.0 oficial)."
  exit 1
fi

ZBXCONF_PATH="/etc/zabbix/zabbix_agent2.conf"

backup_config() {
  if [[ -f "$1" ]]; then
    local backup="${1}.$(date +%Y%m%d%H%M%S).bak"
    cp -a "$1" "$backup"
    echo "Backup criado: $backup"
  fi
}

write_config() {
  install -d -m 0755 /etc/zabbix/zabbix_agent2.d /etc/zabbix/zabbix_agent2.d/plugins.d
  cat > "$ZBXCONF_PATH" <<EOF
ServerActive=$ZABBIX_SERVER:$ZABBIX_PORT
Server=$ZABBIX_SERVER
HostnameItem=system.hostname
PidFile=/var/run/zabbix/zabbix_agent2.pid
LogType=file
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=0
DebugLevel=3
ListenPort=$LISTEN_PORT
HostMetadata=linux
RefreshActiveChecks=300
BufferSend=60
BufferSize=1000
EnablePersistentBuffer=0
Timeout=30
Include=/etc/zabbix/zabbix_agent2.d/*.conf
UnsafeUserParameters=1
ControlSocket=/tmp/agent.sock
Plugins.Log.MaxLinesPerSecond=7
AllowKey=system.run[*]
Plugins.SystemRun.LogRemoteCommands=1
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
EOF
  echo "Arquivo de configuração atualizado em $ZBXCONF_PATH"
}

# ---------- VERIFICAÇÃO DE INSTALAÇÃO EXISTENTE ----------
if command -v zabbix_agent2 >/dev/null 2>&1; then
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet zabbix-agent2 2>/dev/null; then
    echo "Zabbix Agent2 já está instalado e ativo."
    zabbix_agent2 --version | head -n1 || true
    echo "Saindo."
    exit 0
  else
    echo "Zabbix Agent2 encontrado, porém inativo. Prosseguindo com reinstalação/configuração."
  fi
else
  echo "Zabbix Agent2 não encontrado. Prosseguindo com instalação."
fi

# ---------- LISTAGEM DE PLUGINS ----------
list_plugins_apt() {
  apt-cache --names-only search '^zabbix-agent2-plugin-' 2>/dev/null \
    | awk '{print $1}' | sed '/^$/d' || true
}
list_plugins_dnf() {
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-plugins-core >/dev/null 2>&1 || true
    dnf repoquery --qf '%{name}' --available 'zabbix-agent2-plugin-*' 2>/dev/null \
      | grep '^zabbix-agent2-plugin-' \
      | sort -u || true
  else
    yum list available 'zabbix-agent2-plugin-*' 2>/dev/null \
      | awk '/^zabbix-agent2-plugin-/{print $1}' | sort -u || true
  fi
}

list_plugins_zypper() {
  zypper -x se -t package 'zabbix-agent2-plugin-*' 2>/dev/null \
    | awk -F'"' '/<solvable /{
        for(i=1;i<=NF;i++){
          if($i ~ /^name=/){ gsub(/^name=/,"",$i); print $i }
        }
      }' | sort -u || true
}

# ------- FUNÇÕES AUXILIARES DE FALLBACK -------
fallback_dir="/tmp/zbx-fallback"
mkdir -p "$fallback_dir"

fallback_download() {
  # $1: URL  $2: destino
  local url="$1" dest="$2"
  echo "Baixando (fallback): $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --retry-delay 2 -o "$dest" "$url"
  else
    wget -O "$dest" --tries=3 --timeout=20 "$url"
  fi
}

# ---------- INSTALAÇÃO POR FAMÍLIA DE DISTRO ----------
install_rhel_family() {
  # Aviso para Stream
  if [[ "${VERSION,,}" == *"stream"* ]] || [[ "${PRETTY_NAME,,}" == *"stream"* ]]; then
    echo "Aviso: detectado *Stream*; tentando usar EL${VERSION_ID_MAJOR}."
  fi
  local ver_major="$VERSION_ID_MAJOR"
  local archdir="$ARCH_NORM"   # x86_64 | aarch64 | ppc64le | s390x
  local url="https://repo.zabbix.com/zabbix/7.0/rhel/${ver_major}/${archdir}/zabbix-release-latest-7.0.el${ver_major}.noarch.rpm"
  echo "Instalando repositório Zabbix para EL${ver_major} (${archdir})"
  url_ok "$url" || { echo "ERRO: pacote de release indisponível: $url"; exit 1; }
  local tmp="/tmp/zabbix-release.rpm"
  download_to "$url" "$tmp"
  rpm -Uvh "$tmp"
  rm -f "$tmp"

  dnf clean all -y || true
  dnf makecache -y

  # (Opcional) mostra os repos zabbix habilitados para debug
  dnf repolist zabbix\* || true

  # Lista plugins disponíveis (se falhar, seguimos só com o agente)
  mapfile -t plugins < <(list_plugins_dnf || true)

  echo "Instalando zabbix-agent2${plugins:+ + plugins (${#plugins[@]})}..."
  use_fallback=0
  if ((${#plugins[@]})); then
    if ! dnf install -y zabbix-agent2 "${plugins[@]}"; then
      use_fallback=1
    fi
  else
    if ! dnf install -y zabbix-agent2; then
      use_fallback=1
    fi
  fi

  if (( use_fallback )); then
    echo "Instalação via dnf falhou. Iniciando FALLBACK por URL…"

    # limpa diretório de fallback
    rm -rf "$fallback_dir" && mkdir -p "$fallback_dir"

    # agente: só a última URL
    mapfile -t agent_urls  < <(dnf repoquery --latest-limit 1 --location zabbix-agent2 2>/dev/null | grep -E '^https?://')

    # plugins: só a última URL de cada plugin (uma por pacote)
    if ((${#plugins[@]})); then
      mapfile -t plugin_urls < <(for p in "${plugins[@]}"; do dnf repoquery --latest-limit 1 --location "$p" 2>/dev/null | grep -E '^https?://'; done)
    else
      plugin_urls=()
    fi

    if ((${#agent_urls[@]}==0)); then
      echo "ERRO: não consegui resolver a URL do pacote zabbix-agent2 via repoquery."
      exit 1
    fi

    # Baixa tudo (pula linhas vazias/ruído)
    for u in "${agent_urls[@]}" "${plugin_urls[@]}"; do
      [[ -n "$u" ]] || continue
      base="$(basename "$u")"
      fallback_download "$u" "$fallback_dir/$base"
    done

    echo "Instalando RPMs baixados (fallback)…"
    shopt -s nullglob
    rpms=( "$fallback_dir"/*.rpm )
    if ((${#rpms[@]}==0)); then
      echo "ERRO: nenhum RPM foi baixado no fallback."
      exit 1
    fi
    rpm -Uvh --replacepkgs --replacefiles "${rpms[@]}"
    shopt -u nullglob
  fi

  # Valida instalação
  if ! rpm -q zabbix-agent2 >/dev/null 2>&1; then
    echo "ERRO: zabbix-agent2 não foi instalado. Verifique acesso ao repositório e dependências."
    exit 1
  fi
}

install_ubuntu() {
  echo "Resolvendo pacote de release do Zabbix para Ubuntu ${VERSION_ID_FULL}/${VERSION_CODENAME}"
  declare -a try_urls=(
    "https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu${VERSION_ID_FULL}_all.deb"
  )
  case "${VERSION_CODENAME,,}" in
    noble)  try_urls+=("https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu24.04_all.deb") ;;
    jammy)  try_urls+=("https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu22.04_all.deb") ;;
    focal)  try_urls+=("https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu20.04_all.deb") ;;
    bionic) try_urls+=("https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu18.04_all.deb") ;;
    *)      try_urls+=("https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_7.0+ubuntu${VERSION_ID_MAJOR}.04_all.deb") ;;
  esac

  local zbx_release_url=""
  for u in "${try_urls[@]}"; do
    if url_ok "$u"; then zbx_release_url="$u"; break; fi
  done
  [[ -z "$zbx_release_url" ]] && { echo "ERRO: não foi possível resolver pacote de release para Ubuntu ${VERSION_ID_FULL}."; exit 1; }

  echo "Instalando repositório: $zbx_release_url"
  local deb="/tmp/zabbix-release.deb"
  download_to "$zbx_release_url" "$deb"
  dpkg -i "$deb"
  rm -f "$deb"

  apt-get update
  mapfile -t plugins < <(list_plugins_apt)

  echo "Instalando zabbix-agent2${plugins:+ + plugins (${#plugins[@]})}..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2 "${plugins[@]}"; then
    echo "Instalação via APT falhou. Iniciando FALLBACK com 'apt-get download'…"
    pushd "$fallback_dir" >/dev/null
      apt-get update || true
      apt-get download zabbix-agent2 || true
      if ((${#plugins[@]})); then apt-get download "${plugins[@]}" || true; fi
      dpkg -i ./*.deb || true
      DEBIAN_FRONTEND=noninteractive apt-get -f install -y
    popd >/dev/null
  fi

  if ! command -v zabbix_agent2 >/dev/null 2>&1; then
    echo "ERRO: zabbix-agent2 não foi instalado (APT)."
    exit 1
  fi
}

install_debian() {
  local url="https://repo.zabbix.com/zabbix/7.0/debian/pool/main/z/zabbix-release/zabbix-release_latest_7.0+debian${VERSION_ID_MAJOR}_all.deb"
  echo "Instalando repositório Zabbix para Debian ${VERSION_ID_MAJOR}"
  url_ok "$url" || { echo "ERRO: pacote de release indisponível: $url"; exit 1; }

  local deb="/tmp/zabbix-release.deb"
  download_to "$url" "$deb"
  dpkg -i "$deb"
  rm -f "$deb"

  apt-get update
  mapfile -t plugins < <(list_plugins_apt)

  echo "Instalando zabbix-agent2${plugins:+ + plugins (${#plugins[@]})}..."
  if ! DEBIAN_FRONTEND=noninteractive apt-get install -y zabbix-agent2 "${plugins[@]}"; then
    echo "Instalação via APT falhou. Iniciando FALLBACK com 'apt-get download'…"
    pushd "$fallback_dir" >/dev/null
      apt-get update || true
      apt-get download zabbix-agent2 || true
      if ((${#plugins[@]})); then apt-get download "${plugins[@]}" || true; fi
      dpkg -i ./*.deb || true
      DEBIAN_FRONTEND=noninteractive apt-get -f install -y
    popd >/dev/null
  fi

  if ! command -v zabbix_agent2 >/dev/null 2>&1; then
    echo "ERRO: zabbix-agent2 não foi instalado (APT)."
    exit 1
  fi
}

install_suse() {
  local ver_major="$VERSION_ID_MAJOR"
  local archdir="$ARCH_NORM"   # x86_64 | aarch64 | ppc64le | s390x
  echo "Instalando repositório Zabbix para SLES ${ver_major} (${archdir})"

  if ! zypper lr | grep -q 'Enabled.*Yes'; then
    echo "Nenhum repositório SUSE habilitado."
    exit 1
  fi

  local url="https://repo.zabbix.com/zabbix/7.0/sles/${ver_major}/${archdir}/zabbix-release-latest-7.0.sles${ver_major}.noarch.rpm"
  url_ok "$url" || { echo "ERRO: pacote de release indisponível: $url"; exit 1; }
  rpm -Uvh --nosignature "$url"

  zypper --gpg-auto-import-keys -n refresh
  # deps opcionais – se falhar, segue
  zypper -n install mongodb-tools msodbcsql17 || true

  mapfile -t plugins < <(list_plugins_zypper)

  echo "Instalando zabbix-agent2${plugins:+ + plugins (${#plugins[@]})}..."
  if ! zypper --non-interactive --no-confirm install -y zabbix-agent2 "${plugins[@]}"; then
    echo "Instalação via zypper falhou. Iniciando FALLBACK com 'zypper download'…"
    pushd "$fallback_dir" >/dev/null
      zypper --non-interactive download zabbix-agent2 || true
      if ((${#plugins[@]})); then zypper --non-interactive download "${plugins[@]}" || true; fi
      rpm -Uvh --replacepkgs --replacefiles ./*.rpm
    popd >/dev/null
  fi

  if ! command -v zabbix_agent2 >/dev/null 2>&1; then
    echo "ERRO: zabbix-agent2 não foi instalado (zypper)."
    exit 1
  fi
}

case "$family" in
  debian)
    if [[ "$DISTRO" == "ubuntu" ]]; then
      install_ubuntu
    else
      install_debian
    fi
    ;;
  rhel)
    install_rhel_family
    ;;
  suse)
    install_suse
    ;;
  *)
    echo "ERRO: família desconhecida (DISTRO=$DISTRO). Distribuição não suportada."
    exit 1
    ;;
esac

# ---------- VERIFICAÇÕES PÓS-INSTALAÇÃO ----------
if ! command -v zabbix_agent2 >/dev/null 2>&1; then
  echo "ERRO: zabbix_agent2 não encontrado no PATH após a instalação."
  exit 1
fi

# Garante que o systemd leia units novos
systemctl daemon-reload || true

# ---------- CONFIGURAÇÃO ----------
# para evitar corrida com o postinstall, pare antes de trocar a config
systemctl stop zabbix-agent2 2>/dev/null || true

backup_config "$ZBXCONF_PATH"
write_config

# Confirma que o unit existe olhando o filesystem (mais confiável que parsear list-unit-files)
if ! [[ -f /usr/lib/systemd/system/zabbix-agent2.service || -f /etc/systemd/system/zabbix-agent2.service ]]; then
  echo "ERRO: zabbix-agent2.service não foi encontrado no filesystem (instalação incompleta)."
  echo "Debug: rpm -ql zabbix-agent2 | grep -E '/(usr/)?lib/systemd/system/zabbix-agent2\.service' || true"
  exit 1
fi

# ---------- CONTROLE DO SERVIÇO ----------
echo "Habilitando e iniciando zabbix-agent2 via systemd"
systemctl daemon-reload || true
systemctl enable --now zabbix-agent2

sleep 2
if systemctl is-active --quiet zabbix-agent2; then
  echo "Zabbix Agent2 está ativo e rodando."
  # valida se a config aplicada realmente está no arquivo
  echo "Checando parâmetros aplicados:"
  egrep '^(ServerActive|Server|ListenPort)=' "$ZBXCONF_PATH" || true
else
  echo "ERRO: Zabbix Agent2 não está rodando após o start."
  journalctl -u zabbix-agent2 -n 100 --no-pager || true
  exit 1
fi