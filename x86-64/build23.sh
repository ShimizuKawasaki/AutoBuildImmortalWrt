你说得对！脚本里只有**下载** ipk 到 `extra-packages/` 目录的逻辑，但缺少**实际安装**的步骤。

## 问题分析

```
现在的流程：
下载 ipk → extra-packages/ 目录  ✅
                ↓
         ???  ← 缺少这一步
                ↓
         打包进固件              ❌ 没有触发
```

关键在于 `make image` 命令只会安装 `PACKAGES` 变量里列出的包，以及通过 `FILES` 参数指定的文件。**直接丢在 `extra-packages/` 目录的 ipk 不会自动被安装。**

---

## 正确的做法

imagebuilder 支持通过 `PACKAGES` 指定本地 ipk 路径，但更标准的方式是**把 ipk 放入本地仓库目录**，然后加入 `PACKAGES` 列表。

查看你的脚本，已经有 `prepare-packages.sh` 负责处理 `extra-packages/`，我们需要搞清楚它做了什么，但从脚本逻辑推断，**最终 ipk 应该被放到 `packages/` 目录**作为本地仓库。

---

## 修复方案

### 修复 quickstart

```bash
# ============= 下载 quickstart ipk =============
echo "========================================"
echo "🔄 正在下载 quickstart 相关 ipk..."
echo "========================================"
mkdir -p /home/build/immortalwrt/extra-packages

QUICKSTART_BASE_URL="https://github.com/animegasan/luci-app-quickstart/releases/download/1.0.2"

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/quickstart_0.7.12-60_x86_64.ipk" \
    -O /home/build/immortalwrt/extra-packages/quickstart_0.7.12-60_x86_64.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 quickstart_0.7.12-60_x86_64.ipk 失败，退出构建"
    exit 1
fi

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/luci-app-quickstart_1.0.2-20230817_all.ipk" \
    -O /home/build/immortalwrt/extra-packages/luci-app-quickstart_1.0.2-20230817_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 luci-app-quickstart 失败，退出构建"
    exit 1
fi
echo "✅ quickstart ipk 下载成功"

# ⬇️ 新增：将 ipk 复制到 packages 本地仓库目录并刷新索引
cp /home/build/immortalwrt/extra-packages/quickstart_0.7.12-60_x86_64.ipk \
   /home/build/immortalwrt/packages/
cp /home/build/immortalwrt/extra-packages/luci-app-quickstart_1.0.2-20230817_all.ipk \
   /home/build/immortalwrt/packages/
```

然后在 `PACKAGES` 变量里加上包名：
```bash
# ⬇️ 新增：加入 quickstart 包名让 make image 安装
PACKAGES="$PACKAGES quickstart"
PACKAGES="$PACKAGES luci-app-quickstart"
```

---

### 修复 homeproxy

homeproxy 的逻辑需要重新梳理，之前脚本里 `-luci-app-homeproxy` 的方式**并不可靠**，正确流程应该是：

```
① make image 时通过 PACKAGES 安装官方版（拉取依赖）
          ↓
② make image 构建完成，进入固件的 rootfs
          ↓
③ 通过 FILES 机制，把自定义 ipk 预置到固件里
          ↓
④ 写一个 uci-defaults 脚本，在路由器首次启动时执行卸载+安装
```

具体实现：

```bash
# ============= homeproxy 处理 =============
echo "========================================"
echo "🔄 正在下载 homeproxy 自定义版本 ipk..."
echo "========================================"

HOMEPROXY_CUSTOM_URL="https://github.com/bulianglin/homeproxy/releases/download/dev/luci-app-homeproxy__all.ipk"

# ① 下载自定义 ipk 到 FILES 目录，让它随固件一起打包进去
mkdir -p /home/build/immortalwrt/files/root

wget -q --show-progress \
    "${HOMEPROXY_CUSTOM_URL}" \
    -O /home/build/immortalwrt/files/root/luci-app-homeproxy_custom_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 luci-app-homeproxy 自定义版本失败，退出构建"
    exit 1
fi
echo "✅ homeproxy 自定义版本下载成功"

# ② 写入 uci-defaults 脚本，路由器首次启动时自动执行替换
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'UCIEOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
#!/bin/sh
echo ">>> 开始替换 luci-app-homeproxy 为自定义版本..."

# 卸载官方版本（保留依赖）
opkg remove luci-app-homeproxy --force-removal-of-dependent-packages=0

# 安装自定义版本
opkg install /root/luci-app-homeproxy_custom_all.ipk

# 清理安装包
rm -f /root/luci-app-homeproxy_custom_all.ipk

echo ">>> luci-app-homeproxy 替换完成"
# 脚本执行完后自动删除自身，避免重复执行
rm -f /etc/uci-defaults/99-install-homeproxy
UCIEOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
echo "✅ uci-defaults 脚本已写入"
```

