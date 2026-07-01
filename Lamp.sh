#!/bin/bash
# =================================================================######
#  Install LAMP & Manage Virtual Hosts for CentOS/Rocky/AlmaLinux
#  Supported OS: CentOS 7+, Rocky Linux 8/9/10/11+, AlmaLinux 8/9/10+
#  More information: http://www.iewb.net
# =================================================================######

# 检查是否为 root 用户
[ "$(id -u)" != "0" ] && { echo -e "\033[31mError: This script must be run as root!\033[0m"; exit 1; } 
[ ! -e '/etc/redhat-release' ] && { echo -e "\033[31mError: This script is not supported on your system.\033[0m"; exit 1; } 

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
clear

printf "
#######################################################################
#                Install LAMP for CentOS/Rocky/AlmaLinux
#              More information http://www.iewb.net
#######################################################################
"

# 解析系统环境信息
os_name=$(awk -F= '/^NAME/{print $2}' /etc/os-release | awk -F'"' '{print $2}')
os_version_id=$(awk -F= '/^VERSION_ID/{print $2}' /etc/os-release | awk -F'"' '{print $2}')
os_version_id2=$(echo "$os_version_id" | awk -F'.' '{print $1}')
os_release=$(cat /etc/redhat-release)
os_kernel=$(uname -sr)

echo -e "System-release:\e[1;32m $os_release \e[0m"
echo -e "Kernel:\e[1;32m $os_kernel \e[0m"

public_dir="/Data/Public_Root"

# -----------------------------------------------------------------------
# 公共函数：生成 Apache 虚拟主机配置（完美支持多版本 PHP-FPM 反向代理）
# -----------------------------------------------------------------------
generate_vhost_config() {
    local dom=$1
    local p_dir=$2
    local p_ver=$3
    local conf_file="/etc/httpd/conf.d/${dom}.conf"

    # 生成专属目录权限控制与站点虚拟主机
    cat > "$conf_file" << EOF
<Directory "${p_dir}/${dom}/public_html">
    Options FollowSymlinks
    AllowOverride All
    Require all granted
</Directory>

<VirtualHost *:80>
    ServerAdmin web@${dom}
    ServerName ${dom}
    ServerAlias www.${dom}
    DocumentRoot "${p_dir}/${dom}/public_html/"
    ErrorLog "${p_dir}/${dom}/logs/error.log"
    CustomLog "${p_dir}/${dom}/logs/access.log" combined

    # 针对现代系统的多版本 PHP-FPM 进行反向代理绑定
    <IfModule mod_proxy_fcgi.c>
        <FilesMatch \.php$>
EOF

    if [ "$os_version_id2" = "7" ] && [ "$p_ver" = "54" ]; then
        # CentOS 7 使用传统的 TCP 端口代理或标准单版本模式
        echo "            SetHandler \"proxy:fcgi://127.0.0.1:9000\"" >> "$conf_file"
    else
        # Rocky/AlmaLinux/CentOS 动态匹配 Remi 多版本对应的本地套接字 (Socket)
        echo "            SetHandler \"proxy:unix:/var/opt/remi/php${p_ver}/run/php-fpm/www.sock|fcgi://localhost\"" >> "$conf_file"
    fi

    cat >> "$conf_file" << EOF
        </FilesMatch>
    </IfModule>
</VirtualHost>
EOF

    # 为该域名生成独立的独立日志切割配置
    cat > "/etc/logrotate.d/httpd-${dom}" << EOF
${p_dir}/${dom}/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    sharedscripts
    postrotate
        /bin/systemctl reload httpd.service > /dev/null 2>/dev/null || true
    endscript
}
EOF
}

# -----------------------------------------------------------------------
# 主菜单逻辑
# -----------------------------------------------------------------------
echo "1. Install LAMP"
echo "2. Add/Del a domain"
read -p "Please choose what you want to do: " i

