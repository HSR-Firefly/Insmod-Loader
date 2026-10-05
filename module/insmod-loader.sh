#!/system/bin/sh
# insmod-loader.sh —— config.txt 解析 + 校验 + insmod 加载的共用实现。
#
# 本文件被 post-fs-data.sh 与 service.sh 以 `. <路径>` 的方式 source，
# 两个脚本的差别只有运行时机与阶段目录，其余逻辑完全共用。
#
# 用法:  . insmod-loader.sh ; insmod_loader_main <日志名> <阶段目录>
#   <日志名>   日志文件名（不含扩展名），同时也是出错时打印的程序名: post-fs-data | late_start
#   <阶段目录> 阶段目录的绝对路径（该目录下应有 config.txt 与 .ko 文件）
#
# 退出码: 0 = 校验通过并已尝试加载（含「配置为空」）；1 = 触发拒绝，未加载任何模块
#
# 环境变量（可选，便于离线测试；不设置时使用默认值）:
#   KSU_INSMOD_BASE        默认 /data/adb/insmod-loader
#   KSU_INSMOD_LOADER      默认按 insmod 绝对路径查找；可指向假 insmod 以便测试
#   KSU_INSMOD_SKIP_LOAD   非 0 时只解析与校验，不真正加载
#
# 兼容性: 全部使用 POSIX sh 语法 + POSIX test 操作符，可在 KernelSU 自带 BusyBox 的 ash
# 下运行。不使用数组（ash 不支持），待加载列表以「换行分隔的字符串」承载。
# 不依赖 awk / stat（部分设备的 toybox/busybox 未编入或输出格式不同）。
#
# ============================ 安全约定（改动前请先读） ========================
# 1. 本脚本只删自己刚创建的东西：临时目录用 mktemp -d 现建（随机名 + 原子创建，
#    umask 077），清理时只 rm 自己写过的固定文件名，再用 rmdir 收尾 ——
#    rmdir 不跟随符号链接、且目录非空必然失败，因此即使路径被做了手脚也不会误删。
#    **绝不要**改成 `rm -rf "$IL_TMPDIR_ROOT"`：变量一旦为空或路径被替换就是灾难。
# 2. 拒绝一切符号链接：config.txt、模块文件、logs 目录、logs/debug、临时目录是
#    符号链接时一律拒绝，避免被诱导向目录外读写。
# 3. 模块名只允许「阶段目录下的普通文件名」，显式禁止路径分隔符与 .. ，
#    防止 config.txt 被当成任意路径的内核模块加载器。
# 4. cd 必须成功；**绝不**在 cd 失败后回退到 / 继续用相对路径操作 ——
#    否则 config.txt 里的相对文件名会被解析到根目录。
# 5. 日志用「先写临时文件再 mv」落地，不用 `>` 重定向覆盖既有路径（不跟随符号链接）。
# 6. insmod 只走绝对路径，不走 PATH。

# ---------------- 运行环境（ash / BusyBox / mksh / dash / bash 通用）----------
# 不使用 set -u / pipefail，避免在 BusyBox ash 下行为不一致。

