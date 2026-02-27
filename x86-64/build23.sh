#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p /home/build/immortalwrt/files/etc/config

cat << EOF > /home/build/immortalwrt/files/etc/config/pppoe-settings
enable_pppoe=${ENABLE_PPPOE}
pppoe_account=${PPPOE_ACCOUNT}
pppoe_password=${PPPOE_PASSWORD}
EOF

echo "cat pppoe-settings"
cat /home/build/immortalwrt/files/etc/config/pppoe-settings

OFFICIAL="https://downloads.immortalwrt.org"
MIRROR="https://mirrors.sjtug.sjtu.edu.cn/immortalwrt"
echo ">>> official failed, switching to mirror"
BASE_URL="$MIRROR"
echo "Using BASE_URL = $BASE_URL"
echo "========================================"
echo "Updating repositories.conf"
echo "========================================"
sed -i "s#${OFFICIAL}#${BASE_URL}#g" repositories.conf
cat repositories.conf

if [ -z "$CUSTOM_PACKAGES" ]; then
  echo "⚪️ 未选择 任何第三方软件包"
else
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  sh shell/prepare-packages.sh
  ls -lah /home/build/immortalwrt/packages/
fi

# ============= 下载并注册 quickstart ipk =============
echo "========================================"
echo "🔄 正在下载 quickstart 相关 ipk..."
echo "========================================"
mkdir -p /home/build/immortalwrt/packages

QUICKSTART_BASE_URL="https://github.com/animegasan/luci-app-quickstart/releases/download/1.0.2"

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/quickstart_0.7.12-60_x86_64.ipk" \
    -O /home/build/immortalwrt/packages/quickstart_0.7.12-60_x86_64.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 quickstart_0.7.12-60_x86_64.ipk 失败，退出构建"
    exit 1
fi

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/luci-app-quickstart_1.0.2-20230817_all.ipk" \
    -O /home/build/immortalwrt/packages/luci-app-quickstart_1.0.2-20230817_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 luci-app-quickstart 失败，退出构建"
    exit 1
fi
echo "✅ quickstart ipk 下载成功并已注册到本地仓库"

# ============= 手动生成本地仓库索引（仅 quickstart） =============
echo "========================================"
echo "🔄 正在手动生成本地仓库索引..."
echo "========================================"

LOCAL_REPO="/home/build/immortalwrt/packages"
cd "$LOCAL_REPO"

# 清空旧索引
> Packages

for ipk in *.ipk; do
    [ -f "$ipk" ] || continue
    echo "📦 正在处理: $ipk"

    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR"

    ar x "$LOCAL_REPO/$ipk" 2>/dev/null
    if [ -f control.tar.gz ]; then
        tar xzf control.tar.gz ./control 2>/dev/null || tar xzf control.tar.gz 2>/dev/null
    elif [ -f control.tar.xz ]; then
        tar xJf control.tar.xz ./control 2>/dev/null || tar xJf control.tar.xz 2>/dev/null
    fi

    if [ ! -f control ]; then
        echo "  ⚠️  无法解压 control 文件，跳过 $ipk"
        cd "$LOCAL_REPO"
        rm -rf "$TMP_DIR"
        continue
    fi

    sed '/^$/d' control >> "$LOCAL_REPO/Packages"
    echo "Filename: $ipk" >> "$LOCAL_REPO/Packages"

    SIZE=$(stat -c%s "$LOCAL_REPO/$ipk")
    echo "Size: $SIZE" >> "$LOCAL_REPO/Packages"

    SHA256=$(sha256sum "$LOCAL_REPO/$ipk" | awk '{print $1}')
    echo "SHA256sum: $SHA256" >> "$LOCAL_REPO/Packages"
    echo "" >> "$LOCAL_REPO/Packages"

    cd "$LOCAL_REPO"
    rm -rf "$TMP_DIR"
done

gzip -k -f Packages

echo "✅ 本地仓库索引生成完毕"
echo "========================================"
echo "📋 Packages 内容预览："
cat Packages
echo "========================================"
ls -lah "$LOCAL_REPO"

cd /home/build/immortalwrt

# ============= 注册本地仓库到 repositories.conf（插入到第一行） =============
if ! grep -q "src/gz local_extra" repositories.conf; then
    sed -i '1s/^/src\/gz local_extra file:\/\/\/home\/build\/immortalwrt\/packages\n/' repositories.conf
    echo "✅ 本地仓库已注册到 repositories.conf 第一行"
else
    echo "⚪️ 本地仓库已存在，跳过注册"
fi
echo "========================================"
echo "📋 当前 repositories.conf："
cat repositories.conf
echo "========================================"

# ============= 预下载 homeproxy 自定义版本，打包进固件 =============
echo "========================================"
echo "🔄 正在下载 homeproxy 自定义版本 ipk，打包进固件..."
echo "========================================"

HOMEPROXY_CUSTOM_URL="https://github.com/bulianglin/homeproxy/releases/download/dev/luci-app-homeproxy__all.ipk"
HOMEPROXY_IPK_NAME="luci-app-homeproxy_custom_all.ipk"
PREINSTALL_DIR="/home/build/immortalwrt/files/root/preinstall"

mkdir -p "$PREINSTALL_DIR"

