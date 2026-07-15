#!/bin/bash
set -uo pipefail

#############################################
# FNOS Docker 延迟启动管理脚本
# Version: 2.2
#############################################

SCRIPT_DIR_DEFAULT="/vol1/1000/config"
SERVICE_NAME="start_docker.service"
LOG_FILE="/var/log/start_docker.log"


# 检查root权限
check_root(){
    if [ "$EUID" -ne 0 ]; then
        echo "请使用root权限运行"
        exit 1
    fi
}


# 校验非负整数
is_nonneg_int(){
    [[ "$1" =~ ^[0-9]+$ ]]
}


# 检查 docker 是否可用
check_docker(){
    if ! command -v docker >/dev/null 2>&1; then
        echo "未检测到 docker 命令，请先安装 Docker"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "Docker 守护进程未运行，请先启动 Docker"
        return 1
    fi
    return 0
}


# 主菜单
main_menu(){
    while true; do
        clear

        echo "================================"
        echo " FNOS Docker 延迟启动管理工具 "
        echo "================================"

        echo "1. 创建延迟启动服务"
        echo "2. 删除延迟启动服务"
        echo "3. 查看启动日志"
        echo "4. 查看当前配置"
        echo "5. 退出"

        read -p "请选择: " choice

        case "$choice" in
            1) create_service ;;
            2) delete_service ;;
            3) show_log ;;
            4) show_config ;;
            5) echo "退出"; exit 0 ;;
            *) echo "输入错误，请重新选择"; sleep 2 ;;
        esac

        echo
        read -p "按回车键返回主菜单..." _ || true
    done
}


################################
# 创建服务
################################

