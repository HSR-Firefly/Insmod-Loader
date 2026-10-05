#!/usr/bin/env bash
# pack.sh —— 打包 KernelSU 模块。
#
# 职责只有一件: 把 module/ 目录的内容打成可刷入的 zip，输出到 output/。
# 不生成文档、不跑测试、不碰其它目录（README.md / tests/ 都不在打包范围内）。
#
# 用法:
#   ./pack.sh                  # 打包 -> output/insmod-loader_<version>.zip
#   ./pack.sh --name 自定义.zip  # 自定义输出文件名
#   ./pack.sh -h | --help      # 查看用法
#
# 打包规则:
#   - zip 根目录 = module/ 的内容（module.prop 必须位于 zip 根，否则 KernelSU 不识别）
#   - -0 只存储不压缩（模块安装后直接使用，压缩过的 .ko 内核无法加载）
#   - 排除 .git/.svn、点文件、node_modules、*.zip、编辑器临时文件
#   - 保留脚本可执行位
#
# 依赖: zip（如未安装: apt install zip / pkg install zip）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MODULE_DIR="$ROOT/module"
OUTPUT_DIR="$ROOT/output"
OUT_NAME=""

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --name)
      [ $# -ge 2 ] || { echo "错误: --name 需要一个参数" >&2; exit 2; }
      OUT_NAME="$2"; shift 2 ;;
    *)
      echo "错误: 未知参数 '$1'（用 --help 查看用法）" >&2; exit 2 ;;
  esac
done

die() { printf '错误: %s\n' "$1" >&2; exit 1; }

# ---- 前置检查 --------------------------------------------------------------
command -v zip >/dev/null 2>&1 || die "需要 zip 命令（apt install zip / pkg install zip）"
[ -d "$MODULE_DIR" ] || die "找不到模块目录: $MODULE_DIR"
[ -f "$MODULE_DIR/module.prop" ] || die "$MODULE_DIR 下没有 module.prop，这不是一个 KernelSU 模块"

prop_get() { sed -n "s/^$1=//p" "$MODULE_DIR/module.prop" | head -n 1 | tr -d '\r'; }
MODID="$(prop_get id)"
VERSION="$(prop_get version)"
VCODE="$(prop_get versionCode)"
NAME="$(prop_get name)"

[ -n "$MODID" ] || die "module.prop 缺少 id"
printf '%s' "$MODID" | grep -qE '^[a-zA-Z][a-zA-Z0-9._-]+$' \
  || die "module.prop 的 id 不合法: '$MODID'（需匹配 ^[a-zA-Z][a-zA-Z0-9._-]+\$）"
printf '%s' "$VCODE" | grep -qE '^[0-9]+$' \
  || die "module.prop 的 versionCode 必须是整数，当前为 '$VCODE'"
[ -n "$VERSION" ] || VERSION="unknown"
[ -n "$OUT_NAME" ] || OUT_NAME="${MODID}_${VERSION}.zip"

# 关键: module/ 里不能再有一个 module.prop 之外的嵌套模块
if grep -qU $'\r' "$MODULE_DIR/module.prop"; then
  die "module.prop 含 CR 字符（CRLF 换行），必须使用 UNIX(LF) 换行"
fi

mkdir -p "$OUTPUT_DIR"
OUT="$OUTPUT_DIR/$OUT_NAME"

case "$OUT" in
  "$MODULE_DIR"/*) die "输出文件不能位于模块目录内: $OUT" ;;
esac

# ---- 打包 ------------------------------------------------------------------
printf '== 打包 ==\n'
printf '  模块: %s (id=%s, version=%s, versionCode=%s)\n' "${NAME:-$MODID}" "$MODID" "$VERSION" "$VCODE"

rm -f "$OUT"
(
  cd "$MODULE_DIR"
  # -0 = 只存储不压缩。模块安装后是直接挂载/直接使用的，压缩过的 .ko 内核无法加载，
  # 也让安装过程少一次解压开销，因此统一按 KernelSU 惯例用存储模式打包。
  zip -r -X -0 "$OUT" . \
    -x '.*' -x './.*' -x '*/.*' \
    -x '*/node_modules/*' -x './node_modules/*' \
    -x '*.zip' -x '*.swp' -x '*.tmp' -x '*~' \
    -x '*/__MACOSX/*' -x '*.DS_Store' \
    >/dev/null
)

# ---- 校验 ------------------------------------------------------------------
printf '== 校验 ==\n'
FAILED=0
if unzip -Z1 "$OUT" | grep -qx 'module.prop'; then
  printf '  ✓ module.prop 位于 zip 根目录\n'
else
  printf '  ✗ zip 根目录缺少 module.prop（不要把 module/ 这一层也打进去）\n' >&2
  FAILED=1
fi

NESTED="$(unzip -Z1 "$OUT" | grep -E '/module\.prop$' || true)"
if [ -n "$NESTED" ]; then
  printf '  ! 检测到嵌套的 module.prop: %s\n' "$NESTED" >&2
  FAILED=1
fi

# 不应出现测试/文档类文件
STRAY="$(unzip -Z1 "$OUT" | grep -E '^(tests/|README|pack\.sh)' || true)"
if [ -n "$STRAY" ]; then
  printf '  ! zip 里混入了非模块文件:\n%s\n' "$STRAY" >&2
  FAILED=1
else
  printf '  ✓ 未混入 tests/、README、pack.sh\n'
fi

for f in customize.sh post-fs-data.sh service.sh; do
  if unzip -Z1 "$OUT" | grep -qx "$f"; then
    printf '  · 包含 %s\n' "$f"
  fi
done

COUNT="$(unzip -Z1 "$OUT" | grep -c . || true)"
SIZE="$(du -h "$OUT" | cut -f1)"
printf '  文件数: %s    大小: %s\n' "$COUNT" "$SIZE"

if [ "$FAILED" -ne 0 ]; then
  printf '\n打包失败：请修复上面的问题后重试。\n' >&2
  exit 1
fi

printf '\n输出: %s\n' "$OUT"
cat <<'EOF'

刷入方式: KernelSU 管理器 → 模块页 → 浮动按钮(➕) → 选择该 zip → 重启
注意: KernelSU 模块不支持在 Recovery 中安装。
EOF
