#!/usr/bin/env fish

function must_root
        if test (id -u) -ne 0
                echo "请使用root 执行"
                exit 1
        end
end

function run
        echo
        echo "> $argv"
        command $argv
        or begin
                echo "执行失败 > $argv"
                exit 1
        end
end

function install_base_packages
        run apt-get update && apt-get upgrade -y
        run apt-get install -y sudo curl wget ca-certificates ufw nano vim git htop tmux screen unzip tar lsof jq python3 python3-pip python3-venv python3-systemd
        run bash <(curl -sL 'https://get.docker.com')
end

function setup_timezone
    run timedatectl set-timezone Asia/Shanghai
end

function setup_firewall
    run ufw allow OpenSSH
    run ufw allow 22/tcp
    run ufw --force enable
end

must_root
install_base_packages
setup_timezone
setup_firewall

echo "初始化完成"
