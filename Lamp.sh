#!/bin/bash
# =================================================================######
#  LAMP (Apache + MariaDB + PHP) Installer & Virtual Host Manager
#
#  Supported OS (tested):
#    RHEL / Rocky Linux / AlmaLinux / CentOS Stream 9+
#    Debian 12+ / Ubuntu 22.04+
#
#  Other distributions are NOT supported. Derivatives often lack packages or
#  provide-names this script depends on (epel-release, redhat-release,
#  mysql-selinux, $releasever_major, OpenSSL version ...), and cannot be
#  validated without testing each one.
#
#  More information: http://www.iewb.net
# ======================================================================

set -o pipefail

# -----------------------------------------------------------------------
# 常量
# -----------------------------------------------------------------------
readonly PUBLIC_DIR="/Data/Public_Root"
readonly MYSQL_DATA_DIR="/Data/sqldata"
readonly MIN_DATA_KB=512000          # /Data 可用空间下限 500MB
readonly PMA_VERSION="5.2.1"

# PHP / MariaDB 可选版本（与菜单一一对应）
readonly PHP_VERSIONS="7.4 8.1 8.3 8.5"
readonly MARIADB_VERSIONS="10.11 11.4 12.3 13.0"

# -----------------------------------------------------------------------
# 输出与错误处理
# -----------------------------------------------------------------------
c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_bold=$'\033[1m'; c_off=$'\033[0m'

info()  { echo -e "${c_green}[INFO]${c_off} $*"; }
warn()  { echo -e "${c_yellow}[WARN]${c_off} $*"; }
error() { echo -e "${c_red}[ERROR]${c_off} $*" >&2; }
die()   { error "$*"; exit 1; }

# 关键命令失败即中止
run() { "$@" || die "Command failed: $*"; }

# -----------------------------------------------------------------------
# 环境探测
# -----------------------------------------------------------------------
require_root() {
    [ "$(id -u)" = "0" ] || die "This script must be run as root."
    [ -e /etc/os-release ] || die "Unsupported system: /etc/os-release not found."
}

detect_os() {
    . /etc/os-release

    os_id=${ID:-unknown}
    os_name=${NAME:-$os_id}
    os_version_id=${VERSION_ID:-0}
    os_major=${os_version_id%%.*}
    # 上游 codename（衍生版如 Mint 需用 UBUNTU_CODENAME，否则 sury 源找不到套件）
    os_codename=${UBUNTU_CODENAME:-${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}}
    os_kernel=$(uname -sr)

    # Fedora 走自己的源体系，不在本脚本支持范围
    [ "$os_id" = "fedora" ] && die "Fedora is not supported (need EL8+ compatible repositories)."

    # ---- 发行版归类：显式 ID 优先，其余按 ID_LIKE 兜底 ----
    case "$os_id" in
        debian|ubuntu)
            OS_FAMILY="debian"
            ;;
        # RHEL 兼容发行版（含 ID_LIKE 不规范的少数国产/商业版）
        rhel|centos|rocky|almalinux|ol|cloudlinux|virtuozzo|vzlinux|eurolinux|circle|springdale|\
        opencloudos|anolis|alinux|tlinux|asianux|bclinux|kylin|uos|neokylin|openEuler|openeuler)
            OS_FAMILY="rhel"
            ;;
        *)
            case " ${ID_LIKE:-} " in
                *rhel*|*centos*|*fedora*) OS_FAMILY="rhel" ;;
                *debian*|*ubuntu*)        OS_FAMILY="debian" ;;
                *) die "Unsupported distribution: $os_id (ID_LIKE=${ID_LIKE:-none}). See script header for supported OS." ;;
            esac
            ;;
    esac

    # ---- 版本下限：RHEL 系 8+（已不支持 EL7），Debian 11+ / Ubuntu 20.04+ ----
    if [ "$OS_FAMILY" = "rhel" ]; then
        [ "$os_major" -ge 8 ] 2>/dev/null \
            || die "RHEL family version ${os_version_id} is too old. Need 8 or newer."
        if [ -e /etc/redhat-release ]; then
            os_release=$(cat /etc/redhat-release)
        else
            os_release="${os_name} ${os_version_id}"
        fi
    else
        case "$os_id" in
            debian)
                [ "$os_major" -ge 11 ] 2>/dev/null \
                    || die "Debian ${os_version_id} is too old. Need Debian 11 or newer."
                ;;
            ubuntu)
                # 20.04 = 20, 22.04 = 22 ...
                [ "$os_major" -ge 20 ] 2>/dev/null \
                    || die "Ubuntu ${os_version_id} is too old. Need Ubuntu 20.04 or newer."
                ;;
        esac
        [ -n "$os_codename" ] || die "Cannot detect Debian/Ubuntu codename (need VERSION_CODENAME)."
        os_release="${os_name} ${os_version_id} (${os_codename})"
    fi

    # 包管理器可用性
    if [ "$OS_FAMILY" = "rhel" ]; then
        command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1 \
            || die "Neither dnf nor yum found."
    else
        command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
    fi

    # Web / PHP 运行身份
    if [ "$OS_FAMILY" = "rhel" ]; then
        WEB_SERVICE="httpd"
        WEB_USER="apache"
        WEB_CONF_DIR="/etc/httpd/conf.d"
        SSL_CRT="/etc/pki/tls/certs/localhost.crt"
        SSL_KEY="/etc/pki/tls/private/localhost.key"
    else
        WEB_SERVICE="apache2"
        WEB_USER="www-data"
        WEB_CONF_DIR="/etc/apache2/sites-available"
        SSL_CRT="/etc/ssl/certs/localhost.crt"
        SSL_KEY="/etc/ssl/private/localhost.key"
    fi

    # CPU 架构（MariaDB 源路径用）
    case "$(uname -m)" in
        x86_64)          mariadb_arch="amd64" ;;
        aarch64|arm64)   mariadb_arch="aarch64" ;;
        *)               mariadb_arch="amd64" ;;
    esac

    echo -e "System-release: ${c_bold}${os_release}${c_off}"
    echo -e "Kernel        : ${c_bold}${os_kernel}${c_off}"
    echo -e "Family        : ${c_bold}${OS_FAMILY}${c_off}  |  Arch: ${c_bold}${mariadb_arch}${c_off}"
}