insmod_loader_main() {
  IL_NAME="${1:-insmod-loader}"
  IL_DIR="${2:-}"

  IL_BASE="${KSU_INSMOD_BASE:-/data/adb/insmod-loader}"
  IL_SKIP_LOAD="${KSU_INSMOD_SKIP_LOAD:-0}"
  IL_LOGDIR="$IL_BASE/logs"

  # insmod 候选查找路径（冒号分隔，按顺序取第一个「可执行的普通文件」）。
  # /system/bin/insmod 在 Android 上是指向 toybox 的符号链接，-f/-x 会跟随它，这是正常的。
  # 这里只列 insmod 本体/链接本身，不含 toybox 回退：
  # 候选值最终是按「单个可执行文件路径」调用的（"$IL_LOADER" "$IL_F"），不能带子命令参数。
  IL_SEARCH_PATHS="${KSU_INSMOD_SEARCH_PATHS:-/system/bin/insmod:/system/xbin/insmod:/vendor/bin/insmod:/odm/bin/insmod:/debug_ramdisk/insmod:/data/adb/ksu/bin/insmod:/data/adb/ksud/bin/insmod}"

  IL_TMPDIR_ROOT=""
  IL_CTX_TMP=""
  IL_SORT=""
  IL_RESULT=0
  IL_TOTAL=0
  IL_LOADED=0
  IL_FAILED=0        # insmod 返回非 0 的个数（用于区分「全部成功」与「部分失败」）

  # ---------------- 0. 路径与运行环境自检（拒绝在坏路径上做任何事）----------
  case "$IL_DIR" in
    /*) ;;
    *)
      printf '%s: 阶段目录不是绝对路径，拒绝执行: 「%s」\n' "$IL_NAME" "$IL_DIR"
      return 1 ;;
  esac
  if [ "$IL_DIR" = "/" ]; then
    printf '%s: 阶段目录为根目录，拒绝执行\n' "$IL_NAME"
    return 1
  fi
  case "$IL_DIR" in
    /|/data|/data/adb|/data/adb/insmod-loader|"$IL_BASE")
      printf '%s: 阶段目录过于宽泛，拒绝执行: %s\n' "$IL_NAME" "$IL_DIR"
      return 1 ;;
  esac

  # insmod 只认绝对路径，不走 PATH（避免 PATH 被污染时执行到别的程序）
  IL_LOADER="$(insmod_loader_find_insmod)"
  if [ -z "$IL_LOADER" ]; then
    printf '%s: 找不到 insmod 可执行文件，跳过执行\n' "$IL_NAME"
    printf '%s: 已尝试以下路径（要求是可执行的普通文件，符号链接会被跟随）:\n' "$IL_NAME"
    printf '%s:   %s\n' "$IL_NAME" "$IL_SEARCH_PATHS"
    printf '%s: 可在设备上执行 which insmod / ls -l /system/bin/insmod 确认实际位置\n' "$IL_NAME"
    return 1
  fi

  # cd 必须成功。绝不在 cd 失败后回退到 / 继续用相对路径操作 —— 那会把
  # config.txt 里的相对文件名解析到根目录，等于接受任意路径的模块。
  if ! cd "$IL_DIR" 2>/dev/null; then
    printf '%s: 无法进入阶段目录，拒绝执行: %s\n' "$IL_NAME" "$IL_DIR"
    return 1
  fi
  IL_CONFIG="./config.txt"

  # ---------------- 1. 建临时目录 ------------------------------------------
  if ! insmod_loader_make_tmpdir; then
    printf '%s: 无法创建临时目录，跳过执行\n' "$IL_NAME"
    return 1
  fi

  # ---------------- 2. 读取并校验整个 config.txt（全有或全无）--------------
  # 校验通过前不加载任何东西；只要有一条不合法，就整体拒绝。
  insmod_loader_parse_and_validate

  # ---------------- 3. 按优先级从高到低加载 --------------------------------
  if [ "$IL_RESULT" -eq 0 ]; then
    # IL_ORDER 每行 = 「优先级<空格>文件名」，优先级已按数值降序排好
    while IFS= read -r il_line || [ -n "$il_line" ]; do
      [ -n "$il_line" ] || continue
      il_p="${il_line%% *}"
      IL_F="${il_line#* }"

      if [ -z "$IL_F" ] || [ "$IL_F" = "$il_line" ]; then
        continue
      elif [ ! -f "$IL_F" ]; then
        # 理论上不可达: 校验阶段已确认过文件存在
        insmod_loader_out "$IL_NAME: 模块文件不存在，跳过: $IL_F"
      else
        insmod_loader_out "$IL_NAME: insmod $IL_F (优先级 $il_p)"
        if [ "$IL_SKIP_LOAD" != "0" ]; then
          insmod_loader_out "$IL_NAME: [skip-load] 未真正执行 insmod（测试模式）"
          IL_LOADED=$((IL_LOADED + 1))
        elif "$IL_LOADER" "$IL_F" >> "$IL_CTX_TMP" 2>&1; then
          IL_LOADED=$((IL_LOADED + 1))
        else
          il_rc=$?
          IL_FAILED=$((IL_FAILED + 1))
          insmod_loader_out "$IL_NAME: 加载 $IL_F 失败（返回码 $il_rc，内核模块无法加载）"
        fi
      fi
    done <<EOF
$IL_ORDER
EOF
    insmod_loader_out "$IL_NAME: 共 $IL_TOTAL 个模块，成功加载 $IL_LOADED 个，失败 $IL_FAILED 个"
  fi

  # ---------------- 4. 把结果写进 KernelSU 模块描述（override.description）--
  # 在写日志之前做: 让这行也进日志，便于确认状态有没有写成功。
  insmod_loader_update_description

  # ---------------- 5. debug 开关: 落盘本次 stdout 日志 --------------------
  # 以 $IL_LOGDIR/debug 文件的存在与否作为开关（内容无关）。
  insmod_loader_write_debug_log

  # ---------------- 6. 清理：只删自己创建的东西 ----------------------------
  insmod_loader_cleanup_tmpdir

  unset IL_FILE IL_PRIO IL_LINE IL_F IR IL_P 2>/dev/null
  return "$IL_RESULT"
}

# ---------------- 覆写模块描述（KernelSU override.description）---------------
# 三种结果:
#   拒绝加载          -> ❎加载被拒绝，请检查
#   全部成功          -> ✅共 x 个内核模块，成功加载 x 个
#   有模块加载失败    -> ❗共 x 个内核模块，成功加载 x 个，加载失败 y 个
#
# 实现要点:
#   - 用 ksud CLI，模块 ID 由 KernelSU 通过环境变量 KSU_MODULE 提供（这正是文档推荐的用法），
#     避免把模块 ID 硬编码在这里。
#   - 写**持久**配置而不是 --temp: 临时配置会在「每次启动的 post-fs-data 阶段」被清除，
#     而 post-fs-data.sh 恰好在那个阶段里运行，写 --temp 可能立刻被清掉，状态就不显示了。
#     持久配置重启后保留，卸载模块时由 KernelSU 自动删除。
#   - 失败一律静默（只记到日志里）: 覆写描述只是锦上添花，绝不能因此影响模块加载结果。
insmod_loader_update_description() {
  il_msg=""

  if [ "$IL_RESULT" -ne 0 ]; then
    il_msg="❎加载被拒绝，请检查"
  elif [ "$IL_FAILED" -gt 0 ]; then
    il_msg="❗共 $IL_TOTAL 个内核模块，成功加载 $IL_LOADED 个，加载失败 $IL_FAILED 个"
  else
    il_msg="✅共 $IL_TOTAL 个内核模块，成功加载 $IL_LOADED 个"
  fi

  # 离线测试用: 只看将要写入的文本，不真的调用 ksud
  if [ "${IL_DESC_DRY_RUN:-0}" != "0" ]; then
    insmod_loader_out "$IL_NAME: [dry-run] override.description = $il_msg"
    return 0
  fi

  # 只在 KernelSU 模块脚本环境里写配置:
  # 否则 ksud 会用默认身份去写，可能污染别的模块。KSU_MODULE 由 KernelSU 注入为模块 ID。
  if [ -z "${KSU_MODULE:-}" ] && [ "${KSU:-}" != "true" ]; then
    insmod_loader_out "$IL_NAME: 非 KernelSU 模块脚本环境（KSU_MODULE/KSU 未设置），跳过覆写模块描述"
    return 0
  fi

  il_ksud="$(insmod_loader_find_ksud)"
  if [ -z "$il_ksud" ]; then
    insmod_loader_out "$IL_NAME: 未找到 ksud，跳过覆写模块描述"
    return 0
  fi

  if "$il_ksud" module config set override.description "$il_msg" >/dev/null 2>&1; then
    insmod_loader_out "$IL_NAME: 模块描述已更新: $il_msg"
  else
    insmod_loader_out "$IL_NAME: 覆写模块描述失败（不影响加载结果）"
  fi
  return 0
}

# ksud 查找: 同样只走绝对路径候选，不走 PATH
insmod_loader_find_ksud() {
  if [ -n "${KSU_INSMOD_KSUD:-}" ]; then
    printf '%s\n' "$KSU_INSMOD_KSUD"
    return 0
  fi
  if command -v ksud >/dev/null 2>&1; then
    printf '%s\n' "$(command -v ksud)"
    return 0
  fi
  for il_k in /data/adb/ksu/bin/ksud /data/adb/ksud /system/bin/ksud; do
    if [ -f "$il_k" ] && [ -x "$il_k" ]; then
      printf '%s\n' "$il_k"
      return 0
    fi
  done
  return 0
}

# ---------------- insmod 绝对路径查找 ----------------------------------------
# 优先环境变量（离线测试用）；否则在固定候选路径里按顺序找第一个可执行的普通文件。
#
# ⚠️ 这里**不能**拒绝符号链接：Android 上 /system/bin/insmod 本身就是
#    `insmod -> toybox`（或 busybox）的符号链接，加了 [ ! -h ] 判断会导致
#    「明明存在却报找不到 insmod」。insmod 只被「执行」，从不被写入或删除，
#    因此跟随符号链接没有安全风险（真正的安全要求是它必须是可执行的普通文件，
#    而 PATH 已经被绕开了）。
# 找不到时返回空串，由调用方拒绝执行（宁可不动，也不用 PATH 里不确定的程序）。
# 查找路径用 IL_SEARCH_PATHS，可用 KSU_INSMOD_SEARCH_PATHS 覆盖（冒号分隔，仅供测试）。
insmod_loader_find_insmod() {
  if [ -n "${KSU_INSMOD_LOADER:-}" ]; then
    printf '%s\n' "$KSU_INSMOD_LOADER"
    return 0
  fi

  # 逐个候选检查: 可执行的普通文件（-f / -x 都会跟随符号链接，这正是我们要的）
  il_old_ifs="$IFS"
  IFS=':'
  for il_c in $IL_SEARCH_PATHS; do
    IFS="$il_old_ifs"
    [ -n "$il_c" ] || continue
    if [ -f "$il_c" ] && [ -x "$il_c" ]; then
      printf '%s\n' "$il_c"
      return 0
    fi
    IFS=':'
  done
  IFS="$il_old_ifs"
  return 0
}

# ---------------- 通用安全判定（只用 POSIX test，不依赖 awk/stat）------------
# 判定「可安全读取的普通文件」: 不是符号链接、且确实是普通文件。
#
# ⚠️ 这里**故意不检查属主**（不要加 `[ -O "$1" ]`）：
#    本脚本以 root 运行，而用户放 .ko / 改 config.txt 的常见方式是 `adb push`，
#    那样文件属主是 shell(2000)，不是 root。一旦要求「属主必须是当前用户」，
#    正常文件也会被判为「不是普通文件或属主异常」而整体拒绝加载。
#    属主检查对安全也没有帮助：非 root 用户本来就写不进 /data/adb（0700），
#    而能写进去的人已经是 root，伪造一个 root 属主的文件轻而易用。
#    真正的边界是「不是符号链接」+「阶段目录 0700」。
insmod_loader_safe_file() {
  [ -h "$1" ] && return 1
  [ -f "$1" ] || return 1
  return 0
}

# 目录、不是符号链接（同样不检查属主，理由同上）
insmod_loader_safe_dir() {
  [ -h "$1" ] && return 1
  [ -d "$1" ] || return 1
  return 0
}

# 仅用于「临时目录」这一处: 只接受属主就是当前进程的目录。
# 临时目录里放的是本次运行自己写的临时文件（随后会被删），
# 用别人的目录意味着可能删到与本次运行无关的东西，所以这里必须有属主校验。
insmod_loader_safe_tmpdir() {
  insmod_loader_safe_dir "$1" || return 1
  [ -O "$1" ] || return 1
  return 0
}

# ---------------- 临时目录: 现建、私有权限、随用随删 -------------------------
insmod_loader_make_tmpdir() {
  il_prev_umask="$(umask)"
  umask 077                    # 临时目录/文件不给同机其他用户任何权限

  for il_d in "${TMPDIR:-/tmp}" "$IL_DIR" "$IL_BASE" /tmp /dev; do
    insmod_loader_safe_dir "$il_d" || continue     # 只要求是目录（不要求属主: 见函数注释）
    [ -w "$il_d" ] || continue

    il_t=""
    if command -v mktemp >/dev/null 2>&1; then
      # 随机名 + 原子创建：别人无法预测名字，也没机会预先占位
      il_t="$(mktemp -d "$il_d/insmod-loader.XXXXXXXX" 2>/dev/null)" || il_t=""
    fi
    if [ -z "$il_t" ]; then
      # 退化路径（无 mktemp）: 名字可预测，因此额外要求「非符号链接 + 属主是自己」
      il_t="$il_d/insmod-loader.$$"
      ( umask 077; mkdir "$il_t" ) 2>/dev/null || il_t=""
      if ! insmod_loader_safe_tmpdir "$il_t"; then
        il_t=""
      fi
    fi
    # 无论哪条路径建出来的，都要求它是「自己的、非符号链接的目录」才敢往里写/删
    if [ -z "$il_t" ] || ! insmod_loader_safe_tmpdir "$il_t"; then
      continue
    fi

    IL_TMPDIR_ROOT="$il_t"
    IL_CTX_TMP="$il_t/stdout"
    IL_SORT="$il_t/order"
    : > "$IL_CTX_TMP" 2>/dev/null || { IL_TMPDIR_ROOT=""; continue; }
    break
  done

  umask "$il_prev_umask"
  [ -n "$IL_TMPDIR_ROOT" ] || return 1
  return 0
}

# ---------------- 清理临时目录（绝不递归删除）--------------------------------
# 只删自己写入的两个固定文件名，再用 rmdir 收尾：
#   - rmdir 不跟随符号链接（对符号链接返回 ENOTDIR），失败也不会伤到任何东西；
#   - 目录非空时 rmdir 必然失败，所以即使路径被替换，也不会波及其它内容；
#   - rm 的目标是两个固定文件名，不对变量做通配展开，不可能变成 rm -rf。
insmod_loader_cleanup_tmpdir() {
  [ -n "$IL_TMPDIR_ROOT" ] || return 0
  case "$IL_TMPDIR_ROOT" in
    */insmod-loader.*) ;;        # 兜底：只处理符合我们命名规则的目录
    *)
      IL_TMPDIR_ROOT=""
      return 0 ;;
  esac
  insmod_loader_safe_tmpdir "$IL_TMPDIR_ROOT" || { IL_TMPDIR_ROOT=""; return 0; }
  rm -f "$IL_TMPDIR_ROOT/order" 2>/dev/null
  rm -f "$IL_TMPDIR_ROOT/stdout" 2>/dev/null
  rmdir "$IL_TMPDIR_ROOT" 2>/dev/null
  IL_TMPDIR_ROOT=""
  return 0
}

