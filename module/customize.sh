#!/system/bin/sh
# customize.sh —— 安装脚本。该脚本在模块被解压后被内置安装器 source（导入）执行，
# 运行在 KernelSU BusyBox 的 ash「独立模式」下。
#
# 可用变量: MODPATH TMPDIR ZIPFILE ARCH IS64BIT API KSU KSU_VER KSU_VER_CODE
#           KSU_KERNEL_VER_CODE KSU_UAPI_VER KSU_RUNTIME_MODE KSU_LATE_LOAD BOOTMODE
# 可用函数: ui_print abort set_perm set_perm_recursive
#
# 本脚本只做一件事：准备 /data/adb/insmod-loader 持久化目录树与默认 config.txt。
# 任何一步失败都立即 abort（安装失败）；abort 会走安装器的清理流程，不要用 exit。
#
# ============================ 安全约定（改动前请先读） ========================
# 1. 只创建/写入 /data/adb/insmod-loader 这一棵目录树，不碰其它任何路径。
# 2. 目标路径上的任何符号链接都拒绝：否则可能在别处建目录/写文件。
# 3. 本脚本不做任何删除操作（唯一一次 rm 是删自己刚写的探测文件）。
# 4. 不对 $MODPATH 递归设置权限（避免误改解压出来的其它文件）。

ui_print "- 正在安装 Insmod Loader"

# --- 环境要求 ----------------------------------------------------------------
# 依赖 /data/adb 可写（KernelSU 模块本就如此），并且内核支持 insmod。
if [ "$KSU" != "true" ]; then
  ui_print "! 警告: 当前环境变量 KSU 不为 true，本模块是为 KernelSU 设计的"
fi

# --- 目标目录 ----------------------------------------------------------------
BASE=/data/adb/insmod-loader

# 关键路径不接受符号链接：若 /data/adb 或目标目录是符号链接，安装直接失败
if [ -h /data/adb ]; then
  abort "! 安装失败: /data/adb 是符号链接，拒绝在其下创建目录"
fi
if [ -h "$BASE" ]; then
  abort "! 安装失败: $BASE 是符号链接，拒绝写入（可能被指向别处）"
fi
# 已存在但不是目录（例如用户误建了同名文件）时给出明确原因，
# 否则后面那句「目录不可写」会让人摸不着头脑。注意不删除/不覆盖它。
if [ -e "$BASE" ] && [ ! -d "$BASE" ]; then
  abort "! 安装失败: $BASE 已存在但不是目录，请先自行处理（本模块不会删除它）"
fi

if ! mkdir -p "$BASE" 2>/dev/null; then
  abort "! 安装失败: 无法创建目录 $BASE"
fi
if [ -h "$BASE" ] || [ ! -d "$BASE" ]; then
  abort "! 安装失败: $BASE 不是普通目录"
fi

# 只允许 root 访问：这里放的是内核模块与加载清单，没必要给别的用户读
if ! chmod 0700 "$BASE" 2>/dev/null; then
  ui_print "! 警告: 无法将 $BASE 权限收紧为 0700"
fi

# 先校验可写（写入探测文件后立即删除，不留垃圾）
if ! ( : > "$BASE/.insmod-loader-write-test" ) 2>/dev/null; then
  abort "! 安装失败: 目录 $BASE 不可写（/data/adb 是否已正确挂载？）"
fi
rm -f "$BASE/.insmod-loader-write-test"

# --- 创建三个子目录: post-fs-data / late_start / logs ------------------------
for d in post-fs-data late_start logs; do
  if [ -h "$BASE/$d" ]; then
    abort "! 安装失败: $BASE/$d 是符号链接，拒绝使用"
  fi
  if ! mkdir -p "$BASE/$d" 2>/dev/null; then
    abort "! 安装失败: 无法创建目录 $BASE/$d"
  fi
  if [ ! -d "$BASE/$d" ] || [ -h "$BASE/$d" ]; then
    abort "! 安装失败: $BASE/$d 不是普通目录"
  fi
  chmod 0700 "$BASE/$d" 2>/dev/null
done

# --- 在两个阶段目录中创建 config.txt -----------------------------------------
# 语法: [内核模块文件名]:[执行优先级1-999]
# 已存在（例如覆盖安装/升级）则保留用户内容，不覆盖。
for d in post-fs-data late_start; do
  f="$BASE/$d/config.txt"
  if [ -h "$f" ]; then
    abort "! 安装失败: $f 是符号链接，拒绝写入（可能被指向别处）"
  fi
  if [ -f "$f" ]; then
    ui_print "- 已存在配置文件，保留原有内容: $f"
    continue
  fi
  # 用命令分组让重定向失败也能被 if 捕获（ash 对 `cmd > file` 的失败会返回非 0）
  if ! { printf '%s\n' '#语法:模块:执行优先级(1-999)' > "$f"; }; then
    abort "! 安装失败: 无法创建配置文件 $f"
  fi
  if [ ! -s "$f" ]; then
    abort "! 安装失败: 配置文件 $f 未正确写入"
  fi
  if [ -h "$f" ] || [ ! -f "$f" ]; then
    abort "! 安装失败: $f 不是普通文件"
  fi
done

# --- 模块脚本权限 ------------------------------------------------------------
# 只对本模块自己的脚本设置权限；不要对 $MODPATH 整体递归设置，也不要动 webroot/。
for s in post-fs-data.sh service.sh insmod-loader.sh; do
  if [ -h "$MODPATH/$s" ]; then
    abort "! 安装失败: $MODPATH/$s 是符号链接，拒绝设置权限"
  fi
  if [ -f "$MODPATH/$s" ]; then
    set_perm "$MODPATH/$s" 0 0 0755
  fi
done

ui_print "- 目录已就绪: $BASE/{post-fs-data,late_start,logs}（权限 0700）"
ui_print "- 把 .ko 放进 post-fs-data/ 或 late_start/，并在该目录的 config.txt 中登记"
ui_print "- 需要日志时: touch $BASE/logs/debug"
ui_print "- 安装完成，重启后生效"
