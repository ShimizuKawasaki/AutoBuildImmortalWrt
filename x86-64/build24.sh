#!/bin/bash
# Log file for debugging
source shell/custom-packages.sh
echo "第三方软件包: $CUSTOM_PACKAGES"
LOGFILE="/tmp/uci-defaults-log.txt"
echo "Starting 99-custom.sh at $(date)" >> $LOGFILE
echo "编译固件大小为: $PROFILE MB"
echo "Include Docker: $INCLUDE_DOCKER"

echo "Create pppoe-settings"
mkdir -p  /home/build/immortalwrt/files/etc/config

# 创建pppoe配置文件 yml传入环境变量ENABLE_PPPOE等 写入配置文件 供99-custom.sh读取
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
  # ============= 同步第三方插件库==============
  # 同步第三方软件仓库run/ipk
  echo "🔄 正在同步第三方软件仓库 Cloning run file repo..."
  git clone --depth=1 https://github.com/wukongdaily/store.git /tmp/store-run-repo

  # 拷贝 run/x86 下所有 run 文件和ipk文件 到 extra-packages 目录
  mkdir -p /home/build/immortalwrt/extra-packages
  cp -r /tmp/store-run-repo/run/x86/* /home/build/immortalwrt/extra-packages/

  echo "✅ Run files copied to extra-packages:"
  ls -lh /home/build/immortalwrt/extra-packages/*.run
  # 解压并拷贝ipk到packages目录
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
echo "✅ quickstart ipk 下载成功"

# ============= 下载 iStore 相关 ipk =============
echo "========================================"
echo "🔄 正在下载 iStore 相关 ipk..."
echo "========================================"

ISTORE_BASE_URL="https://istore.linkease.com/repo/all/store"

ISTORE_PKGS=(
    "taskd_1.0.3-2_all.ipk"
    "luci-lib-taskd_1.0.25_all.ipk"
    "luci-lib-xterm_4.18.0_all.ipk"
    "luci-app-store_0.2.0-r3_all.ipk"
)

for pkg in "${ISTORE_PKGS[@]}"; do
    echo "📦 正在下载: $pkg"
    wget -q --show-progress \
        "${ISTORE_BASE_URL}/${pkg}" \
        -O /home/build/immortalwrt/packages/${pkg}
    if [ $? -ne 0 ]; then
        echo "❌ 下载 ${pkg} 失败，退出构建"
        exit 1
    fi
    echo "✅ ${pkg} 下载成功"
done

echo "✅ iStore 相关 ipk 全部下载成功"

# ============= 手动生成本地仓库索引 =============
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

# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建固件..."

# ============= imm仓库内的插件==============
# 定义所需安装的包列表 下列插件你都可以自行删减
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-theme-argon"
PACKAGES="$PACKAGES luci-app-argon-config"
PACKAGES="$PACKAGES luci-i18n-argon-config-zh-cn"
#24.10
PACKAGES="$PACKAGES luci-i18n-package-manager-zh-cn"
PACKAGES="$PACKAGES luci-i18n-ttyd-zh-cn"
PACKAGES="$PACKAGES openssh-sftp-server"
PACKAGES="$PACKAGES luci-i18n-samba4-zh-cn"
# 文件管理器
PACKAGES="$PACKAGES luci-i18n-filemanager-zh-cn"
# quickstart：从本地仓库安装
PACKAGES="$PACKAGES quickstart"
PACKAGES="$PACKAGES luci-app-quickstart"
# iStore：从本地仓库安装
PACKAGES="$PACKAGES taskd"
PACKAGES="$PACKAGES luci-lib-taskd"
PACKAGES="$PACKAGES luci-lib-xterm"
PACKAGES="$PACKAGES luci-app-store"
# ======== shell/custom-packages.sh =======
# 合并imm仓库以外的第三方插件
PACKAGES="$PACKAGES $CUSTOM_PACKAGES"


# 判断是否需要编译 Docker 插件
if [ "$INCLUDE_DOCKER" = "yes" ]; then
    PACKAGES="$PACKAGES luci-i18n-dockerman-zh-cn"
    echo "Adding package: luci-i18n-dockerman-zh-cn"
fi



# 构建镜像
echo "$(date '+%Y-%m-%d %H:%M:%S') - Building image with the following packages:"
echo "$PACKAGES"

make image PROFILE="generic" PACKAGES="$PACKAGES" FILES="/home/build/immortalwrt/files" ROOTFS_PARTSIZE=$PROFILE

if [ $? -ne 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: Build failed!"
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Build completed successfully."