case "$i" in
    1)
        # 1. 输入域名
        while :; do echo
            read -t 25 -p "Please enter your domain name or press Enter [test.com]: " domain
            domain=${domain:-test.com}
            [ -n "$domain" ] && break
        done

        # 2. 选择 PHP 版本
        while :; do echo
            echo "1. PHP5.4 (CentOS 7 Only)"
            echo "2. PHP7.4"
            echo "3. PHP8.1"
            echo "4. PHP8.3"
            echo "5. PHP8.5"
            read -t 25 -p "Please choose the PHP version [5 for PHP8.5]: " v    
            case "$v" in
                1) php_version=54 ;;
                2) php_version=74 ;;
                3) php_version=81 ;;
                4) php_version=83 ;;
                5) php_version=85 ;;
                *)
                    echo "Your choice is not 1-5, will install php8.5"
                    php_version=85
                    ;;     
            esac
            [ -n "$php_version" ] && break
        done

        # 3. 选择 MariaDB 版本
        while :; do echo
            echo "1. MariaDB 10.11"
            echo "2. MariaDB 11.4"
            echo "3. MariaDB 12.3"
            echo "4. MariaDB 13.0"
            read -t 25 -p "Please choose the MariaDB version [3 for 12.3]: " v1
            case "$v1" in
                1) MariaDB_version=10.11 ;;
                2) MariaDB_version=11.4 ;;
                3) MariaDB_version=12.3 ;;
                4) MariaDB_version=13.0 ;;
                *)
                    echo "Your choice is not 1-4, will install MariaDB 12.3"
                    MariaDB_version=12.3
                    ;;
            esac
            [ -n "$MariaDB_version" ] && break
        done

        # 4. 输入数据库密码
        while :; do echo
            read -p "Please input MariaDB root password: " dbpasswd
            [ -n "$dbpasswd" ] && break
            echo "Password cannot be empty, please try again."
        done

        # 5. 是否安装 phpMyAdmin
        while :; do echo
            read -t 20 -p "Do you want to install phpmyadmin [yes/no, default: yes]: " phpmyadmin
            phpmyadmin=${phpmyadmin:-yes}
            [ -n "$phpmyadmin" ] && break
        done

        # --- 开始安装基础源 ---
        if [ "$os_name" = "CentOS Stream" ]; then
            dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$os_version_id.noarch.rpm
        elif [ ! -e '/etc/yum.repos.d/epel.repo' ]; then
            yum -y install epel-release
        fi

        # --- 安装 PHP 环境 ---
        if [ "$os_version_id2" = "7" ]; then
            # CentOS 7 经典兼容分支源调整
            sed -i 's/mirrorlist=/#mirrorlist=/g' /etc/yum.repos.d/CentOS-*
            sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
            rpm -ivh https://rpms.remirepo.net/enterprise/remi-release-$os_version_id.rpm --force --nodeps
        else
            # Rocky / AlmaLinux 8/9/10+ 现代主流分支
            dnf install -y http://rpms.remirepo.net/enterprise/remi-release-$os_version_id.rpm
        fi

        # 统一使用 Remi 多版本软件集安装，防止版本冲突
        if [ "$os_version_id2" = "7" ] && [ "$php_version" = "54" ]; then
            yum install --enablerepo=remi php php-opcache php-devel php-mbstring php-mysqlnd php-bcmath php-gd php-common php-xml php-curl -y
            ini_file="/etc/php.ini"
            fpm_service="php-fpm"
        else
            yum install -y --enablerepo=remi php${php_version}-php-fpm php${php_version}-php-cli php${php_version}-php-bcmath php${php_version}-php-gd php${php_version}-php-json php${php_version}-php-mbstring php${php_version}-php-mysqlnd php${php_version}-php-opcache php${php_version}-php-pdo php${php_version}-php-xml php${php_version}-php-intl php${php_version}-php-zip php${php_version}-php-curl php${php_version}-php-pecl-redis php${php_version}-php-pecl-imagick
            ini_file="/etc/opt/remi/php${php_version}/php.ini"
            fpm_service="php${php_version}-php-fpm"
        fi
        
        if [ -e "$ini_file" ]; then
            sed -i 's/upload_max_filesize = 2M/upload_max_filesize = 16M/g' "$ini_file"
            sed -i 's/expose_php = On/expose_php = Off/g' "$ini_file"
        fi

        systemctl enable $fpm_service
        systemctl restart $fpm_service

        # 自动修复 FPM 权限过严导致 Apache 503 的问题
        fpm_conf="/etc/opt/remi/php${php_version}/php-fpm.d/www.conf"
        [ ! -e "$fpm_conf" ] && fpm_conf="/etc/php-fpm.d/www.conf"
        if [ -e "$fpm_conf" ]; then
            sed -i 's/;listen.mode = 0660/listen.mode = 0666/g' "$fpm_conf"
            sed -i 's/listen.mode = 0660/listen.mode = 0666/g' "$fpm_conf"
            systemctl restart $fpm_service
        fi

        # --- 安装 MariaDB 数据库 ---
        if [ ! -e /etc/yum.repos.d/MariaDB.repo ]; then
            cat > /etc/yum.repos.d/MariaDB.repo << EOF
