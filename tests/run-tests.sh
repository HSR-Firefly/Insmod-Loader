#!/usr/bin/env bash
# 本地离线测试 insmod-loader.sh 的解析/校验/排序/日志分支
# 用法: bash tests/run-tests.sh
set -u

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../module" && pwd)"
WORK="$(mktemp -d /tmp/insmod-loader-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

# 假 insmod: 记录调用顺序，返回 0；对 0 字节的 .ko 返回 1（模拟加载失败）
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/insmod" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FAKE_CALLS"
if [ ! -s "$1" ]; then
  echo "insmod: ERROR: could not insert module $1: Invalid module format" >&2
  exit 1
fi
exit 0
EOF
chmod +x "$FAKE_BIN/insmod"

# 建模拟设备目录树
BASE="$WORK/data/adb/insmod-loader"
mkdir -p "$BASE/post-fs-data" "$BASE/late_start" "$BASE/logs"

# 预置「可加载成功」的 .ko 桩文件（内容非空 == 假 insmod 返回 0）
make_kos() {
  local dir="$1"; shift
  mkdir -p "$dir"
  for n in "$@"; do printf 'KO' > "$dir/$n"; done
}

# 直接执行加载器: run_raw <阶段名> <阶段目录> <调用记录文件>
# 结果放在全局 RAW_OUT / RAW_RC
run_raw() {
  : > "$3"
  RAW_OUT="$(
    cd "$MODULE_DIR" || exit 1
    FAKE_CALLS="$3" \
    KSU_INSMOD_BASE="$BASE" \
    KSU_INSMOD_LOADER="$FAKE_BIN/insmod" \
    KSU_INSMOD_SKIP_LOAD=0 \
    sh -c '. ./insmod-loader.sh; insmod_loader_main "$1" "$2"' _ "$1" "$2" 2>&1
  )"
  RAW_RC=$?
}

# 场景执行器: run_case <阶段> <配置内容> <期望结果: pass|reject> <期望stdout关键字>
run_case() {
  local stage="$1" cfg="$2" expect="$3" keyword="$4"
  local dir="$BASE/$stage"
  mkdir -p "$dir"
  make_kos "$dir" a.ko b.ko c.ko x.ko y.ko
  printf '%b' "$cfg" > "$dir/config.txt"

  local calls="$WORK/calls.$stage.txt"
  local out rc
  run_raw "$stage" "$dir" "$calls"
  out="$RAW_OUT"; rc="$RAW_RC"
  local label="[$stage] ${keyword}"
  if [ "$expect" = "pass" ] && [ "$rc" -ne 0 ]; then
    bad "$label -> 期望通过，实际 rc=$rc"; printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  if [ "$expect" = "reject" ]; then
    if [ "$rc" -eq 0 ]; then
      bad "$label -> 期望拒绝，实际 rc=0"; printf '%s\n' "$out" | sed 's/^/       /'
      return
    fi
    if [ -s "$calls" ]; then
      bad "$label -> 触发拒绝却仍然调用了 insmod"; printf '%s\n' "$out" | sed 's/^/       /'
      return
    fi
    if ! printf '%s' "$out" | grep -q '拒绝加载'; then
      bad "$label -> 缺少「拒绝加载」原因输出"; printf '%s\n' "$out" | sed 's/^/       /'
      return
    fi
  fi
  if ! printf '%s' "$out" | grep -q "$keyword"; then
    bad "$label -> stdout 未包含关键字「$keyword」(rc=$rc)"; printf '%s\n' "$out" | sed 's/^/       /'
    return
  fi
  ok "$label"
}

echo "== 场景组 1: 正常加载与优先级排序 =="
# 优先级: 500 > 300 > 100，配置文件里的书写顺序故意打乱
run_case post-fs-data '#语法:模块:执行优先级(1-999)\n# 注释行\nb.ko:300\n\na.ko:500\nc.ko:100\n' pass '成功加载 3 个'
ORDER="$(sed 's|.*/||' "$WORK/calls.post-fs-data.txt" | tr '\n' ' ')"
if [ "$ORDER" = "a.ko b.ko c.ko " ]; then ok "加载顺序按优先级降序: $ORDER"
else bad "加载顺序错误: $ORDER（期望 a.ko b.ko c.ko）"; fi