preflight() {
    command -v curl >/dev/null 2>&1 || warn "curl not found yet, it will be installed."
    mkdir -p "$PUBLIC_DIR" "$MYSQL_DATA_DIR"
    local avail_kb
    avail_kb=$(df --output=avail -k "$PUBLIC_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$avail_kb" ] && [ "$avail_kb" -lt "$MIN_DATA_KB" ]; then
        die "Not enough disk space on $(df "$PUBLIC_DIR" | awk 'NR==1{print $NF}') (need >= 500MB)."
    fi
}

# -----------------------------------------------------------------------
# 通用工具函数
# -----------------------------------------------------------------------
pkg_install() {
    if [ "$OS_FAMILY" = "rhel" ]; then
        # EL8+ 优先 dnf，老系统/最小化环境回退 yum
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y "$@"
        else
            yum install -y "$@"
        fi
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    fi
}

# 可选组件：失败只告警，不中断主流程
pkg_install_soft() {
    if ! pkg_install "$@"; then
        warn "Optional packages skipped: $*"
        return 1
    fi
}

# 逐包安装并容忍个别失败（用于扩展型组件），返回失败列表
pkg_install_each() {
    local failed=() p
    # 先整批装：一次事务完成，远快于逐个安装
    info "Installing optional packages..."
    if pkg_install "$@" >/dev/null 2>&1; then
        info "Optional packages installed."
        return 0
    fi
    # 整批失败（个别包在源中不存在）→ 退回逐个装，缺的跳过，并显示进度
    for p in "$@"; do
        printf "  - %-32s" "$p"
        if pkg_install "$p" >/dev/null 2>&1; then
            echo "ok"
        else
            echo "not available"
            failed+=("$p")
        fi
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        warn "Packages not available (missing from repos or network error): ${failed[*]}"
        return 1
    fi
    return 0
}

php_ver_compact() { echo "${1//./}"; }                 # 8.1 -> 81

php_fpm_service() {
    local v=$1
    if [ "$OS_FAMILY" = "rhel" ]; then echo "php$(php_ver_compact "$v")-php-fpm"
    else echo "php${v}-fpm"; fi
}

php_fpm_socket() {
    local v=$1
    if [ "$OS_FAMILY" = "rhel" ]; then
        echo "/var/opt/remi/php$(php_ver_compact "$v")/run/php-fpm/www.sock"
    else
        echo "/run/php/php${v}-fpm.sock"
    fi
}

php_ini_path() {
    local v=$1
    if [ "$OS_FAMILY" = "rhel" ]; then echo "/etc/opt/remi/php$(php_ver_compact "$v")/php.ini"
    else echo "/etc/php/${v}/fpm/php.ini"; fi
}

php_fpm_pool_path() {
    local v=$1
    if [ "$OS_FAMILY" = "rhel" ]; then echo "/etc/opt/remi/php$(php_ver_compact "$v")/php-fpm.d/www.conf"
    else echo "/etc/php/${v}/fpm/pool.d/www.conf"; fi
}

# 写 php.ini 配置项（已存在则覆盖，不存在则追加）
php_ini_set() {
    local file=$1 key=$2 val=$3
    [ -f "$file" ] || return 0
    if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
    else
        echo "${key} = ${val}" >> "$file"
    fi
}

# 写 FPM pool 配置项
pool_set() {
    local file=$1 key=$2 val=$3
    [ -f "$file" ] || return 0
    if grep -qE "^[;[:space:]]*${key}[[:space:]]*=" "$file"; then
        sed -i -E "s|^[;[:space:]]*${key}[[:space:]]*=.*|${key} = ${val}|" "$file"
    else
        echo "${key} = ${val}" >> "$file"
    fi
}

# 域名合法性校验（防路径穿越 / 注入）
valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

# SQL 字符串转义（单引号翻倍）
sql_escape() { echo "${1//\'/\'\'}"; }

# 下载文件（校验证书，失败返回非 0）
download() {
    local url=$1 dest=$2 timeout=${3:-20}
    curl -fsSL --connect-timeout 10 --max-time "$timeout" -o "$dest" "$url"
}

# 探测 URL 是否可用（HEAD 请求，跟随跳转），用于检查软件源是否收录了该发行版代号
url_exists() {
    curl -fsIL --connect-timeout 8 --max-time 15 -o /dev/null "$1" 2>/dev/null
}

# -----------------------------------------------------------------------
# 软件源安装
# -----------------------------------------------------------------------
# 清理历史残留的第三方源配置（上次安装失败可能留下坏源，导致 apt update 直接失败）
clean_stale_repo_files() {
    if [ "$OS_FAMILY" = "rhel" ]; then
        rm -f /etc/yum.repos.d/MariaDB.repo /etc/yum.repos.d/mariadb.repo
    else
        rm -f /etc/apt/sources.list.d/mariadb*.list \
              /etc/apt/sources.list.d/mariadb*.sources \
              /etc/apt/sources.list.d/MariaDB*.list 2>/dev/null || true
    fi
}