wget -q --show-progress \
    --no-check-certificate \
    --timeout=60 \
    --tries=3 \
    "${HOMEPROXY_CUSTOM_URL}" \
    -O "${PREINSTALL_DIR}/${HOMEPROXY_IPK_NAME}"

if [ $? -ne 0 ] || [ ! -s "${PREINSTALL_DIR}/${HOMEPROXY_IPK_NAME}" ]; then
    echo "❌ 下载 homeproxy 自定义版本失败，退出构建"
    exit 1
fi

echo "✅ homeproxy ipk 下载成功: $(du -sh ${PREINSTALL_DIR}/${HOMEPROXY_IPK_NAME})"

# ============= 写入首次启动安装脚本 =============
echo "========================================"
echo "🔄 写入 uci-defaults 首次启动安装脚本..."
echo "========================================"

mkdir -p /home/build/immortalwrt/files/etc/uci-defaults

cat << 'UCIEOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
#!/bin/sh

IPK_PATH="/root/preinstall/luci-app-homeproxy_custom_all.ipk"
LOG="/var/log/homeproxy-install.log"

echo "[$(date)] ===== 开始安装 homeproxy =====" >> "${LOG}"

# ============= 等待网络就绪 =============
echo "[$(date)] 等待网络就绪..." >> "${LOG}"
MAX_WAIT=10
WAITED=0
while ! ping -c 1 -W 2 223.5.5.5 > /dev/null 2>&1; do
    if [ "$WAITED" -ge "$MAX_WAIT" ]; then
        echo "[$(date)] ⚠️  网络等待超时 ${MAX_WAIT}s，跳过 opkg update，继续本地安装..." >> "${LOG}"
        break
    fi
    echo "[$(date)] 网络未就绪，等待中... (${WAITED}s)" >> "${LOG}"
    sleep 5
    WAITED=$((WAITED + 5))
done

# ============= opkg update =============
if ping -c 1 -W 2 223.5.5.5 > /dev/null 2>&1; then
    echo "[$(date)] 网络已就绪，执行 opkg update..." >> "${LOG}"
    opkg update >> "${LOG}" 2>&1
    if [ $? -eq 0 ]; then
        echo "[$(date)] ✅ opkg update 成功" >> "${LOG}"
    else
        echo "[$(date)] ⚠️  opkg update 失败，继续本地安装..." >> "${LOG}"
    fi
fi

# ============= 检查 ipk 文件是否存在 =============
if [ ! -f "${IPK_PATH}" ]; then
    echo "[$(date)] ❌ ERROR: ipk 文件不存在: ${IPK_PATH}" >> "${LOG}"
    exit 1
fi

echo "[$(date)] 找到 ipk 文件: ${IPK_PATH}" >> "${LOG}"

# ============= 卸载官方版本（如果存在）=============
if opkg list-installed | grep -q "^luci-app-homeproxy "; then
    echo "[$(date)] 检测到已安装官方版本，先卸载..." >> "${LOG}"
    opkg remove luci-app-homeproxy \
        --force-depends \
        --force-remove \
        >> "${LOG}" 2>&1
fi

# ============= 强制安装自定义版本 =============
echo "[$(date)] 正在安装自定义版本..." >> "${LOG}"
opkg install "${IPK_PATH}" \
    --force-reinstall \
    --force-overwrite \
    >> "${LOG}" 2>&1

if [ $? -eq 0 ]; then
    echo "[$(date)] ✅ homeproxy 安装成功！" >> "${LOG}"
    # 清理 ipk 释放空间
    rm -f "${IPK_PATH}"
    rmdir /root/preinstall 2>/dev/null || true
    # 重启 uhttpd 使 LuCI 生效
    /etc/init.d/uhttpd restart >> "${LOG}" 2>&1
else
    echo "[$(date)] ❌ homeproxy 安装失败，请查看日志: ${LOG}" >> "${LOG}"
fi

exit 0
UCIEOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
echo "✅ 首次启动安装脚本写入完成"

# ============= 验证 files 目录结构 =============
echo "========================================"
echo "📁 验证 files 目录结构："
echo "========================================"
echo "--- preinstall 目录 ---"
ls -lah /home/build/immortalwrt/files/root/preinstall/
echo "--- uci-defaults 目录 ---"
ls -lah /home/build/immortalwrt/files/etc/uci-defaults/
echo "--- uci-defaults 脚本内容 ---"
cat /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
echo "========================================"

# ============= 开始编译 =============
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建..."
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
PACKAGES="$PACKAGES luci-i18n-opkg-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES appfilter"
PACKAGES="$PACKAGES luci-app-appfilter"
PACKAGES="$PACKAGES luci-i18n-appfilter-zh-cn"
PACKAGES="$PACKAGES luci-i18n-samba4-zh-cn"
# quickstart：从本地仓库安装
PACKAGES="$PACKAGES quickstart"
PACKAGES="$PACKAGES luci-app-quickstart"
# homeproxy：编译时安装官方版本（提供依赖），首次启动时被自定义版本覆盖
PACKAGES="$PACKAGES luci-app-homeproxy"
# 合并第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" \
    PACKAGES="$PACKAGES" \
    FILES="/home/build/immortalwrt/files" \
    ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - ❌ Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - ✅ Build completed successfully."