echo "== 场景组 2: 各类拒绝分支 =="
run_case post-fs-data 'a.ko:1000\n'   reject '超出范围'
run_case post-fs-data 'a.ko:0\n'      reject '超出范围'
run_case post-fs-data 'a.ko:\n'       reject '优先级非法'
run_case post-fs-data 'a.ko:abc\n'    reject '优先级非法'
run_case post-fs-data 'a.ko:1.5\n'    reject '优先级非法'
run_case post-fs-data 'a.ko:0x10\n'   reject '优先级非法'
run_case post-fs-data 'a.ko:+5\n'     reject '优先级非法'
run_case post-fs-data 'nope.ko:100\n' reject '模块文件不存在'
run_case post-fs-data 'a.ko\n'        reject '语法错误'
run_case post-fs-data 'a b.ko:100\n'  reject '文件名非法'
run_case post-fs-data ':100\n'        reject '文件名非法'
run_case post-fs-data '..:100\n'      reject '文件名非法'
run_case post-fs-data 'a.ko-100\n'    reject '语法错误'

echo "== 场景组 3: 边界与合法写法 =="
run_case post-fs-data 'a.ko:999\n'    pass '优先级 999'
run_case post-fs-data 'a.ko:001\n'    pass '优先级 1'
run_case post-fs-data 'a.ko:1\n'      pass '优先级 1'
# 0999 去前导零后为 999，合法
run_case post-fs-data 'a.ko:0999\n'   pass '优先级 999'
# CRLF 换行
run_case post-fs-data 'a.ko:100\r\nc.ko:200\r\n' pass '成功加载 2 个'
# 纯注释 / 空行 / 纯空白行
run_case post-fs-data '# 只有注释\r\n\n   \n\t\n'  pass '没有指定任何内核模块'
# 同一文件登记两次（按两次加载处理）
run_case post-fs-data 'a.ko:100\na.ko:200\n'    pass '成功加载 2 个'

echo "== 场景组 3b: 手写配置的宽容处理（这些写法必须被接受，不能整份拒绝） =="
# 行的首尾空白、分隔冒号两侧空白、UTF-8 BOM、Tab 缩进 —— 都是用户手写/记事本保存时的常见形态。
# 回归背景: 这些曾因「行首行尾空白」和「冒号两侧空白」被整份拒绝。
run_case post-fs-data 'a.ko:100 \n'     pass '成功加载 1 个'      # 行尾空格
run_case post-fs-data 'a.ko:100\t\n'    pass '成功加载 1 个'      # 行尾 Tab
run_case post-fs-data 'a.ko: 100\n'     pass '成功加载 1 个'      # 冒号后空格
run_case post-fs-data 'a.ko :100\n'     pass '成功加载 1 个'      # 冒号前空格
run_case post-fs-data 'a.ko : 100\n'    pass '成功加载 1 个'      # 冒号两侧空格
run_case post-fs-data '  a.ko:100\n'    pass '成功加载 1 个'      # 行首空格
run_case post-fs-data '\ta.ko:100\n'    pass '成功加载 1 个'      # 行首 Tab
run_case post-fs-data '\xef\xbb\xbfa.ko:100\n' pass '成功加载 1 个'  # UTF-8 BOM
run_case post-fs-data '\xef\xbb\xbfa.ko:100 \r\n' pass '成功加载 1 个' # BOM+CRLF+尾空格
# 但文件名中间的空白仍然是错误
run_case post-fs-data 'a b.ko:100\n'    reject '文件名非法'
# 中文全角冒号给出专门提示（不是笼统的「缺少分隔冒号」）
run_case post-fs-data 'a.ko：100\n'     reject '全角冒号'