# ---------------- 解析 + 校验 -------------------------------------------------
# 依赖 main 预先建好的 $IL_SORT / $IL_CTX_TMP（临时目录由 main 统一清理）。
# 成功: IL_ORDER = 按优先级从高到低排好序的「优先级<空格>文件名」列表（换行分隔），
#       IL_TOTAL = 条目数，IL_RESULT=0
# 失败: IL_RESULT=1，并已打印拒绝原因
insmod_loader_parse_and_validate() {
  IL_ORDER=""
  IL_LINENO=0
  IL_COUNT=0

  if [ ! -e "$IL_CONFIG" ]; then
    insmod_loader_reject "找不到配置文件 $IL_DIR/config.txt"
    return 1
  fi
  if ! insmod_loader_safe_file "$IL_CONFIG"; then
    insmod_loader_reject "配置文件不是普通文件，或是个符号链接，拒绝解析: $IL_DIR/config.txt"
    return 1
  fi

  : > "$IL_SORT" 2>/dev/null || {
    insmod_loader_reject "无法创建临时文件，无法解析 $IL_DIR/config.txt"
    return 1
  }

  # 第一遍: 逐行做语法校验，并把「优先级<空格>行号<空格>文件名」写入排序用的临时文件
  while IFS= read -r IL_LINE || [ -n "$IL_LINE" ]; do
    IL_LINENO=$((IL_LINENO + 1))

    # --- 行预处理: 只做「不影响语义的宽容处理」，不放过任何真正的语法错误 ---
    # 1) 去掉 UTF-8 BOM（Windows 记事本另存会加，导致第一个文件名多出 3 个字节）。
    #    注意必须是 #??? （3 个字符）: BOM 是 3 字节，而参数展开的 ? 是按「字符」匹配的。
    case "$IL_LINE" in
      "$(printf '\357\273\277')"*) IL_LINE="${IL_LINE#???}" ;;
    esac
    # 2) 容忍 CRLF: 行尾 CR 视为换行的一部分
    case "$IL_LINE" in
      *"$(printf '\r')") IL_LINE="${IL_LINE%?}" ;;
    esac
    # 3) 去掉行首/行尾的（半角）空白: 用户手写配置时极易多打空格/Tab，
    #    这类写法意图明确（文件名与优先级都在），不该整份配置被拒绝。
    #    ⚠️ 只删行首行尾；文件名**中间**的空白仍然是错误（见下面的文件名校验）。
    #    注意: 不要用 `tr -d '[:space:]'` 判空行 —— 部分 BusyBox 构建不展开该字符类。
    case "$IL_LINE" in
      *[!\ ]*) ;;                                    # 含非空格字符，继续处理
      *) continue ;;                                 # 整行都是空格 -> 空行
    esac
    IL_LINE="$(printf '%s' "$IL_LINE" | sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')"
    [ -n "$IL_LINE" ] || continue                    # 行首/行尾空白删完就空了

    case "$IL_LINE" in
      '#'*) continue ;;                              # 注释行，忽略
    esac

    IL_F="${IL_LINE%%:*}"
    IR="${IL_LINE#*:}"

    # 中文全角冒号是手写配置时最常见的笔误，单独给一句更明确的提示。
    # ⚠️ 这一条必须放在「缺少分隔冒号」判断**之前**：全角行里没有半角冒号，
    #    IL_F == 整行、IR == 整行，先判「缺冒号」会让这条提示永远无法命中。
    case "$IL_LINE" in
      *：*)
        insmod_loader_reject "第 $IL_LINENO 行使用了中文全角冒号「：」，请改成半角冒号「:」: $IL_LINE"
        return 1 ;;
    esac

    if [ "$IR" = "$IL_LINE" ]; then                  # 行内没有冒号
      insmod_loader_reject "第 $IL_LINENO 行语法错误（缺少分隔冒号），应为「模块文件名:优先级」: $IL_LINE"
      return 1
    fi

    # 去掉分隔冒号两侧的空白: `mydriver.ko : 100` 这种写法意图明确，不该整份拒绝。
    # 注意只删两侧 —— 文件名**中间**的空白仍然是错误（见下面的文件名校验）。
    IL_F="$(printf '%s' "$IL_F" | sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')"
    IR="$(printf '%s' "$IR" | sed -e 's/^[ 	]*//' -e 's/[ 	]*$//')"

    # 模块文件名: 必须是本目录下的普通文件名。
    # 显式禁止路径分隔符与 ..（只允许「阶段目录/文件名」这一种形态），
    # 否则 config.txt 会变成任意路径的内核模块加载器。
    # 注意: '' 这一支不能省（模式里的 * 匹配不了空串）；`*/../*` 不能写成 `*..*`，
    # 否则会误杀 my..ko 这种合法名字。
    case "$IL_F" in
      ''|.|..|/*|*/../*|../*|*/*|*[[:space:]]*)
        insmod_loader_reject "第 $IL_LINENO 行的模块文件名非法: 「$IL_F」（只能是本目录下的普通文件名: 不能为空、不能含空白或路径分隔符、不能是 . 或 ..）"
        return 1 ;;
    esac

    # 优先级: 必须是十进制整数（拒绝 +1 / 0x10 / 1.5 / 空 等写法）
    case "$IR" in
      ''|*[!0-9]*)
        insmod_loader_reject "第 $IL_LINENO 行的优先级非法: 「$IR」（必须是 1-999 的十进制整数）"
        return 1 ;;
    esac

    while [ "${#IR}" -gt 1 ] && [ "${IR#0}" != "$IR" ]; do
      IR="${IR#0}"                                   # 去前导零（0999 记为 999）
    done
    if [ "${#IR}" -gt 3 ]; then
      insmod_loader_reject "第 $IL_LINENO 行的优先级 $IR 超出范围（必须在 1-999 之间）"
      return 1
    fi
    IL_P=$((IR + 0))
    if [ "$IL_P" -lt 1 ] || [ "$IL_P" -gt 999 ]; then
      insmod_loader_reject "第 $IL_LINENO 行的优先级 $IL_P 超出范围（必须在 1-999 之间）"
      return 1
    fi

    # 默认只接受 .ko（阶段目录里允许放别的辅助文件，但它们不会被当作模块加载）。
    # 路径安全由上面的检查保证；这一条只是防手误。确有其它扩展名需求时可用
    # KSU_INSMOD_ALLOW_ANY=1 关闭该限制（此时「文件确实存在且是普通文件」仍然强制）。
    # 放在存在性检查之前: 这样 x.zip 存在时会说「不是 .ko」而不是误报「文件不存在」。
    if [ "${KSU_INSMOD_ALLOW_ANY:-0}" = "0" ]; then
      case "$IL_F" in
        *.ko) ;;
        *)
          insmod_loader_reject "第 $IL_LINENO 行指定的 $IL_F 不是 .ko 内核模块文件（如确需其它扩展名，设 KSU_INSMOD_ALLOW_ANY=1）"
          return 1 ;;
      esac
    fi

    # 文件安全检查：符号链接 / 非普通文件，一律拒绝（不检查属主，见 safe_file 注释）
    if ! insmod_loader_safe_file "$IL_F"; then
      if [ -h "$IL_F" ]; then
        insmod_loader_reject "第 $IL_LINENO 行指定的 $IL_F 是符号链接，拒绝加载（可能被指向目录外）"
      elif [ -d "$IL_F" ]; then
        insmod_loader_reject "第 $IL_LINENO 行指定的 $IL_F 是目录，不是内核模块文件"
      elif [ ! -e "$IL_F" ]; then
        insmod_loader_reject "第 $IL_LINENO 行指定的模块文件不存在: $IL_DIR/$IL_F"
      else
        insmod_loader_reject "第 $IL_LINENO 行指定的 $IL_F 不是普通文件，拒绝加载"
      fi
      return 1
    fi

    printf '%s %s %s\n' "$IL_P" "$IL_LINENO" "$IL_F" >> "$IL_SORT"
    IL_COUNT=$((IL_COUNT + 1))
  done < "$IL_CONFIG"

  if [ "$IL_COUNT" -eq 0 ]; then
    insmod_loader_out "$IL_NAME: 配置文件中没有指定任何内核模块，无需加载"
    return 0
  fi

  # 第二遍: 按优先级数值降序（-k1,1nr），同优先级按行号升序（-k2,2n)。
  # 临时文件每行 = 「优先级<空格>行号<空格>文件名」；这里只去掉行号，保留优先级，
  # 得到 IL_ORDER 的每行 = 「优先级<空格>文件名」。
  IL_ORDER="$(sort -k1,1nr -k2,2n "$IL_SORT" 2>/dev/null | sed 's/ [0-9][0-9]* / /')"

  if [ -z "$IL_ORDER" ]; then
    insmod_loader_reject "解析 $IL_DIR/config.txt 失败（sort 不可用或临时文件读写异常）"
    return 1
  fi

  IL_TOTAL="$IL_COUNT"
  return 0
}

