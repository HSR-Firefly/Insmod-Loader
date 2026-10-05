#!/system/bin/sh
# post-fs-data.sh —— post-fs-data 模式: 阻塞启动（最多 10 秒），在模块挂载之前、Zygote 之前运行。
#
# 本阶段的 insmod 与 late_start 阶段逻辑完全一致，差别只有:
#   1. 运行时机更早（早于 Zygote / 系统服务启动）
#   2. 读取的配置目录是 /data/adb/insmod-loader/post-fs-data/
#   3. 日志文件名是 logs/post-fs-data.txt
#
# ⚠️ 该阶段禁止使用 setprop，会导致启动过程死锁！需要改属性请用 resetprop -n。
# ⚠️ 该阶段阻塞启动（10 秒上限），内核模块卡住会拖慢甚至卡死开机，请谨慎使用。
#
# 本脚本只做三件事: 定位自身目录 → 校验共用实现可读 → 交给共用实现执行。
# 路径、符号链接、临时文件与清理的安全检查都在 insmod-loader.sh（见该文件顶部约定）。

MODDIR=${0%/*}
KSU_INSMOD_BASE=${KSU_INSMOD_BASE:-/data/adb/insmod-loader}

# 拒绝符号链接形式的共用实现（避免 source 到目录外的东西）
if [ -h "$MODDIR/insmod-loader.sh" ]; then
  echo "post-fs-data: insmod-loader.sh 是符号链接，拒绝执行"
  exit 1
fi
if [ ! -f "$MODDIR/insmod-loader.sh" ]; then
  echo "post-fs-data: 找不到 $MODDIR/insmod-loader.sh，跳过执行"
  exit 1
fi

. "$MODDIR/insmod-loader.sh"
insmod_loader_main post-fs-data "$KSU_INSMOD_BASE/post-fs-data"