[mariadb]
name = MariaDB
baseurl = https://yum.mariadb.org/$MariaDB_version/rhel$os_version_id2-amd64
gpgkey = https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF
        fi
        yum install --enablerepo=mariadb mariadb mariadb-server -y
        [ ! -e /usr/sbin/mysqld ] && yum install mariadb mariadb-server -y

        # --- 安装 Apache Web 服务 ---
        yum --enablerepo=epel install libargon2 libmcrypt -y 2>/dev/null || true
        yum install httpd mod_ssl openssl unzip wget -y
        command -v unzip &>/dev/null || { echo -e "\033[31mError: unzip installation failed.\033[0m"; exit 1; }

        # --- Apache 安全加固 ---
        cat > /etc/httpd/conf.d/security.conf << 'EOF'
ServerTokens Prod
ServerSignature Off
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
EOF
        grep -q 'LoadModule headers_module' /etc/httpd/conf.modules.d/*.conf 2>/dev/null || \
        echo 'LoadModule headers_module modules/mod_headers.so' >> /etc/httpd/conf/httpd.conf

        yum install -y gd gd-devel freetype freetype-devel libpng libpng-devel libjpeg libjpeg-devel 2>/dev/null || true

        # --- 创建站点目录与测试页 ---
        mkdir -p "$public_dir/$domain/public_html" "$public_dir/$domain/logs"
        
        cat > "$public_dir/$domain/public_html/index.php" << EOF
<html>
<head>
<title>LAMP Test Page!</title>
<style type="text/css">
* { margin:0; padding:0; }
body { margin:0 auto; font-size:12px; font-family:Verdana; line-height:150%; }
ul { list-style:none; }
h1 { font-size:18px; }
.clearfloat { clear:both; height:0; font-size: 1px; line-height: 0; }
#container{ margin:0 auto; width:940px; }
#header { height:45px; background:#cf0; }
#header h1 { padding:10px 20px; }
#nav { background:#FF6600; height:25px; margin-bottom:6px; padding:5px; }
#nav ul li { float:left; }
#nav ul li a { display:block; padding:4px 10px 2px 10px; color:#000; text-decoration:none; }
#nav ul li a:hover { text-decoration:underline; background:#06f; color:#FFF; }
</style>
</head>
<body><center>
<div id="container">
  <div id="header">
    <h1>LAMP installation was successful!</h1>
  </div>
  <div class="clearfloat"></div>
  <div id="nav">
    <ul>
      <li><a href="./t.php">PHP Info</a></li>
      <li><a href="./phpmyadmin">PHPMyAdmin</a></li>
      <li><a href="http://www.iewb.net">MyBlog</a></li>
    </ul>
  </div>
</div>
</center>
<?php phpinfo(); ?>
</body>
</html>
EOF

        # 下载服务器探针 (带防失败回退)
        wget -T 10 -O yhtz.zip https://static.lty.fun/%E5%85%B6%E4%BB%96%E8%B5%84%E6%BA%90/Status-TZ/yhtz7-https.zip --no-check-certificate -q
        if [ -f yhtz.zip ]; then
            unzip -o -q yhtz.zip && mv yhtz7-https.php "$public_dir/$domain/public_html/t.php"
            rm -f yhtz.zip
        else
            echo "<?php phpinfo(); ?>" > "$public_dir/$domain/public_html/t.php"
        fi

        # 安装 phpMyAdmin
        if [ "$phpmyadmin" != "no" ]; then
            wget -T 15 https://files.phpmyadmin.net/phpMyAdmin/5.2.1/phpMyAdmin-5.2.1-all-languages.zip --no-check-certificate -q
            if [ -f phpMyAdmin-5.2.1-all-languages.zip ]; then
                unzip -o -q ./phpMyAdmin-5.2.1-all-languages.zip
                mv phpMyAdmin-5.2.1-all-languages "$public_dir/$domain/public_html/phpmyadmin"
                rm -f phpMyAdmin-5.2.1-all-languages.zip
            fi
        fi

        # 生成虚拟主机配置
        generate_vhost_config "$domain" "$public_dir" "$php_version"

        # 防火墙与 SELinux 放行
        if command -v firewall-cmd &>/dev/null; then
            firewall-cmd --add-service=http --permanent 2>/dev/null
            firewall-cmd --add-service=https --permanent 2>/dev/null
            firewall-cmd --reload 2>/dev/null
        fi
        setenforce 0 2>/dev/null || true
        [ -e /etc/selinux/config ] && sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

        # --- 安全迁移 MariaDB 数据目录 ---
        avail_kb=$(df /Data 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$avail_kb" ] && [ "$avail_kb" -lt 512000 ]; then
            echo -e "\033[31mError: Not enough disk space on /Data (need at least 500MB). Aborting migration.\033[0m"
            exit 1
        fi

        systemctl start mariadb
        sleep 2
        systemctl stop mariadb
        mkdir -p /Data/sqldata

        if [ -d "/Data/sqldata/mysql" ]; then
            mv /Data/sqldata /Data/sqldata.bak.$(date +%Y%m%d%H%M%S)
            mkdir -p /Data/sqldata
            echo -e "\033[33mWarning: /Data/sqldata already exists, backed up.\033[0m"
        fi

        if cp -a /var/lib/mysql/* /Data/sqldata/; then
            rm -rf /var/lib/mysql/*
        else
            echo -e "\033[31mError: Failed to copy MariaDB data.\033[0m"
            exit 1
        fi
        chown -R mysql:mysql /Data/sqldata

        cat > /etc/my.cnf.d/z-custom.cnf << EOF
[mysqld]
datadir=/Data/sqldata
socket=/Data/sqldata/mysql.sock
init_connect='SET collation_connection = utf8mb4_unicode_ci'
init_connect='SET NAMES utf8mb4'
character_set_server=utf8mb4
collation-server=utf8mb4_unicode_ci
skip-character-set-client-handshake=true
tmp_table_size = 128M
max_heap_table_size = 128M

[client]
socket=/Data/sqldata/mysql.sock

[client-server]
socket=/Data/sqldata/mysql.sock
EOF
        rm -f /var/lib/mysql/mysql.sock
        ln -s /Data/sqldata/mysql.sock /var/lib/mysql/mysql.sock

        # 生成本地默认 SSL 证书
        if [ ! -s "/etc/pki/tls/certs/localhost.crt" ]; then
            mkdir -p /etc/pki/tls/private /etc/pki/tls/certs
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/pki/tls/private/localhost.key -out /etc/pki/tls/certs/localhost.crt -subj "/C=XX/L=DefaultCity/O=DefaultCompany" 2>/dev/null
        fi

        systemctl start mariadb httpd
        systemctl enable mariadb httpd

        # 等待 MariaDB 完全就绪后再改密
        db_ready=0
        for i in $(seq 1 10); do
            if mysql -u root -e "SELECT 1;" &>/dev/null; then
                db_ready=1
                break
            fi
            sleep 2
        done

        if [ "$db_ready" -eq 1 ]; then
            mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${dbpasswd}');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED VIA mysql_native_password USING PASSWORD('${dbpasswd}');
GRANT ALL PRIVILEGES ON *.* TO 'root'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
        else
            echo -e "\033[31mError: MariaDB did not start in time. Password not set.\033[0m"
        fi

        clear
        echo -e "\033[32mYour LAMP Platform installation was successful!\033[0m"
        echo -e "\033[32mPHP Version: php${php_version} | MariaDB Root Password: ${dbpasswd}\033[0m"
        ;;

    2)
        echo "a. Add a domain"
        echo "b. Delete a domain"
        read -p "Please choose what you want to do: " i2
        case "$i2" in
            a)
                while :; do echo
                    read -p "Please input your new domain: " adddomain 
                    [ -n "$adddomain" ] && break
                done

                if [ -e "$public_dir" ]; then
                    mkdir -p "$public_dir/$adddomain/public_html" "$public_dir/$adddomain/logs"
                    
                    # 智能获取系统内激活的 Remi PHP FPM 版本
                    current_php=$(systemctl list-units --type=service --state=running | grep -oE 'php[0-9]+-php-fpm' | head -n1 | grep -oE '[0-9]+')
                    current_php=${current_php:-85}

                    generate_vhost_config "$adddomain" "$public_dir" "$current_php"

                    if [ ! -e "$public_dir/$adddomain/public_html/index.php" ]; then
                        echo "<?php phpinfo(); ?>" > "$public_dir/$adddomain/public_html/index.php"
                    fi
                    systemctl restart httpd
                    clear
                    echo -e "\033[32mNew domain added successfully: $adddomain\033[0m"
                else
                    echo "You haven't installed the LAMP environment yet..."
                fi
                ;;
            b)
                while :; do echo
                    read -p "Please input the domain you want to delete: " deldomain
                    [ -n "$deldomain" ] && break
                done
                if [ -e "$public_dir/$deldomain" ]; then
                    rm -rf "$public_dir/$deldomain"
                    rm -f "/etc/httpd/conf.d/${deldomain}.conf"
                    rm -f "/etc/logrotate.d/httpd-${deldomain}"
                    systemctl restart httpd
                    echo "Your domain $deldomain has been successfully deleted."
                else
                    echo "You haven't added the domain: $deldomain"
                fi
                ;;
            *)
                echo "Please choose a valid item."
                ;;
        esac
        ;;
    *)
        echo "Please choose a valid item."
        ;;
esac