echo "== 场景组 4: insmod 失败不视为拒绝 =="
# 用 0 字节的 .ko 让假 insmod 返回非 0：加载失败不等于配置被拒绝
run_case post-fs-data 'a.ko:100\n' pass '成功加载 1 个'
: > "$BASE/post-fs-data/a.ko"
: > "$BASE/logs/debug"                       # 开 debug，确认 insmod 的 stderr 也落盘
run_raw post-fs-data "$BASE/post-fs-data" "$WORK/calls.badko.txt"
if [ "$RAW_RC" -eq 0 ] && printf '%s' "$RAW_OUT" | grep -q '成功加载 0 个' \
   && printf '%s' "$RAW_OUT" | grep -q '加载 a.ko 失败' \
   && grep -q 'insmod: ERROR' "$BASE/logs/post-fs-data.txt"; then
  ok "insmod 失败时: 不判为拒绝、记录失败原因、insmod 的 stderr 落盘"
else
  bad "insmod 失败路径行为异常 (rc=$RAW_RC)"; printf '%s\n' "$RAW_OUT" | sed 's/^/       /'
  sed 's/^/       log: /' "$BASE/logs/post-fs-data.txt" 2>/dev/null
fi
rm -f "$BASE/logs/debug"

echo "== 场景组 4b: 覆写模块描述（override.description） =="
# 用 IL_DESC_DRY_RUN=1 打印将要写入的描述文本（不真的调用 ksud）。
# 三种结果必须是互斥且带正确数量的。
desc_of() {   # desc_of <阶段> <配置内容> [准备命令]
  local stage="$1" cfg="$2" prep="${3:-}"
  local dir="$BASE/$stage"
  mkdir -p "$dir"
  make_kos "$dir" a.ko b.ko
  printf '%b' "$cfg" > "$dir/config.txt"
  [ -n "$prep" ] && eval "$prep"
  local out
  out="$(
    cd "$MODULE_DIR" || exit 1
    KSU_INSMOD_BASE="$BASE" KSU_INSMOD_LOADER="$FAKE_BIN/insmod" KSU_INSMOD_SKIP_LOAD=0 \
    IL_DESC_DRY_RUN=1 \
    sh -c '. ./insmod-loader.sh; insmod_loader_main "$1" "$2"' _ "$stage" "$dir" 2>&1
  )"
  printf '%s' "$out" | sed -n 's/.*override\.description = //p' | tail -1
}

D="$(desc_of post-fs-data 'a.ko:100\n')"
if [ "$D" = "✅共 1 个内核模块，成功加载 1 个" ]; then ok "全部成功: $D"; else bad "全部成功描述错误: [$D]"; fi

D="$(desc_of post-fs-data 'a.ko:100\nb.ko:50\n' ': > "$BASE/post-fs-data/b.ko"')"
if [ "$D" = "❗共 2 个内核模块，成功加载 1 个，加载失败 1 个" ]; then ok "部分失败: $D"; else bad "部分失败描述错误: [$D]"; fi

D="$(desc_of post-fs-data 'a.ko:1000\n')"
if [ "$D" = "❎加载被拒绝，请检查" ]; then ok "被拒绝: $D"; else bad "被拒绝描述错误: [$D]"; fi

D="$(desc_of post-fs-data '# 只有注释\n')"
if [ "$D" = "✅共 0 个内核模块，成功加载 0 个" ]; then ok "未指定模块: $D"; else bad "空配置描述错误: [$D]"; fi

# 非 KernelSU 环境（没有 KSU_MODULE/KSU）时绝不能去调用 ksud，否则可能写到别的模块上
: > "$BASE/post-fs-data/a.ko"
printf 'a.ko:100\n' > "$BASE/post-fs-data/config.txt"
FAKE_KSUD="$WORK/ksud"; : > "$FAKE_KSUD"; chmod +x "$FAKE_KSUD"
OUT="$(
  cd "$MODULE_DIR" || exit 1
  KSU_INSMOD_BASE="$BASE" KSU_INSMOD_LOADER="$FAKE_BIN/insmod" KSU_INSMOD_KSUD="$FAKE_KSUD" \
  sh -c '. ./insmod-loader.sh; insmod_loader_main post-fs-data "$1"' _ "$BASE/post-fs-data" 2>&1
)"
if printf '%s' "$OUT" | grep -q '非 KernelSU 模块脚本环境'; then
  ok "非 KernelSU 环境下不写模块配置"