create_service(){

echo
echo "开始创建 Docker 延迟启动服务"

if ! check_docker; then
    return
fi


read -p "脚本保存目录(默认 $SCRIPT_DIR_DEFAULT): " script_path

script_path=${script_path:-$SCRIPT_DIR_DEFAULT}


mkdir -p "$script_path" || { echo "无法创建目录: $script_path"; return; }


# 获取容器列表

mapfile -t containers < <(docker ps -a --format "{{.Names}}")


if [ ${#containers[@]} -eq 0 ]; then

echo "没有找到Docker容器"

return

fi


echo
echo "Docker容器列表:"
echo

for i in "${!containers[@]}"
do

echo "$((i+1)). ${containers[$i]}"

done


echo
echo "输入启动顺序编号(例如 1 3 5；支持区间 1-5；输入 a 选择全部):"

read -p "请选择: " select_ids


selected=()
invalid=0


# 全选
if [[ "$select_ids" =~ ^[[:space:]]*(a|\*|all)[[:space:]]*$ ]]; then

selected=("${containers[@]}")

else

for token in $select_ids
do

if [[ $token =~ ^[0-9]+-[0-9]+$ ]]; then

start=${token%-*}
end=${token#*-}

if [ "$start" -ge 1 ] && [ "$end" -le "${#containers[@]}" ] && [ "$start" -le "$end" ]; then

for ((n=start; n<=end; n++)); do
selected+=("${containers[$((n-1))]}")
done

else

invalid=1

fi

elif [[ $token =~ ^[0-9]+$ ]]; then

if [ "$token" -ge 1 ] && [ "$token" -le "${#containers[@]}" ]; then

selected+=("${containers[$((token-1))]}")


else

invalid=1

fi

else

invalid=1

fi

done

fi


# 去重（保持顺序）
declare -A _seen=()
unique_selected=()

for c in "${selected[@]}"
do

if [[ -z "${_seen[$c]:-}" ]]; then

_seen[$c]=1
unique_selected+=("$c")

fi

done

selected=("${unique_selected[@]}")


if [ ${#selected[@]} -eq 0 ]; then

echo "没有选择容器"

return

fi

if [ "$invalid" -eq 1 ]; then

echo "已忽略无效或越界的编号"

fi


read -p "系统启动后等待多少秒启动第一个容器(默认60): " first_delay

first_delay=${first_delay:-60}

if ! is_nonneg_int "$first_delay"; then
    echo "等待时间需为非负整数"
    return
fi


read -p "容器之间间隔秒数(默认10): " interval

interval=${interval:-10}

if ! is_nonneg_int "$interval"; then
    echo "间隔时间需为非负整数"
    return
fi


script_file="$script_path/start_docker.sh"

if [ -f "$script_file" ]; then
    read -p "启动脚本已存在，是否覆盖?(y/n): " ow
    if [[ "$ow" != "y" && "$ow" != "Y" ]]; then
        echo "已取消"
        return
    fi
fi


# 生成前确认
echo
echo "===== 配置确认 ====="
echo "启动脚本: $script_file"
echo "首个容器等待: ${first_delay}s"
echo "容器间隔: ${interval}s"
echo "启动顺序:"

for i in "${!selected[@]}"
do
echo "  $((i+1)). ${selected[$i]}"
done

read -p "确认生成并创建?(y/n): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "已取消"
    return
fi


################################
#生成启动脚本
################################


cat > "$script_file" <<EOF
#!/bin/bash

LOG="$LOG_FILE"

echo "===== Docker启动任务开始 \$(date) =====" >> \$LOG


#等待系统稳定

sleep $first_delay


#等待Docker启动（兼容 docker.service 名称差异，docker info 成功即视为就绪）
COUNT=0

while ! systemctl is-active --quiet docker 2>/dev/null && ! docker info >/dev/null 2>&1
do

COUNT=\$((COUNT+1))

echo "等待Docker启动 \$COUNT" >> \$LOG


if [ \$COUNT -gt 30 ];then

echo "Docker启动失败" >> \$LOG
exit 1

fi

sleep 5

done


EOF


for c in "${selected[@]}"
do


cat >> "$script_file" <<EOF

echo "准备启动 $c \$(date)" >> \$LOG


STATUS=\$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)


if [ "\$STATUS" != "true" ];then

docker start "$c" >> \$LOG 2>&1

if [ \$? -eq 0 ];then

echo "$c 启动成功" >> \$LOG

else

echo "$c 启动失败" >> \$LOG

fi
else

echo "$c 已经运行" >> \$LOG

fi


sleep $interval


EOF

done


chmod +x "$script_file"


echo
echo "启动脚本生成:"
echo "$script_file"


read -p "是否创建systemd服务?(y/n): " yn


if [[ "$yn" == "y" || "$yn" == "Y" ]]
then

if [ -f "/etc/systemd/system/$SERVICE_NAME" ]; then
    read -p "systemd 服务已存在，是否覆盖?(y/n): " ow2
    if [[ "$ow2" != "y" && "$ow2" != "Y" ]]; then
        echo "已取消服务创建（脚本已生成）"
        return
    fi
fi

cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF

[Unit]

Description=FNOS Docker Delayed Startup

Requires=docker.service

After=docker.service network-online.target

Wants=network-online.target



[Service]

Type=oneshot

ExecStart="$script_file"

RemainAfterExit=yes



[Install]

WantedBy=multi-user.target

EOF


systemctl daemon-reload

systemctl enable "$SERVICE_NAME"


echo
echo "服务创建完成"

fi

}


################################
# 删除服务
################################

delete_service(){

echo

if systemctl list-unit-files | grep -q "$SERVICE_NAME"
then


read -p "确认删除?(y/n): " c

if [[ "$c" == "y" || "$c" == "Y" ]]
then

systemctl stop "$SERVICE_NAME" 2>/dev/null

systemctl disable "$SERVICE_NAME" 2>/dev/null


# 读取并清理生成脚本（去掉 ExecStart 可能的引号）
gen_script=$(sed -n 's/^ExecStart=//p' "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null | head -n1 | sed -e 's/^"//' -e 's/"$//')
rm -f "/etc/systemd/system/$SERVICE_NAME"

if [ -n "$gen_script" ] && [ -f "$gen_script" ]; then
    rm -f "$gen_script"
    echo "已删除启动脚本: $gen_script"
fi

systemctl daemon-reload


echo "服务已删除"


else

echo "取消"

fi


else

echo "没有找到服务"

fi

}


################################
# 查看日志
################################

show_log(){

echo

if [ -f "$LOG_FILE" ]
then

tail -100 "$LOG_FILE"

else

echo "暂无日志"

fi

}


################################
# 查看当前配置
################################

show_config(){

echo

if [ ! -f "/etc/systemd/system/$SERVICE_NAME" ]; then

echo "尚未创建延迟启动服务"

return

fi

gen_script=$(sed -n 's/^ExecStart=//p' "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null | head -n1 | sed -e 's/^"//' -e 's/"$//')

echo "启动脚本: ${gen_script:-未知}"
echo
echo "计划开机启动的容器:"

if [ -n "$gen_script" ] && [ -f "$gen_script" ]; then

grep -o 'docker start "[^"]*"' "$gen_script" 2>/dev/null | sed 's/docker start "\(.*\)"/\1/' | nl

if [ -z "$(grep -o 'docker start "[^"]*"' "$gen_script" 2>/dev/null)" ]; then

grep -o 'docker start [^ ]*' "$gen_script" 2>/dev/null | sed 's/docker start //' | nl

fi

else

echo "（未找到启动脚本，无法列出容器）"

fi

}


check_root

main_menu