# ---------------- 日志落盘（原子替换，绝不重定向覆盖既有路径）----------------
insmod_loader_write_debug_log() {
  [ -e "$IL_LOGDIR/debug" ] || return 0
  if ! insmod_loader_safe_file "$IL_LOGDIR/debug"; then
    printf '%s: logs/debug 不是普通文件，忽略日志开关\n' "$IL_NAME"
    return 0
  fi
  if ! insmod_loader_safe_dir "$IL_LOGDIR"; then
    printf '%s: logs 目录不可用（不存在或不是目录），跳过写日志\n' "$IL_NAME"
    return 0
  fi

  IL_LOG="$IL_LOGDIR/$IL_NAME.txt"
  il_tmp_log="$IL_LOG.new.$$"

  # 先写临时文件，成功后再 mv：mv 是替换而非跟随，不会经由符号链接写到别处
  if ! {
    printf '# stage=%s\n' "$IL_NAME"
    printf '# config=%s\n' "$IL_CONFIG"
    printf '# result=%s\n' "$IL_RESULT"
    printf '# time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    cat "$IL_CTX_TMP" 2>/dev/null
  } > "$il_tmp_log" 2>/dev/null; then
    rm -f "$il_tmp_log" 2>/dev/null
    printf '%s: 日志写入失败（无法创建 %s）\n' "$IL_NAME" "$il_tmp_log"
    return 0
  fi

  if mv -f "$il_tmp_log" "$IL_LOG" 2>/dev/null; then
    printf '%s: 日志已写入 %s\n' "$IL_NAME" "$IL_LOG"
  else
    rm -f "$il_tmp_log" 2>/dev/null
    printf '%s: 日志写入失败: %s\n' "$IL_NAME" "$IL_LOG"
  fi
  return 0
}

# ---------------- 输出: 同时镜像到上下文临时文件（debug 时整体落盘）----------
insmod_loader_out() {
  printf '%s\n' "$1"
  if [ -n "$IL_CTX_TMP" ] && [ -f "$IL_CTX_TMP" ]; then
    printf '%s\n' "$1" >> "$IL_CTX_TMP"
  fi
  return 0
}

# ---------------- 拒绝: 打印原因，且本次不加载任何模块 ------------------------
insmod_loader_reject() {
  insmod_loader_out "$IL_NAME: 拒绝加载: $1"
  insmod_loader_out "$IL_NAME: 本次不加载任何内核模块，跳过执行"
  IL_RESULT=1
  return 1
}