`PACKAGES` 里保留官方版用于拉取依赖：
```bash
# 官方版用于在构建时解析并安装依赖，uci-defaults 会在首次启动时替换为自定义版
PACKAGES="$PACKAGES luci-app-homeproxy"
```

---

## 完整修复后的脚本

```bash
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
mkdir -p /home/build/immortalwrt/extra-packages

QUICKSTART_BASE_URL="https://github.com/animegasan/luci-app-quickstart/releases/download/1.0.2"

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/quickstart_0.7.12-60_x86_64.ipk" \
    -O /home/build/immortalwrt/extra-packages/quickstart_0.7.12-60_x86_64.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 quickstart_0.7.12-60_x86_64.ipk 失败，退出构建"
    exit 1
fi

wget -q --show-progress \
    "${QUICKSTART_BASE_URL}/luci-app-quickstart_1.0.2-20230817_all.ipk" \
    -O /home/build/immortalwrt/extra-packages/luci-app-quickstart_1.0.2-20230817_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 luci-app-quickstart 失败，退出构建"
    exit 1
fi
echo "✅ quickstart ipk 下载成功"

# 拷贝到本地仓库目录，使 make image 能够识别
cp /home/build/immortalwrt/extra-packages/quickstart_0.7.12-60_x86_64.ipk \
   /home/build/immortalwrt/packages/
cp /home/build/immortalwrt/extra-packages/luci-app-quickstart_1.0.2-20230817_all.ipk \
   /home/build/immortalwrt/packages/
echo "✅ quickstart ipk 已注册到本地仓库"


# ============= 下载 homeproxy 自定义版本并写入启动替换脚本 =============
echo "========================================"
echo "🔄 正在下载 homeproxy 自定义版本 ipk..."
echo "========================================"

HOMEPROXY_CUSTOM_URL="https://github.com/bulianglin/homeproxy/releases/download/dev/luci-app-homeproxy__all.ipk"

# 下载到 FILES/root，随固件打包，路由器启动后可访问
mkdir -p /home/build/immortalwrt/files/root

wget -q --show-progress \
    "${HOMEPROXY_CUSTOM_URL}" \
    -O /home/build/immortalwrt/files/root/luci-app-homeproxy_custom_all.ipk
if [ $? -ne 0 ]; then
    echo "❌ 下载 luci-app-homeproxy 自定义版本失败，退出构建"
    exit 1
fi
echo "✅ homeproxy 自定义版本下载成功"

# 写入 uci-defaults 脚本，路由器首次启动时自动卸载官方版并安装自定义版
mkdir -p /home/build/immortalwrt/files/etc/uci-defaults
cat << 'UCIEOF' > /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
#!/bin/sh
echo ">>> 开始替换 luci-app-homeproxy 为自定义版本..."

# 卸载官方版本，保留依赖
opkg remove luci-app-homeproxy --force-removal-of-dependent-packages=0

# 安装自定义版本
opkg install /root/luci-app-homeproxy_custom_all.ipk

# 清理安装包
rm -f /root/luci-app-homeproxy_custom_all.ipk

echo ">>> luci-app-homeproxy 替换完成"
rm -f /etc/uci-defaults/99-install-homeproxy
UCIEOF

chmod +x /home/build/immortalwrt/files/etc/uci-defaults/99-install-homeproxy
echo "✅ uci-defaults 替换脚本已写入"


# 输出调试信息
echo "$(date '+%Y-%m-%d %H:%M:%S') - 开始构建..."
PACKAGES=""
PACKAGES="$PACKAGES curl"
PACKAGES="$PACKAGES luci-i18n-diskman-zh-cn"
PACKAGES="$PACKAGES luci-i18n-firewall-zh-cn"
PACKAGES="$PACKAGES luci-i18n-filebrowser-zh-cn"
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
# homeproxy：官方版用于解析依赖，首次启动时会被 uci-defaults 替换为自定义版
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