install_base_tools() {
    info "Installing base tools..."
    # 必须在第一次 apt update 之前清掉坏源，否则残留的 mariadb.list 会让 update 直接 die
    clean_stale_repo_files
    if [ "$OS_FAMILY" = "rhel" ]; then
        pkg_install curl wget unzip ca-certificates openssl logrotate || die "Failed to install base tools."
        # EPEL：先试发行版自带 epel-release，失败再用 Fedora 官方 RPM（覆盖 RHEL/CentOS/各种衍生版）
        if [ ! -e /etc/yum.repos.d/epel.repo ]; then
            pkg_install epel-release \
                || pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${os_major}.noarch.rpm" \
                || warn "EPEL install failed, continue without it."
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        export NEEDRESTART_MODE=a
        run apt-get update -y
        pkg_install curl wget unzip ca-certificates openssl logrotate apt-transport-https gnupg lsb-release \
            || die "Failed to install base tools."
    fi
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
    command -v unzip >/dev/null 2>&1 || die "unzip is required but not installed."
    command -v logrotate >/dev/null 2>&1 || die "logrotate is required but not installed."
}

# Remi 源修复：只补缺失的 dnf 变量，不动 repo 文件本身。
# Remi 的 repo 地址依赖自定义变量 $releasever_major；RHEL/CentOS/Rocky 的 release 包自带
# /etc/dnf/vars/releasever_major，而衍生版（如 OpenCloudOS）没有，导致 URL 里的变量
# 无法展开、请求打到畸形路径而 403。补上该文件后各发行版行为一致。
fix_remi_repo() {
    mkdir -p /etc/dnf/vars
    echo "$os_major" > /etc/dnf/vars/releasever_major
}

install_php_repo() {
    info "Configuring PHP repository..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        # Remi 发布的是 el 大版本号（remi-release-9.rpm），不能带 9.x 小版本
        local rel_pkg="https://rpms.remirepo.net/enterprise/remi-release-${os_major}.rpm"
        if ! rpm -q remi-release >/dev/null 2>&1; then
            if ! pkg_install "$rel_pkg"; then
                # remi-release 依赖 epel-release，而部分衍生版（如 OpenCloudOS）不打包 EPEL。
                # 该包本质只是仓库配置，绕过依赖安装即可。
                warn "dnf install remi-release failed, retrying with rpm --nodeps ..."
                local tmp_rpm="/tmp/remi-release-${os_major}.rpm"
                download "$rel_pkg" "$tmp_rpm" 60 \
                    || die "Failed to download ${rel_pkg}. Check network access to rpms.remirepo.net."
                rpm -ivh --nodeps "$tmp_rpm" \
                    || die "Failed to install remi-release (rpm --nodeps)."
                rm -f "$tmp_rpm"
            fi
        fi
        fix_remi_repo
    else
        # Ondřej Surý PHP 仓库
        local keyring_deb="/tmp/debsuryorg-archive-keyring.deb"
        download "https://packages.sury.org/debsuryorg-archive-keyring.deb" "$keyring_deb" 30 \
            || die "Failed to download sury.org keyring."
        run dpkg -i "$keyring_deb"
        rm -f "$keyring_deb"
        echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${os_codename} main" \
            > /etc/apt/sources.list.d/php.list
        run apt-get update -y
    fi
}

install_php() {
    local v=$1
    local compact
    compact=$(php_ver_compact "$v")
    info "Installing PHP ${v}..."

    # 分两层安装：核心扩展必须成功；其余扩展逐个装，个别缺失只告警。
    # 核心集合覆盖绝大多数 PHP 程序（WordPress/Drupal/Laravel/常见 CMS 等）。
    # 扩展包名在新 PHP/新发行版上时有缺漏（如 php8.5-opcache），不能因单个包失败而中断。
    if [ "$OS_FAMILY" = "rhel" ]; then
        # Remi SCL 并行安装包（phpXX-php-*），可多版本共存
        local pfx="php${compact}-php"
        run yum install -y \
            "${pfx}-fpm" \
            "${pfx}-cli" \
            "${pfx}-mbstring" \
            "${pfx}-mysqlnd" \
            "${pfx}-xml" \
            "${pfx}-curl"
        # 可选扩展：缺失只告警（json/sodium 在新版 PHP 已内置）
        pkg_install_each \
            "${pfx}-bcmath" \
            "${pfx}-gd" \
            "${pfx}-opcache" \
            "${pfx}-pdo" \
            "${pfx}-intl" \
            "${pfx}-sodium" \
            "${pfx}-zip" \
            "${pfx}-json" \
            "${pfx}-fileinfo" \
            "${pfx}-pecl-redis" \
            "${pfx}-pecl-imagick" || true
    else
        # Ondřej Surý 源：包名 phpX.Y-xxx
        run apt-get install -y \
            "php${v}-fpm" \
            "php${v}-cli" \
            "php${v}-mbstring" \
            "php${v}-mysql" \
            "php${v}-xml" \
            "php${v}-curl"
        # 可选扩展：缺失只告警（json/sodium 内置于 phpX.Y-common）
        pkg_install_each \
            "php${v}-bcmath" \
            "php${v}-gd" \
            "php${v}-opcache" \
            "php${v}-intl" \
            "php${v}-zip" \
            "php${v}-common" \
            "php${v}-fileinfo" \
            "php${v}-redis" \
            "php${v}-imagick" || true
    fi

    systemctl list-unit-files "$(php_fpm_service "$v").service" >/dev/null 2>&1 \
        || die "PHP-FPM service $(php_fpm_service "$v") not found after installation."
}

