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

# ============= 下载 homeproxy 自定义版本并注册到本地仓库 =============
echo "========================================"
echo "🔄 正在下载 homeproxy 自定义版本 ipk..."
echo "========================================"

HOMEPROXY_CUSTOM_URL="https://github.com/bulianglin/homeproxy/releases/download/dev/luci-app-homeproxy__all.ipk"

wget -q --show-progress \
    "${HOMEPROXY_CUSTOM_URL}" \
    -O /home/build/immortalwrt/packages/luci-app-homeproxy_custom_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 homeproxy 自定义版本失败，退出构建"
    exit 1
fi
echo "✅ homeproxy 自定义版本下载成功，已注册到本地仓库"

# ============= 生成本地仓库索引 =============
echo "========================================"
echo "🔄 正在生成本地仓库索引..."
echo "========================================"
cd /home/build/immortalwrt/packages
../scripts/ipkg-make-index.sh . > Packages
gzip -k Packages
cd /home/build/immortalwrt
echo "✅ 本地仓库索引生成完毕"
ls -lah /home/build/immortalwrt/packages/

# ============= 注册本地仓库到 repositories.conf =============
# 避免重复添加
if ! grep -q "src/gz local_extra" repositories.conf; then
    echo "src/gz local_extra file:///home/build/immortalwrt/packages" >> repositories.conf
    echo "✅ 本地仓库已注册到 repositories.conf"
else
    echo "⚪️ 本地仓库已存在，跳过注册"
fi
cat repositories.conf

# 输出调试信息
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
# homeproxy：直接从本地仓库安装自定义版本
PACKAGES="$PACKAGES luci-app-homeproxy"
# 合并第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"

if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