else bad "非 KernelSU 环境仍尝试写配置"; printf '%s\n' "$OUT" | sed 's/^/       /'; fi


echo "== 场景组 5: late_start 阶段独立配置 =="
run_case late_start '#语法:模块:执行优先级(1-999)\nx.ko:10\ny.ko:900\n' pass '成功加载 2 个'
ORDER="$(sed 's|.*/||' "$WORK/calls.late_start.txt" | tr '\n' ' ')"
if [ "$ORDER" = "y.ko x.ko " ]; then ok "late_start 顺序: $ORDER"
else bad "late_start 顺序错误: $ORDER（期望 y.ko x.ko）"; fi

echo "== 场景组 6: debug 开关与日志落盘 =="
# 无 debug 文件 -> 不应产生日志
rm -f "$BASE/logs/debug" "$BASE/logs/post-fs-data.txt"
run_case post-fs-data 'a.ko:100\n' pass '成功加载 1 个'
if [ -f "$BASE/logs/post-fs-data.txt" ]; then bad "无 debug 文件时不应写日志"
else ok "无 debug 文件时不写日志"; fi

# 有 debug 文件 -> 写日志
: > "$BASE/logs/debug"
run_case post-fs-data 'a.ko:100\n' pass '成功加载 1 个'
if [ -s "$BASE/logs/post-fs-data.txt" ] && grep -q 'insmod a.ko' "$BASE/logs/post-fs-data.txt"; then
  ok "有 debug 文件时写入 logs/post-fs-data.txt"
else bad "有 debug 文件却未写入日志"; cat "$BASE/logs/post-fs-data.txt" 2>/dev/null | sed 's/^/       /'; fi

# 拒绝场景也要落盘原因
run_case post-fs-data 'a.ko:1000\n' reject '超出范围'
if grep -q '拒绝加载' "$BASE/logs/post-fs-data.txt"; then ok "拒绝原因也写入日志"
else bad "拒绝原因未写入日志"; fi

# late_start 日志互不覆盖
run_case late_start 'x.ko:1\n' pass '成功加载 1 个'
if [ -s "$BASE/logs/late_start.txt" ] && [ -s "$BASE/logs/post-fs-data.txt" ]; then
  ok "两个阶段的日志分别写入两个文件"
else bad "阶段日志文件缺失"; fi

# 日志目录不存在时不应崩溃
mv "$BASE/logs" "$BASE/logs.bak"
run_case post-fs-data 'a.ko:100\n' pass '成功加载 1 个'
if [ -d "$BASE/logs.bak" ] && [ ! -f "$BASE/logs/post-fs-data.txt" ]; then
  ok "logs 目录缺失时安静降级（不写日志、不报错崩溃）"
else bad "logs 目录缺失时行为异常"; fi
mv "$BASE/logs.bak" "$BASE/logs"

echo "== 场景组 7: config.txt 缺失 =="
# 直接构造「没有 config.txt」的目录，不经 run_case（它总会写一份 config.txt）
NO_CFG="$BASE/no-config"
mkdir -p "$NO_CFG"
make_kos "$NO_CFG" a.ko
rm -f "$NO_CFG/config.txt"
run_raw post-fs-data "$NO_CFG" "$WORK/calls.noconfig.txt"
if [ "$RAW_RC" -ne 0 ] && printf '%s' "$RAW_OUT" | grep -q '找不到配置文件' \
   && [ ! -s "$WORK/calls.noconfig.txt" ]; then
  ok "[post-fs-data] 找不到配置文件 -> 拒绝且不加载"
else
  bad "[post-fs-data] 找不到配置文件 -> 未正确拒绝 (rc=$RAW_RC)"; printf '%s\n' "$RAW_OUT" | sed 's/^/       /'
fi

echo
printf '结果: %s 通过, %s 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
