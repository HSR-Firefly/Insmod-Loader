#!/usr/bin/env bash
# 安全性专项测试: 验证 insmod-loader.sh 不会被诱导越权读写/误删
# 用法: bash tests/security-tests.sh
#
# 覆盖:
#   A. 路径穿越（config.txt 指向阶段目录之外）
#   B. 符号链接（config.txt / .ko / logs 目录 / logs/debug）
#   C. 非普通文件（FIFO / 目录 / 设备节点）
#   D. 环境异常（阶段目录不可进入、临时目录不可用）时是否安全退出
#   E. 清理动作是否会误删（临时目录 / 其它文件 / 符号链接目标）
#   F. 正常功能未被安全加固破坏
set -u

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../module" && pwd)"
SHELL_BIN="${TEST_SH:-sh}"
# 归一化成绝对路径: 后面有一段用 env -i 清空 PATH 的测试，相对名字会找不到（rc=127）
case "$SHELL_BIN" in
  /*) ;;
  *) SHELL_BIN="$(command -v "$SHELL_BIN" 2>/dev/null || printf '%s' "$SHELL_BIN")" ;;
esac
WORK="$(mktemp -d /tmp/insmod-loader-sec.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

BASE="$WORK/data/adb/insmod-loader"
STAGE="$BASE/post-fs-data"
LOGS="$BASE/logs"
mkdir -p "$STAGE" "$LOGS" "$BASE/late_start"

FAKE_BIN="$WORK/bin"; mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/insmod" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_CALLS"
[ -s "$1" ] || exit 1
exit 0
EOF
chmod +x "$FAKE_BIN/insmod"

# 阶段目录之外的“诱饵”文件：任何情况下都不该被读作模块、更不该被删
OUTSIDE="$WORK/outside"
mkdir -p "$OUTSIDE"
printf 'PRECIOUS' > "$OUTSIDE/secret.ko"
printf 'KEEPME' > "$OUTSIDE/keep.txt"

run() {  # run <阶段名> <阶段目录>
  : > "$WORK/calls.txt"
  OUT="$(
    cd "$MODULE_DIR" || exit 1
    FAKE_CALLS="$WORK/calls.txt" \
    KSU_INSMOD_BASE="$BASE" \
    KSU_INSMOD_LOADER="$FAKE_BIN/insmod" \
    KSU_INSMOD_SKIP_LOAD="${SKIP_LOAD:-0}" \
    KSU_INSMOD_ALLOW_ANY="${ALLOW_ANY:-0}" \
    "$SHELL_BIN" -c '. ./insmod-loader.sh; insmod_loader_main "$1" "$2"' _ "$1" "$2" 2>&1
  )"
  RC=$?
  CALLS="$(cat "$WORK/calls.txt" 2>/dev/null)"
}

write_cfg() { printf '%b' "$1" > "$LOGS/../post-fs-data/config.txt"; }

existed_dirs() { ls -d /tmp/insmod-loader.* "$BASE"/insmod-loader.* "$STAGE"/insmod-loader.* 2>/dev/null | wc -l; }

# ---------------------------------------------------------------- A. 路径穿越
head_ "A. 路径穿越 / 目录外文件"
for spec in \
  "../outside/secret.ko:100" \
  "../../outside/secret.ko:100" \
  "./secret.ko:100" \
  "post-fs-data/../../outside/secret.ko:100" \
  "/etc/hostname:100" \
  "$OUTSIDE/secret.ko:100" \
  ".hidden/../secret.ko:100" \
  "..:100" \
  ".:100" \
; do
  printf '%s\n' "$spec" > "$STAGE/config.txt"
  run post-fs-data "$STAGE"
  if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then
    ok "拒绝目录外/穿越写法: $spec"
  else
    bad "未拒绝: $spec (rc=$RC, calls=[$CALLS])"
  fi
done

# ---------------------------------------------------------------- B. 符号链接
head_ "B. 符号链接"
# B1. .ko 是符号链接（指向目录外的真文件）—— 必须拒绝，不能加载
ln -sf "$OUTSIDE/secret.ko" "$STAGE/link.ko"
printf 'link.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then ok "拒绝符号链接 .ko"; else bad "符号链接 .ko 未被拒绝 (rc=$RC calls=[$CALLS])"; fi
if [ -f "$OUTSIDE/secret.ko" ] && [ "$(cat "$OUTSIDE/secret.ko")" = "PRECIOUS" ]; then
  ok "链接目标文件完好"
else bad "链接目标被破坏！"; fi
rm -f "$STAGE/link.ko"

# B2. config.txt 本身是符号链接 —— 必须拒绝解析
printf 'real.ko:100\n' > "$OUTSIDE/realcfg.txt"
: > "$STAGE/real.ko"
ln -sf "$OUTSIDE/realcfg.txt" "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then ok "拒绝符号链接 config.txt"; else bad "符号链接 config.txt 未被拒绝 (rc=$RC calls=[$CALLS])"; fi
rm -f "$STAGE/config.txt"

# B3. logs 目录是符号链接 —— 不能经由它写日志
rm -rf "$LOGS"; ln -sf "$OUTSIDE" "$LOGS"
printf 'real.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ ! -f "$OUTSIDE/post-fs-data.txt" ]; then
  ok "logs 为符号链接时不写入其目标目录"
else bad "经由符号链接 logs 写出了日志！"; fi
rm -f "$LOGS"; mkdir -p "$LOGS"

# B4. logs/debug 是符号链接 —— 只当作“开关”，不能被跟随
: > "$OUTSIDE/debugtarget"
ln -sf "$OUTSIDE/debugtarget" "$LOGS/debug"
run post-fs-data "$STAGE"
if [ ! -s "$OUTSIDE/debugtarget" ]; then
  ok "logs/debug 为符号链接时不跟随、不写入"
else bad "跟随了符号链接 debug"; fi
rm -f "$LOGS/debug"

# B5. 已有日志文件是符号链接 —— 必须替换而不是写到目标
: > "$OUTSIDE/precious.txt"
ln -sf "$OUTSIDE/precious.txt" "$LOGS/post-fs-data.txt"
: > "$LOGS/debug"
run post-fs-data "$STAGE"
if [ ! -s "$OUTSIDE/precious.txt" ] && [ -f "$LOGS/post-fs-data.txt" ] && [ ! -h "$LOGS/post-fs-data.txt" ]; then
  ok "符号链接日志被替换为普通文件，未写到目标"
else bad "日志经符号链接写到了别处 (target size=$(stat -c%s "$OUTSIDE/precious.txt" 2>/dev/null))"; fi
rm -f "$LOGS/debug" "$LOGS/post-fs-data.txt"

# ---------------------------------------------------------------- C. 非普通文件
head_ "C. 非普通文件"
mkfifo "$STAGE/fifo.ko" 2>/dev/null && {
  printf 'fifo.ko:100\n' > "$STAGE/config.txt"
  run post-fs-data "$STAGE"
  if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then ok "拒绝 FIFO"; else bad "FIFO 未被拒绝 (rc=$RC)"; fi
  rm -f "$STAGE/fifo.ko"
} || echo "  (跳过 FIFO: 环境不支持)"
mkdir -p "$STAGE/adir.ko"
printf 'adir.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then ok "拒绝同名目录"; else bad "同名目录未被拒绝 (rc=$RC)"; fi
rmdir "$STAGE/adir.ko"

# 不存在的文件 / 自造名称
printf 'ghost.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -ne 0 ] && [ -z "$CALLS" ]; then ok "拒绝不存在的模块文件"; else bad "不存在的文件未被拒绝"; fi

# ---------------------------------------------------------------- D. 环境异常
head_ "D. 环境异常"
# D1. 阶段目录不存在
run post-fs-data "$WORK/definitely-missing"
if [ "$RC" -ne 0 ]; then ok "阶段目录不存在时拒绝执行 (rc=$RC)"; else bad "阶段目录不存在却继续执行"; fi
# D2. 阶段目录为 / 或过于宽泛
for d in / /data /data/adb "%BASE%"; do
  [ "$d" = "%BASE%" ] && d="$BASE"
  run post-fs-data "$d"
  if [ "$RC" -ne 0 ]; then ok "拒绝宽泛阶段目录: $d"; else bad "未拒绝宽泛阶段目录: $d"; fi
done
# D3. 相对路径
run post-fs-data "relative/dir"
if [ "$RC" -ne 0 ]; then ok "拒绝相对阶段目录"; else bad "未拒绝相对阶段目录"; fi
# D4. 找不到 insmod 时应当安全退出（不加载、不报错崩溃），并把查过的路径打出来
printf 'a.ko:100\n' > "$STAGE/config.txt"; printf 'KO' > "$STAGE/a.ko"
OUT="$(cd "$MODULE_DIR" && env -i KSU_INSMOD_BASE="$BASE" KSU_INSMOD_ALLOW_ANY=0 \
  KSU_INSMOD_SEARCH_PATHS=/nonexistent/x:/nonexistent/y PATH=/nonexistent \
  "$SHELL_BIN" -c '. ./insmod-loader.sh; insmod_loader_main post-fs-data "$1"' _ "$STAGE" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '找不到 insmod' \
   && printf '%s' "$OUT" | grep -q '/nonexistent/x'; then
  ok "找不到 insmod 时拒绝执行、且报出查找过的路径"
else bad "insmod 缺失时行为异常 (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi

# D5. insmod 是符号链接时必须接受（Android 上 /system/bin/insmod -> toybox 就是这种形态）
# 注意: 这里给一个最小的、真实存在的 PATH（/system/bin:/bin 之类），因为脚本清理/建临时目录
# 需要 mkdir/mktemp/rm 等外部命令；不能用 env -i PATH=/nonexistent，
# 那样在 dash 下连 mkdir 都找不到（ash 内建才有），会掩盖本用例真正要验证的查找逻辑。
LINKBIN="$WORK/linkbin"
mkdir -p "$LINKBIN"
cat > "$WORK/realinsmod" <<'EOF'
#!/bin/sh
# 注意: 用 #!/bin/sh 而不是 /usr/bin/env bash —— 这个用例在精简环境下运行，
# env 找不到 bash 会让脚本以 127 失败，看起来像「insmod 没被调用」。
printf '%s\n' "$1" >> "$FAKE_CALLS"
exit 0
EOF
chmod +x "$WORK/realinsmod"
ln -sf "$WORK/realinsmod" "$LINKBIN/insmod"
: > "$WORK/calls.txt"
OUT="$(cd "$MODULE_DIR" && env -i KSU_INSMOD_BASE="$BASE" FAKE_CALLS="$WORK/calls.txt" \
  KSU_INSMOD_SEARCH_PATHS="$LINKBIN/insmod" PATH=/usr/bin:/bin \
  "$SHELL_BIN" -c '. ./insmod-loader.sh; insmod_loader_main post-fs-data "$1"' _ "$STAGE" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && [ -s "$WORK/calls.txt" ] && printf '%s' "$OUT" | grep -q '成功加载 1 个'; then
  ok "符号链接形式的 insmod 被正确接受并调用"
else
  bad "符号链接 insmod 未被接受 (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# D6. 不可执行的 insmod 候选必须被跳过（否则会一直失败到超时）
printf 'not executable' > "$WORK/noexec_insmod"
chmod 644 "$WORK/noexec_insmod"
OUT="$(cd "$MODULE_DIR" && env -i KSU_INSMOD_BASE="$BASE" KSU_INSMOD_ALLOW_ANY=0 \
  KSU_INSMOD_SEARCH_PATHS="$WORK/noexec_insmod" PATH=/usr/bin:/bin \
  "$SHELL_BIN" -c '. ./insmod-loader.sh; insmod_loader_main post-fs-data "$1"' _ "$STAGE" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q '找不到 insmod'; then
  ok "跳过不可执行的候选"
else bad "不可执行候选未被跳过 (rc=$RC)"; fi

# ---------------------------------------------------------------- E. 清理不误删
head_ "E. 清理动作是否会误删"
printf 'a.ko:100\n' > "$STAGE/config.txt"; printf 'KO' > "$STAGE/a.ko"
BEFORE="$(existed_dirs)"
run post-fs-data "$STAGE"
AFTER="$(existed_dirs)"
if [ "$RC" -eq 0 ] && [ "$AFTER" -le "$BEFORE" ]; then
  ok "临时目录用完即删（无残留: $AFTER）"
else bad "临时目录残留或执行失败 (before=$BEFORE after=$AFTER rc=$RC)"; fi

# 被拒绝的场景也不能残留
printf 'a.ko:9999\n' > "$STAGE/config.txt"
BEFORE="$(existed_dirs)"; run post-fs-data "$STAGE"; AFTER="$(existed_dirs)"
if [ "$AFTER" -le "$BEFORE" ]; then ok "拒绝场景同样不留临时目录"; else bad "拒绝场景残留临时目录"; fi

# 诱饵文件与目录外的文件必须原封不动
if [ "$(cat "$OUTSIDE/secret.ko")" = "PRECIOUS" ] && [ "$(cat "$OUTSIDE/keep.txt")" = "KEEPME" ]; then
  ok "阶段目录外的文件未被改写"
else bad "阶段目录外的文件被改动了！"; fi

# 回归: 数据文件（config.txt / .ko）不能因为「属主不是当前用户」被拒绝。
# 真机形态: 脚本以 root 运行，而 .ko 常由 adb push 放入 —— 属主是 shell(2000) 而非 root。
# 曾经的 bug: safe_file 里加了 [ -O ] 判定，导致正常文件也报「不是普通文件或属主异常」。
# 说明: 本地无法把文件 chown 给别人，故用「提取函数体做静态检查」锁死该判定不许回来。
extract_fn() {  # extract_fn <函数名> <文件>
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { inside = 1 }
    inside { print }
    inside && /^}/ { exit }
  ' "$2"
}
SAFE_FILE_BODY="$(extract_fn insmod_loader_safe_file "$MODULE_DIR/insmod-loader.sh")"
SAFE_DIR_BODY="$(extract_fn insmod_loader_safe_dir "$MODULE_DIR/insmod-loader.sh")"
TMPDIR_BODY="$(extract_fn insmod_loader_safe_tmpdir "$MODULE_DIR/insmod-loader.sh")"

if [ -n "$SAFE_FILE_BODY" ] && [ -n "$SAFE_DIR_BODY" ] \
   && ! printf '%s\n%s\n' "$SAFE_FILE_BODY" "$SAFE_DIR_BODY" | grep -qE '\[\s+-O\s'; then
  ok "数据文件/目录判定不含属主检查（-O）"
else
  bad "safe_file/safe_dir 里又出现了 -O 属主判定，会导致非属主文件被整体拒绝"
fi
if printf '%s' "$TMPDIR_BODY" | grep -qE '\[\s+-O\s'; then
  ok "临时目录仍保留属主校验（防止删到别人的目录）"
else bad "临时目录丢失了属主校验"; fi
# 真的跑一次: 属主是自己时当然要能加载（防止上面改动改坏正常路径）
printf 'KO' > "$STAGE/a.ko"
printf 'a.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '成功加载 1 个'; then
  ok "正常文件（属主一致）照常加载"
else bad "正常文件被拒绝: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi

# 预先占位一个同名临时目录，必须不删它（内容保留）
: > "$STAGE/config.txt"
FAKE_TMP="$STAGE/insmod-loader.$$"
mkdir -p "$FAKE_TMP"; printf 'NOTOURS' > "$FAKE_TMP/keep"
run post-fs-data "$STAGE"
if [ -f "$FAKE_TMP/keep" ] && [ "$(cat "$FAKE_TMP/keep")" = "NOTOURS" ]; then
  ok "同名但非本次创建的临时目录不会被删"
else bad "误删了他人的同名目录！"; fi
rm -rf "$FAKE_TMP"

# 阶段目录里的其它文件在运行后仍在（我们没有清理阶段目录的逻辑）
printf 'KO' > "$STAGE/a.ko"; printf 'x' > "$STAGE/notes.txt"
printf 'a.ko:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ -f "$STAGE/notes.txt" ] && [ -f "$STAGE/a.ko" ] && [ -f "$STAGE/config.txt" ]; then
  ok "阶段目录内的用户文件未被删除"
else bad "阶段目录内文件被删！"; fi
rm -f "$STAGE/notes.txt"

# ---------------------------------------------------------------- F. 功能未被破坏
head_ "F. 功能未被安全加固破坏"
printf 'KO' > "$STAGE/a.ko"; printf 'KO' > "$STAGE/b.ko"; printf 'KO' > "$STAGE/c.ko"
printf 'KO' > "$STAGE/lib..ko"          # 名字里带 .. 但仍是普通文件名，必须被接受
write_cfg 'c.ko:100\nlib..ko:500\n# 注释\n\nb.ko:500\n'
run post-fs-data "$STAGE"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '成功加载 3 个'; then
  ok "lib..ko 之类合法名可用、注释与空行正常"
else bad "功能回归: rc=$RC"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi
ORDER="$(printf '%s\n' "$CALLS" | sed 's|.*/||' | tr '\n' ' ')"
if [ "$ORDER" = "lib..ko b.ko c.ko " ]; then
  ok "优先级与同级顺序正确: $ORDER"
else bad "顺序错误: $ORDER"; fi

# 非 .ko 默认拒绝，可用开关放开
printf 'x' > "$STAGE/notako.bin"
printf 'notako.bin:100\n' > "$STAGE/config.txt"
run post-fs-data "$STAGE"
if [ "$RC" -ne 0 ]; then ok "默认拒绝非 .ko"; else bad "非 .ko 未被拒绝"; fi
ALLOW_ANY=1 run post-fs-data "$STAGE"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '成功加载 1 个'; then
  ok "KSU_INSMOD_ALLOW_ANY=1 时允许其它扩展名"
else bad "放宽开关无效 (rc=$RC)"; fi
rm -f "$STAGE/notako.bin"

echo
printf '结果: %s 通过, %s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