configure_php() {
    local v=$1
    local ini pool sock
    ini=$(php_ini_path "$v")
    pool=$(php_fpm_pool_path "$v")
    sock=$(php_fpm_socket "$v")

    info "Tuning PHP ${v}..."

    [ -f "$ini" ] || die "php.ini not found: $ini"

    # 生产常用项：兼顾大多数 PHP 程序
    php_ini_set "$ini" "upload_max_filesize"   "16M"
    php_ini_set "$ini" "post_max_size"         "16M"
    php_ini_set "$ini" "expose_php"            "Off"
    php_ini_set "$ini" "date.timezone"         "UTC"
    php_ini_set "$ini" "session.cookie_httponly" "1"
    php_ini_set "$ini" "mysqli.default_socket"  "$MYSQL_DATA_DIR/mysql.sock"
    php_ini_set "$ini" "pdo_mysql.default_socket" "$MYSQL_DATA_DIR/mysql.sock"

    # FPM 套接字权限：精确授权给 Web 用户，避免 0666 全局可写
    if [ -f "$pool" ]; then
        pool_set "$pool" "listen"       "$sock"
        pool_set "$pool" "listen.owner" "$WEB_USER"
        pool_set "$pool" "listen.group" "$WEB_USER"
        pool_set "$pool" "listen.mode"  "0660"
    fi

    run systemctl enable --now "$(php_fpm_service "$v")"
    run systemctl restart "$(php_fpm_service "$v")"

    # 确认套接字就绪
    local i
    for i in $(seq 1 15); do
        [ -S "$sock" ] && return 0
        sleep 1
    done
    die "PHP-FPM socket $sock was not created."
}

