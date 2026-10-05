#!/system/bin/sh
# service.sh —— late_start 服务模式: 非阻塞，与其余启动过程并行执行（推荐使用的阶段）。
#
# 本阶段的 insmod 与 post-fs-data 阶段逻辑完全一致，差别只有:
#   1. 运行时机更晚（系统主要服务已启动，非阻塞）
#   2. 读取的配置目录是 /data/adb/insmod-loader/late_start/
#   3. 日志文件名是 logs/late_start.txt
#
# 本脚本只做三件事: 定位自身目录 → 校验共用实现可读 → 交给共用实现执行。
# 路径、符号链接、临时文件与清理的安全检查都在 insmod-loader.sh（见该文件顶部约定）。

MODDIR=${0%/*}
KSU_INSMOD_BASE=${KSU_INSMOD_BASE:-/data/adb/insmod-loader}

# 拒绝符号链接形式的共用实现（避免 source 到目录外的东西）
if [ -h "$MODDIR/insmod-loader.sh" ]; then
  echo "late_start: insmod-loader.sh 是符号链接，拒绝执行"
  exit 1
fi
if [ ! -f "$MODDIR/insmod-loader.sh" ]; then
  echo "late_start: 找不到 $MODDIR/insmod-loader.sh，跳过执行"
  exit 1
fi

. "$MODDIR/insmod-loader.sh"
insmod_loader_main late_start "$KSU_INSMOD_BASE/late_start"