# -----------------------------------------------------------------------
# Apache
# -----------------------------------------------------------------------
install_apache() {
    info "Installing Apache..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        run yum install -y httpd mod_ssl openssl
        # headers 常随 httpd 一起提供；缺失则手动加载
        if ! grep -qs 'LoadModule headers_module' /etc/httpd/conf.modules.d/*.conf /etc/httpd/conf/httpd.conf; then
            echo 'LoadModule headers_module modules/mod_headers.so' >> /etc/httpd/conf/httpd.conf
        fi
    else
        run apt-get install -y apache2
        run a2enmod proxy proxy_fcgi proxy_http rewrite ssl headers setenvif
        # 关闭默认站点，避免与业务虚拟主机混淆
        a2dissite 000-default >/dev/null 2>&1 || true
    fi
}

configure_apache_security() {
    local conf
    if [ "$OS_FAMILY" = "rhel" ]; then
        conf="/etc/httpd/conf.d/security.conf"
    else
        conf="/etc/apache2/conf-available/lamp-security.conf"
    fi

    cat > "$conf" << 'EOF'
ServerTokens Prod
ServerSignature Off
<IfModule mod_headers.c>
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-Content-Type-Options "nosniff"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>
EOF

    if [ "$OS_FAMILY" = "debian" ]; then
        a2enconf lamp-security >/dev/null
    fi
    return 0
}

generate_ssl_cert() {
    [ -s "$SSL_CRT" ] && [ -s "$SSL_KEY" ] && return 0
    info "Generating local SSL certificate..."
    mkdir -p "$(dirname "$SSL_CRT")" "$(dirname "$SSL_KEY")"
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout "$SSL_KEY" -out "$SSL_CRT" \
        -subj "/C=XX/O=LAMP/CN=localhost" 2>/dev/null \
        || die "Failed to generate SSL certificate."
    chmod 600 "$SSL_KEY"
}

# 生成站点虚拟主机 + 独立日志切割
generate_vhost_config() {
    local dom=$1
    local p_ver=$2
    local sock
    sock=$(php_fpm_socket "$p_ver")

    local conf_file="${WEB_CONF_DIR}/${dom}.conf"
    local site_root="${PUBLIC_DIR}/${dom}/public_html"

    info "Writing vhost: $conf_file"

    cat > "$conf_file" << EOF
<Directory "${site_root}">
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

<VirtualHost *:80>
    ServerAdmin web@${dom}
    ServerName ${dom}
    ServerAlias www.${dom}
    DocumentRoot "${site_root}/"
    DirectoryIndex index.php index.html

    ErrorLog  "${PUBLIC_DIR}/${dom}/logs/error.log"
    CustomLog "${PUBLIC_DIR}/${dom}/logs/access.log" combined

    <IfModule mod_proxy_fcgi.c>
        <FilesMatch \.php$>
            SetHandler "proxy:unix:${sock}|fcgi://localhost"
        </FilesMatch>
    </IfModule>
</VirtualHost>

<VirtualHost *:443>
    ServerAdmin web@${dom}
    ServerName ${dom}
    ServerAlias www.${dom}
    DocumentRoot "${site_root}/"
    DirectoryIndex index.php index.html

    ErrorLog  "${PUBLIC_DIR}/${dom}/logs/error.log"
    CustomLog "${PUBLIC_DIR}/${dom}/logs/access.log" combined

    SSLEngine on
    SSLCertificateFile "${SSL_CRT}"
    SSLCertificateKeyFile "${SSL_KEY}"

    <IfModule mod_proxy_fcgi.c>
        <FilesMatch \.php$>
            SetHandler "proxy:unix:${sock}|fcgi://localhost"
        </FilesMatch>
    </IfModule>
</VirtualHost>
EOF

    # Debian 系需显式启用站点
    if [ "$OS_FAMILY" = "debian" ]; then
        a2ensite "${dom}.conf" >/dev/null
    fi

    cat > "/etc/logrotate.d/httpd-${dom}" << EOF
${PUBLIC_DIR}/${dom}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        /bin/systemctl reload ${WEB_SERVICE}.service > /dev/null 2>&1 || true
    endscript
}
EOF
}

# -----------------------------------------------------------------------
# MariaDB
# -----------------------------------------------------------------------
install_mariadb_repo() {
    local ver=$1
    info "Configuring MariaDB ${ver} repository..."

    # 再清一次残留源配置（install_base_tools 已清过；此处保证独立调用时也正确）
    clean_stale_repo_files

    if [ "$OS_FAMILY" = "rhel" ]; then
        cat > /etc/yum.repos.d/MariaDB.repo << EOF
[mariadb]
name = MariaDB
baseurl = https://yum.mariadb.org/${ver}/rhel${os_major}-${mariadb_arch}
gpgkey = https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck = 1
module_hotfixes = 1
EOF
        # 预导入签名密钥，安装时不再弹 GPG 确认
        rpm --import https://yum.mariadb.org/RPM-GPG-KEY-MariaDB 2>/dev/null || true
    else
        # MariaDB 官方源对新发行版的收录有滞后（如 Ubuntu 26.04 "resolute"）。
        # 安装前先探测代号是否可用，不可用则按「当前 -> 最近 LTS -> 更旧 LTS」回退。
        local suite="" probe c
        if [ "$os_id" = "ubuntu" ]; then
            for c in "$os_codename" noble jammy focal; do
                probe="https://deb.mariadb.org/${ver}/ubuntu/dists/${c}/Release"
                url_exists "$probe" && { suite=$c; break; }
            done
        else
            for c in "$os_codename" bookworm bullseye trixie; do
                probe="https://deb.mariadb.org/${ver}/debian/dists/${c}/Release"
                url_exists "$probe" && { suite=$c; break; }
            done
        fi

        if [ -z "$suite" ]; then
            die "MariaDB ${ver} apt repo has no release for ${os_name} ${os_version_id} (${os_codename}). \
Try another MariaDB version, or check https://deb.mariadb.org/${ver}/${os_id}/dists/"
        fi
        if [ "$suite" != "$os_codename" ]; then
            warn "MariaDB repo has no '${os_codename}' entry, falling back to '${suite}' (compatible packages)."
        fi

        mkdir -p /etc/apt/keyrings
        # MariaDB 官方密钥是 ASCII 装甲格式，apt 不认（"unsupported filetype"），
        # 必须用 gpg --dearmor 转成二进制 keyring 后才能用于 signed-by 校验。
        local key_raw="/tmp/mariadb-key-raw.pgp"
        download "https://mariadb.org/mariadb_release_signing_key.pgp" "$key_raw" 30 \
            || die "Failed to download MariaDB signing key."
        gpg --batch --yes --dearmor < "$key_raw" > /etc/apt/keyrings/mariadb-keyring.gpg 2>/dev/null \
            || die "Failed to convert MariaDB signing key (gpg --dearmor)."
        rm -f "$key_raw"
        chmod 644 /etc/apt/keyrings/mariadb-keyring.gpg
        cat > /etc/apt/sources.list.d/mariadb.list << EOF
deb [signed-by=/etc/apt/keyrings/mariadb-keyring.gpg] https://deb.mariadb.org/${ver}/${os_id} ${suite} main
EOF
        run apt-get update -y
    fi
}

# MariaDB-server 硬依赖 galera-4，galera-4 依赖 libboost_program_options。
# 该库在 RHEL 系的 CRB/PowerTools/devel 开发者源中，多数衍生版（如 OpenCloudOS）默认未启用。
# 只在这类源里找这一只包，不影响 PHP/MariaDB 的选源，也不永久启用开发者源。
ensure_boost_program_options() {
    rpm -q boost-program-options >/dev/null 2>&1 && return 0
    info "Installing boost-program-options (needed by galera-4)..."
    pkg_install boost-program-options && return 0

    # 按发行版常见命名逐个试；--enablerepo 仅本次事务生效，不写入配置
    local r
    for r in crb powertools devel CRB PowerTools Devel; do
        if pkg_install "--enablerepo=${r}" boost-program-options; then
            return 0
        fi
    done

    die "boost-program-options (needed by galera-4 / MariaDB-server) is not available. \
Enable your distro's devel/CRB/PowerTools repository and retry."
}

install_mariadb() {
    info "Installing MariaDB server..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        ensure_boost_program_options
        run yum install -y --enablerepo=mariadb mariadb mariadb-server
        command -v mysqld >/dev/null 2>&1 || die "mysqld not found after installation."
    else
        DEBIAN_FRONTEND=noninteractive run apt-get install -y mariadb-server mariadb-client
    fi
}

migrate_mariadb_datadir() {
    local conf_dir conf_file
    if [ "$OS_FAMILY" = "rhel" ]; then
        conf_dir="/etc/my.cnf.d"
    else
        conf_dir="/etc/mysql/mariadb.conf.d"
    fi
    conf_file="${conf_dir}/z-custom.cnf"

    # 已迁移过则跳过
    if [ -f "$conf_file" ] && grep -q "^datadir=${MYSQL_DATA_DIR}" "$conf_file" 2>/dev/null \
        && [ -d "${MYSQL_DATA_DIR}/mysql" ]; then
        info "MariaDB datadir already on ${MYSQL_DATA_DIR}, skip migration."
        return 0
    fi

    info "Migrating MariaDB datadir to ${MYSQL_DATA_DIR}..."
    mkdir -p "$MYSQL_DATA_DIR"

    # 先完成一次初始化，再搬数据
    run systemctl enable mariadb
    run systemctl start mariadb
    local i
    for i in $(seq 1 20); do
        mysqladmin ping >/dev/null 2>&1 && break
        [ "$i" = 20 ] && die "MariaDB failed to initialize."
        sleep 2
    done
    run systemctl stop mariadb

    if [ -d "${MYSQL_DATA_DIR}/mysql" ]; then
        local bak="${MYSQL_DATA_DIR}.bak.$(date +%Y%m%d%H%M%S)"
        warn "${MYSQL_DATA_DIR} already contains data, moving it to ${bak}"
        run mv "$MYSQL_DATA_DIR" "$bak"
        run mkdir -p "$MYSQL_DATA_DIR"
    fi

    if ! cp -a /var/lib/mysql/. "$MYSQL_DATA_DIR/"; then
        die "Failed to copy MariaDB data to ${MYSQL_DATA_DIR}."
    fi
    rm -rf /var/lib/mysql/*
    chown -R mysql:mysql "$MYSQL_DATA_DIR"

    # 字符集统一 utf8mb4；socket 统一到数据目录
    cat > "$conf_file" << EOF
[mysqld]
datadir = ${MYSQL_DATA_DIR}
socket = ${MYSQL_DATA_DIR}/mysql.sock
bind-address = 127.0.0.1
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
init_connect = 'SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci'
tmp_table_size = 64M
max_heap_table_size = 64M

[client]
socket = ${MYSQL_DATA_DIR}/mysql.sock
default-character-set = utf8mb4

[client-server]
socket = ${MYSQL_DATA_DIR}/mysql.sock
EOF

    # 兼容仍以默认路径找 socket 的程序
    mkdir -p /var/lib/mysql /run/mysqld
    chown mysql:mysql /var/lib/mysql /run/mysqld 2>/dev/null || true
    ln -sfn "${MYSQL_DATA_DIR}/mysql.sock" /var/lib/mysql/mysql.sock
    ln -sfn "${MYSQL_DATA_DIR}/mysql.sock" /run/mysqld/mysqld.sock
}

secure_mariadb() {
    local raw_passwd=$1
    local sql_passwd
    sql_passwd=$(sql_escape "$raw_passwd")

    info "Securing MariaDB and setting root password..."
    run systemctl start mariadb

    local ready=0 i
    for i in $(seq 1 20); do
        if mysql -u root -e "SELECT 1;" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 2
    done
    [ "$ready" = 1 ] || die "MariaDB did not become ready in time."

    mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('${sql_passwd}');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('${sql_passwd}');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db = 'test' OR Db LIKE 'test\\_%';
FLUSH PRIVILEGES;
EOF
}

# -----------------------------------------------------------------------
# 站点创建
# -----------------------------------------------------------------------
create_site() {
    local dom=$1
    local site="${PUBLIC_DIR}/${dom}"

    info "Creating site ${site}..."
    run mkdir -p "${site}/public_html" "${site}/logs"
    chmod 755 "${site}" "${site}/public_html"
    chmod 750 "${site}/logs"

    cat > "${site}/public_html/index.php" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>LAMP is ready</title>
<style>
  body { margin: 0; padding: 40px 16px; background: #f4f6f8; color: #24292f;
         font: 16px/1.6 system-ui, -apple-system, "Segoe UI", sans-serif; }
  .card { max-width: 720px; margin: 0 auto; background: #fff; border-radius: 12px;
          padding: 32px 36px; box-shadow: 0 8px 24px rgba(0,0,0,.06); }
  h1 { margin: 0 0 8px; font-size: 26px; color: #0b7a3e; }
  p.sub { margin: 0 0 24px; color: #57606a; }
  table { width: 100%; border-collapse: collapse; font-size: 14px; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #eaeef2; }
  th { width: 40%; color: #57606a; font-weight: 600; }
  code { background: #f6f8fa; padding: 2px 6px; border-radius: 4px; }
  .ok { color: #0b7a3e; font-weight: 600; }
  .miss { color: #cf222e; font-weight: 600; }
</style>
</head>
<body>
<div class="card">
  <h1>LAMP installation was successful!</h1>
  <p class="sub">Apache + MariaDB + PHP are ready. Replace <code>index.php</code> with your application.</p>
  <table>
    <tr><th>PHP version</th><td><code><?php echo htmlspecialchars(PHP_VERSION); ?></code></td></tr>
    <tr><th>Server API</th><td><code><?php echo htmlspecialchars(PHP_SAPI); ?></code></td></tr>
    <tr><th>Extension check</th><td>
<?php
$exts = array('bcmath','curl','gd','intl','mbstring','mysqli','openssl','pdo_mysql',
              'sodium','xml','zip','fileinfo','session');
$missing = array();
foreach ($exts as $e) {
    if (!extension_loaded($e)) { $missing[] = $e; }
}
if (!$missing) {
    echo '<span class="ok">All required extensions are loaded</span>';
} else {
    echo '<span class="miss">Missing: ' . htmlspecialchars(implode(', ', $missing)) . '</span>';
}
?>
    </td></tr>
    <tr><th>Document root</th><td><code><?php echo htmlspecialchars($_SERVER['DOCUMENT_ROOT'] ?? ''); ?></code></td></tr>
    <tr><th>Loaded config</th><td><code><?php echo htmlspecialchars(php_ini_loaded_file() ?: '(none)'); ?></code></td></tr>
  </table>
</div>
</body>
</html>
EOF
}

install_phpmyadmin() {
    local dom=$1
    local workdir
    workdir=$(mktemp -d /tmp/lamp-pma.XXXXXX)

    info "Installing phpMyAdmin into ${PUBLIC_DIR}/${dom}/public_html/phpmyadmin ..."
    local zip="${workdir}/pma.zip"
    if ! download "https://files.phpmyadmin.net/phpMyAdmin/${PMA_VERSION}/phpMyAdmin-${PMA_VERSION}-all-languages.zip" "$zip" 120; then
        warn "phpMyAdmin download failed, skipping."
        rm -rf "$workdir"
        return 1
    fi

    run unzip -q "$zip" -d "$workdir"
    rm -rf "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin"
    run mv "${workdir}/phpMyAdmin-${PMA_VERSION}-all-languages" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin"
    rm -rf "$workdir"

    # 精简暴露面：去掉文档与示例
    rm -rf "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/docs" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/examples" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/setup" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/composer.json" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/ChangeLog" \
           "${PUBLIC_DIR}/${dom}/public_html/phpmyadmin/LICENSE" 2>/dev/null || true

    info "phpMyAdmin installed. Suggested: protect /phpmyadmin with .htaccess or IP allow-list."
}

# -----------------------------------------------------------------------
# 防火墙 / SELinux
# -----------------------------------------------------------------------
open_firewall() {
    info "Configuring firewall..."
    if [ "$OS_FAMILY" = "rhel" ]; then
        if systemctl is-active firewalld >/dev/null 2>&1; then
            firewall-cmd --add-service=http --permanent    >/dev/null 2>&1 || true
            firewall-cmd --add-service=https --permanent   >/dev/null 2>&1 || true
            firewall-cmd --reload                          >/dev/null 2>&1 || true
        fi
        # /Data 自定义目录与 FPM socket 在 SELinux 下问题较多，生产常用做法：
        setenforce 0 2>/dev/null || true
        if [ -e /etc/selinux/config ]; then
            sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
        fi
    else
        if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
            ufw allow 80/tcp  >/dev/null 2>&1 || true
            ufw allow 443/tcp >/dev/null 2>&1 || true
        fi
    fi
}

# -----------------------------------------------------------------------
# 域名管理
# -----------------------------------------------------------------------
detect_current_php() {
    local v
    if [ "$OS_FAMILY" = "rhel" ]; then
        # 服务名形如 php85-php-fpm（85 = 8.5），主版本可能是多位数，只把最后一位当小版本
        v=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | grep -oE 'php[0-9]+-php-fpm' | head -n1 | grep -oE '[0-9]+')
        [ -n "$v" ] && echo "${v:0:$(( ${#v} - 1 ))}.${v: -1}"
    else
        v=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
            | grep -oE 'php[0-9]+\.[0-9]+-fpm' | head -n1 | sed -E 's/php([0-9.]+)-fpm/\1/')
        [ -n "$v" ] && echo "$v"
    fi
}

add_domain() {
    # 用 Web 服务是否存在判断是否已装 LAMP（PUBLIC_DIR 会被 preflight 创建，不能作依据）
    systemctl list-unit-files "${WEB_SERVICE}.service" >/dev/null 2>&1 \
        || die "LAMP environment not found (${WEB_SERVICE} is not installed). Please install first."

    local dom
    while :; do
        read -r -p "Please input your new domain: " dom
        if [ -z "$dom" ]; then
            echo "Domain cannot be empty."
        elif ! valid_domain "$dom"; then
            echo "Invalid domain format: $dom"
        elif [ -e "${PUBLIC_DIR}/${dom}" ]; then
            echo "Domain already exists: $dom"
        else
            break
        fi
    done

    local php_ver
    php_ver=$(detect_current_php)
    php_ver=${php_ver:-8.5}
    info "Using PHP ${php_ver} for ${dom}"

    run mkdir -p "${PUBLIC_DIR}/${dom}/public_html" "${PUBLIC_DIR}/${dom}/logs"
    generate_vhost_config "$dom" "$php_ver"

    [ -e "${PUBLIC_DIR}/${dom}/public_html/index.php" ] || \
        cat > "${PUBLIC_DIR}/${dom}/public_html/index.php" << EOF
<?php echo "Hello, ${dom}! Replace this file with your application.";
EOF

    run systemctl reload "$WEB_SERVICE"
    echo -e "${c_green}New domain added successfully: ${dom}${c_off}"
}

del_domain() {
    local dom
    while :; do
        read -r -p "Please input the domain you want to delete: " dom
        if [ -z "$dom" ]; then
            echo "Domain cannot be empty."
        elif ! valid_domain "$dom"; then
            echo "Invalid domain format: $dom"
        else
            break
        fi
    done

    if [ ! -e "${PUBLIC_DIR}/${dom}" ]; then
        echo "You haven't added the domain: $dom"
        return 1
    fi

    # 校验通过后再删，防止路径穿越
    rm -rf "${PUBLIC_DIR:?}/${dom}"
    rm -f "${WEB_CONF_DIR}/${dom}.conf"
    if [ "$OS_FAMILY" = "debian" ]; then
        a2dissite "${dom}.conf" >/dev/null 2>&1 || true
    fi
    rm -f "/etc/logrotate.d/httpd-${dom}"
    run systemctl reload "$WEB_SERVICE"
    echo "Your domain ${dom} has been successfully deleted."
}

# -----------------------------------------------------------------------
# 交互输入
# -----------------------------------------------------------------------
choose_php_version() {
    local v i=0
    echo
    for v in $PHP_VERSIONS; do
        i=$((i + 1))
        echo "${i}. PHP${v}"
    done
    local total=$i default_idx=$i
    local default_ver="${PHP_VERSIONS##* }"

    while :; do
        echo
        read -r -t 25 -p "Please choose the PHP version [${default_idx} for PHP${default_ver}]: " v
        v=${v:-$default_idx}
        case "$v" in
            1) php_version="7.4" ;;
            2) php_version="8.1" ;;
            3) php_version="8.3" ;;
            4) php_version="8.5" ;;
            *)
                echo "Your choice is not 1-${total}, will install PHP${default_ver}"
                php_version=$default_ver
                ;;
        esac
        break
    done
}

choose_mariadb_version() {
    local v i=0
    echo
    for v in $MARIADB_VERSIONS; do
        i=$((i + 1))
        echo "${i}. MariaDB ${v}"
    done
    local total=$i default_idx=3
    local default_ver="12.3"

    while :; do
        echo
        read -r -t 25 -p "Please choose the MariaDB version [${default_idx} for ${default_ver}]: " v
        v=${v:-$default_idx}
        case "$v" in
            1) mariadb_version="10.11" ;;
            2) mariadb_version="11.4" ;;
            3) mariadb_version="12.3" ;;
            4) mariadb_version="13.0" ;;
            *)
                echo "Your choice is not 1-${total}, will install MariaDB ${default_ver}"
                mariadb_version=$default_ver
                ;;
        esac
        break
    done
}

collect_install_input() {
    echo
    read -r -t 25 -p "Please enter your domain name or press Enter [test.com]: " domain
    domain=${domain:-test.com}
    if ! valid_domain "$domain"; then
        warn "Invalid domain '${domain}', fallback to test.com"
        domain="test.com"
    fi

    choose_php_version
    choose_mariadb_version

    echo
    while :; do
        read -r -s -p "Please input MariaDB root password: " dbpasswd
        echo
        if [ -z "$dbpasswd" ]; then
            echo "Password cannot be empty, please try again."
        elif [[ "$dbpasswd" == *"'"* ]]; then
            echo "Password cannot contain single quotes, please try again."
        elif [[ "$dbpasswd" == *"\\"* ]]; then
            # MySQL 字符串中反斜杠是转义符，会改变密码语义
            echo "Password cannot contain backslashes, please try again."
        else
            read -r -s -p "Confirm MariaDB root password: " dbpasswd2
            echo
            [ "$dbpasswd" = "$dbpasswd2" ] && break
            echo "Passwords do not match, please try again."
        fi
    done

    echo
    read -r -t 20 -p "Do you want to install phpMyAdmin [yes/no, default: no]: " phpmyadmin
    # 统一转小写再判断，接受 Yes/YES/y 等输入
    phpmyadmin=${phpmyadmin:-no}
    phpmyadmin=$(printf '%s' "$phpmyadmin" | tr '[:upper:]' '[:lower:]')
    case "$phpmyadmin" in
        yes|y) phpmyadmin="yes" ;;
        *)     phpmyadmin="no" ;;
    esac
}

# -----------------------------------------------------------------------
# 安装主流程
# -----------------------------------------------------------------------
do_install() {
    collect_install_input

    echo
    info "========== Installation summary =========="
    info "OS        : ${os_release}"
    info "Domain    : ${domain}"
    info "PHP       : ${php_version}"
    info "MariaDB   : ${mariadb_version}"
    info "phpMyAdmin: ${phpmyadmin}"
    info "Web root  : ${PUBLIC_DIR}/${domain}/public_html"
    info "=========================================="
    echo
    read -r -t 15 -p "Press Enter to continue (or wait 15s)... " _ || true

    install_base_tools
    install_php_repo
    install_php "$php_version"
    info "PHP done. Installing Apache..."
    install_apache
    info "Apache done. Configuring MariaDB repository..."
    install_mariadb_repo "$mariadb_version"
    info "Installing MariaDB server (this may take a while)..."
    install_mariadb

    configure_php "$php_version"
    configure_apache_security
    generate_ssl_cert
    info "Migrating MariaDB datadir and securing database..."
    migrate_mariadb_datadir
    secure_mariadb "$dbpasswd"

    create_site "$domain"
    generate_vhost_config "$domain" "$php_version"

    if [ "$phpmyadmin" = "yes" ]; then
        install_phpmyadmin "$domain"
    fi

    info "Configuring firewall and starting services..."
    open_firewall

    run systemctl enable "$WEB_SERVICE" mariadb
    run systemctl restart "$WEB_SERVICE" mariadb
    run systemctl restart "$(php_fpm_service "$php_version")"

    # 最终自检
    sleep 2
    if ! systemctl is-active --quiet "$WEB_SERVICE"; then
        die "${WEB_SERVICE} is not running. Check logs: journalctl -u ${WEB_SERVICE}"
    fi
    if ! systemctl is-active --quiet mariadb; then
        die "mariadb is not running. Check logs: journalctl -u mariadb"
    fi

    echo
    echo -e "${c_green}${c_bold}Your LAMP platform installation was successful!${c_off}"
    echo -e "${c_green}  Domain      : ${domain}${c_off}"
    echo -e "${c_green}  PHP         : PHP${php_version}  ($(php_fpm_socket "$php_version"))${c_off}"
    echo -e "${c_green}  MariaDB     : ${mariadb_version}  (datadir ${MYSQL_DATA_DIR})${c_off}"
    echo -e "${c_green}  Web root    : ${PUBLIC_DIR}/${domain}/public_html${c_off}"
    echo -e "${c_green}  DB root pwd : ${dbpasswd}${c_off}"
    echo -e "${c_yellow}  Note: index.php is a status page - replace it with your application.${c_off}"
}

# -----------------------------------------------------------------------
# 主菜单
# -----------------------------------------------------------------------
main() {
    require_root
    detect_os
    preflight

    echo
    echo "1. Install LAMP"
    echo "2. Add/Del a domain"
    read -r -p "Please choose what you want to do: " choice

    case "$choice" in
        1) do_install ;;
        2)
            echo
            echo "a. Add a domain"
            echo "b. Delete a domain"
            read -r -p "Please choose what you want to do: " sub
            case "$sub" in
                a) add_domain ;;
                b) del_domain ;;
                *) die "Please choose a valid item." ;;
            esac
            ;;
        *) die "Please choose a valid item." ;;
    esac
}

main "$@"
