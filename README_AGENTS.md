# Insmod Loader (`id=insmod-loader`, `name=Insmod Loader`)

> **这份文档给改代码的人 / AI 看**：实现细节、安全约定、校验规则、测试与打包方式。
> 面向使用者的简明说明见 [README.md](README.md)。

用 Shell 脚本在开机时按配置的优先级 `insmod` 加载指定内核模块（`.ko`）的 KernelSU 模块。

- **不需要元模块**：本模块不改 `/system`，纯脚本类模块。
- **不支持 Recovery 安装**：请在 KernelSU 管理器中刷入 zip。
- **模块代码在 `module/` 目录**（zip 根 = 该目录内容），文档与测试在仓库根，打包产物在 `output/`。

## 1. 工作原理

安装时（`customize.sh`）创建持久化目录树：

```txt
/data/adb/insmod-loader/
├── post-fs-data/
│   ├── config.txt        # 装机时创建，内容: #语法:模块:执行优先级(1-999)
│   └── *.ko              # 你自己放进去的内核模块
├── late_start/
│   ├── config.txt
│   └── *.ko
└── logs/
    └── debug             # 需要日志时手动创建（touch），内容无所谓
```

任一目录/文件创建失败 → 安装直接失败（`abort`）。

开机时两个脚本做同样的三件事，只是时机与目录不同：

| 脚本 | 时机 | 配置目录 | 日志文件 |
|---|---|---|---|
| `post-fs-data.sh` | post-fs-data（阻塞、Zygote 之前） | `post-fs-data/` | `logs/post-fs-data.txt` |
| `service.sh` | late_start（非阻塞，推荐） | `late_start/` | `logs/late_start.txt` |

两者共用同一份实现 `insmod-loader.sh`（由上面两个脚本 `source`）。两者都位于仓库的 `module/` 目录下。

## 2. config.txt 语法

```txt
#语法:模块:执行优先级(1-999)
# 以 # 开头的行会被忽略
mydriver.ko:100
another.ko:900
```

- **模块名**：必须是所在阶段目录中真实存在的**文件名**（就是 `insmod` 的参数）。
- **优先级**：十进制整数 `1-999`，**数值越大越先加载**（`900` 在 `100` 之前）。
- 优先级相同的条目，按它们在配置文件里出现的先后顺序加载。
- 空行、纯空白行、`#` 开头的行为注释，全部忽略。
- 每行只取第一个冒号作为分隔符（文件名里不要带冒号）。
- 同一个文件名可以登记两次（会 `insmod` 两次，第二次通常返回 "File exists"）。

## 3. 拒绝加载（全有或全无）

逐行校验**整个** config.txt，只要命中任意一条，本次**一个模块都不加载**并在 stdout 打印原因：

| 情况 | 拒绝原因输出 |
|---|---|
| 优先级超出 1-999（如 `1000`、`0`） | `优先级 ... 超出范围` |
| 优先级不是十进制整数（`abc`、`1.5`、`0x10`、`+5`、空） | `优先级非法` |
| 行内没有冒号（如 `a.ko 100`） | `语法错误（缺少分隔冒号）` |
| 文件名称为空、含空白、含路径分隔符、或为 `.` / `..` | `文件名非法` |
| 名称对应的文件不存在（或是个目录、FIFO、符号链接、非 `.ko`） | `模块文件不存在` / 相应说明 |
| 找不到 `config.txt` | `找不到配置文件` |

> 例外：单个模块 **insmod 失败**（版本不匹配、依赖缺失等）**不算拒绝**——其余模块仍会继续加载，失败原因会打印出来。

## 4. debug 日志

```sh
su -c 'touch /data/adb/insmod-loader/logs/debug'
```

只要 `logs/debug` 这个**文件存在**（内容无关），每次开机就会把该阶段的完整 stdout（含 insmod 的 stderr）写入 `logs/<阶段名>.txt`，开头附带 stage / config / result / 时间四行元信息。删除该文件即关闭日志。

> ⚠️ `post-fs-data` 阶段 `logs/` 可能还没准备好写，且该阶段打不开 `/data` 的加密环境；**请在系统启动后用 `adb shell` / 管理器终端创建 `debug`**，或直接在管理器里建好。

## 4b. 覆写模块描述（KernelSU `override.description`）

每次运行结束都会用 `ksud module config set override.description "<文案>"` 把结果写到模块描述上，
在 KernelSU 管理器模块列表里直接可见：

| 情况 | 文案 |
|---|---|
| 全部成功（含"未指定任何模块"） | `✅共 x 个内核模块，成功加载 x 个` |
| 有模块 insmod 失败（返回码非 0） | `❗共 x 个内核模块，成功加载 x 个，加载失败 y 个` |
| 触发拒绝（配置非法等，一个都没加载） | `❎加载被拒绝，请检查` |

实现要点（勿改）：

- **写持久配置，不要写 `--temp`**。KernelSU 的临时配置「在每次启动的 post-fs-data 阶段自动清除」，
  而 `post-fs-data.sh` 正好在那个阶段内运行 —— 写 `--temp` 可能写完就被清掉，状态不显示。
  持久配置重启保留，模块卸载时由 KernelSU 自动清理。
- 模块 ID 用 KernelSU 注入的环境变量 `KSU_MODULE`（官方推荐的用法），不在脚本里硬编码。
- **只在 `KSU_MODULE` 或 `KSU=true` 存在时写**，否则 `ksud` 会用默认身份写配置，可能污染别的模块。
- `ksud` 走绝对路径候选（`/data/adb/ksu/bin/ksud` 等），不走 `PATH`。
- **失败一律静默**：找不到 `ksud`、命令返回非 0，都只记一行日志，绝不能影响加载结果与退出码。
- 离线测试用 `IL_DESC_DRY_RUN=1` 打印将要写入的文案（不调用 ksud），
  `KSU_INSMOD_KSUD` 可指向假 ksud 检查真实调用参数。

> 两个阶段都会写这个键，所以**后运行的那个阶段的结果覆盖先运行的**（默认就是用户该看的 `late_start`）。

## 5. 使用步骤

```sh
# 1. 刷入模块并重启一次（让安装脚本建好目录树）
# 2. 放入内核模块（必须与该设备内核 KMI/版本匹配！）
adb push mydriver.ko /data/adb/insmod-loader/late_start/
# 3. 登记并排序（建议用 late_start 阶段）
adb shell 'su -c "printf \"mydriver.ko:100\n\" >> /data/adb/insmod-loader/late_start/config.txt"'
# 4. 打开日志便于排查
adb shell 'su -c "touch /data/adb/insmod-loader/logs/debug"'
# 5. 重启
adb reboot
# 6. 查看结果
adb shell 'su -c "cat /data/adb/insmod-loader/logs/late_start.txt"'
adb shell 'su -c "lsmod | head"'
```

## 6. 注意事项与风险

- **加载不匹配的 `.ko` 会直接 kernel panic / 开不了机**。务必确认内核版本与模块签名（未开启 `CONFIG_MODULE_SIG_FORCE` 时才能加载自编译模块），并确保有救砖手段。
- **`post-fs-data` 阶段会阻塞开机（上限 10 秒）**：长时间卡在 `insmod` 会拖慢甚至卡死启动。只在该阶段加载「必须早于 Zygote」的模块；其余一律用 `late_start`。
- 该阶段同样禁止 `setprop`（本模块未使用），需要改属性请用 `resetprop -n`。
- 模块输出的日志走的是脚本 stdout；KernelSU 也会把模块脚本输出收进它自己的日志，两者不冲突。
- 覆盖安装/升级本模块时**不会覆盖**已有的 `config.txt`，避免丢掉你的配置；`/data/adb/insmod-loader` 目录也不会被卸载脚本删除（内核模块文件是你自己放的，模块不擅自清理）。
- 内核模块只会被「加载」，不会被卸载；配置里删掉一行只代表下次开机不再加载它，本次开机已加载的模块仍然存在。

## 7. 安全性说明（本轮复查后的加固点）

脚本只做「读配置 → insmod → 写自己目录下的日志」，**没有任何删除用户数据的逻辑**。具体保证：

| 风险 | 处理方式 |
|---|---|
| 误删文件 | 唯一的删除动作在临时目录清理处：只 `rm -f` 自己刚写的 `order` / `stdout` 两个固定名，再 `rmdir` 收尾（`rmdir` 不跟随符号链接、目录非空必然失败）。**代码中没有 `rm -rf`**，源文件里也写了警示注释防止后人改回去 |
| 路径穿越 | 模块名禁止 `/`、`..`、空白；只允许「阶段目录/普通文件名」一种形态，`config.txt` 不会被当成任意路径的模块加载器 |
| 符号链接诱导读写 | `config.txt`、`.ko`、`logs` 目录、`logs/debug` 本身是符号链接时一律拒绝；日志用「先写临时文件再 `mv`」落地，不使用会跟随链接的 `>` 重定向 |
| `cd` 失败导致相对路径落到 `/` | `cd` 必须成功，失败即拒绝执行（旧版曾回退到 `/`，已修） |
| 环境变量/`PATH` 被污染 | `insmod` 只按绝对路径候选列表查找，不走 `PATH`；找不到就拒绝执行而不是猜。**候选允许是符号链接**（见下方说明） |
| 临时目录被抢占替换 | `mktemp -d` 随机名 + `umask 077`；退化路径额外校验「非符号链接、属主是自己」 |
| 非普通文件 | FIFO / 设备节点 / 目录一律拒绝加载（**但不检查属主**，见下方说明） |
| 宽泛路径 | 阶段目录为 `/`、`/data`、`/data/adb`、`/data/adb/insmod-loader` 本身或相对路径时拒绝执行 |
| 安装脚本被诱导写入别处 | `customize.sh` 对 `/data/adb`、目标目录及其子目录、`config.txt` 逐项拒绝符号链接，并把自己建的目录权限收紧到 `0700` |

### config.txt 行处理: 容忍「不影响语义的写法」（踩过的坑，勿改）

解析每行前先做三步宽容处理，**顺序不能变**：

1. 去掉 UTF-8 BOM（必须是 `${IL_LINE#???}` —— BOM 是 3 **字节**，而参数展开的 `?` 按**字符**匹配，
   用 `#?` 只会删掉 1 个字节，剩下 2 个字节粘在文件名前面）
2. 去掉行尾 CR（CRLF）
3. 用 `sed` 删掉**行首行尾**空白；再删掉分隔冒号**两侧**空白

这些写法在真机上都可能出现，必须接受：`a.ko:100 `（尾空格）、`a.ko: 100`、`a.ko : 100`、
`  a.ko:100`、Tab 缩进、Windows 记事本保存带 BOM 的文件。
**曾经只做了 CRLF 处理，上面这些写法会报「优先级非法 / 文件名非法」从而整份配置被拒绝。**

两条边界：

- 文件名**中间**的空白仍然是错误（`my driver.ko`）——只删两侧，不做全局删空白。
- 判断顺序: 「中文全角冒号」提示必须放在「缺少分隔冒号」**之前**，
  否则全角行同样满足"没有半角冒号"，该提示永远不触发。
- 「不是 .ko」的判断放在**存在性检查之前**，这样存在的 `x.zip` 会报
  「不是 .ko 内核模块文件」，而不是误导性的「文件不存在」。

`tests/run-tests.sh` 的「场景组 3b」锁定了上述全部宽容写法。

### 不要检查数据文件的属主（踩过的坑，勿改）

`insmod_loader_safe_file()` / `insmod_loader_safe_dir()` 只判定「不是符号链接 + 是普通文件/目录」，
**不要**往里加 `[ -O "$1" ]`：

- 本脚本以 **root** 运行，而用户放 `.ko`、改 `config.txt` 的常见方式是 `adb push` ——
  那样文件属主是 **shell(2000)**，不是 root。加了属主判定后，**正常文件也会被判为
  「不是普通文件或属主异常」并整体拒绝加载**（这个 bug 真实发生过）。
- 属主检查对安全也没有增益：非 root 用户本来就写不进 `/data/adb`（模块建的目录是 0700），
  而能写进去的人已经是 root，伪造 root 属主的文件轻而易用。
- 真正的边界是「不是符号链接」+「阶段目录 0700」。

属主校验**只保留在临时目录**那一处（`insmod_loader_safe_tmpdir()`），因为那里要保证
「删除的目录确实是本次运行自己建的」，防止删到与本次运行无关的东西。

`tests/security-tests.sh` 里有对应回归检查：会提取这两个函数的函数体做静态断言，
一旦 `-O` 回到数据文件路径上就报 FAIL（已用变异测试验证该检查有效）。

### insmod 查找规则（踩过的坑，勿改）

候选路径按顺序取第一个**可执行的普通文件**：

```
/system/bin/insmod : /system/xbin/insmod : /vendor/bin/insmod : /odm/bin/insmod :
/debug_ramdisk/insmod : /data/adb/ksu/bin/insmod : /data/adb/ksud/bin/insmod
```

可用 `KSU_INSMOD_SEARCH_PATHS`（冒号分隔）覆盖，`KSU_INSMOD_LOADER` 可直接指定绝对路径（两者都只用于离线测试）。

**不要给候选加 `[ ! -h ]`（拒绝符号链接）判断。** Android 上 `/system/bin/insmod` 本身就是
`insmod -> toybox`（或 busybox）的符号链接，AOSP/各家 ROM 都是这么装 toybox applet 的
（例：MIUI 的 init 就有 `symlink("toybox", "/system/bin/...")`）。
加了这条判断的后果是：文件明明存在却报「找不到 insmod 可执行文件」，
且因为循环里没有别的候选能通过，会直接拒绝执行。
`insmod` 只被「执行」，从不被写入/删除，跟随符号链接没有安全风险 —— 真正的安全要求
（不走 `PATH`、必须是可执行文件）已经满足。

候选值会被当作**单个可执行文件路径**调用（`"$IL_LOADER" "$IL_F"`），
所以**不要**往候选里塞 `toybox insmod` 这种「程序 + 子命令」形式：
`"$IL_LOADER"` 带引号不会被词分割，会变成找一个名字里带空格的程序而报 `not found`。
设备上若连 `insmod` applet 都没有，`toybox insmod` 同样无法加载模块，因此不需要这个回退。

找不到时会打印**实际查过的路径列表**（`IL_SEARCH_PATHS`），便于在设备上一眼定位。

> 仍属「有意为之」的行为：`/data/adb/insmod-loader` 下的目录、`config.txt`、`.ko`、日志在**卸载模块后依然保留**（那是你自己放的模块与配置，模块不擅自清理）。

## 8. 仓库结构

代码、文档、测试、产物互相隔离：`module/` 是唯一的模块本体（**zip 根 = 该目录的内容**），
两份 README 与 `tests/` 都不会被写进刷入包（`pack.sh` 会显式校验这一点）。

> `check-module.sh` 会提示「目录名 'module' 与模块 id 'insmod-loader' 不一致」——这是**预期**的：
> 该检查针对的是「模块目录直接以 id 命名」的场景（例如 `insmod-loader/`），
> 而本仓库把模块内容放在 `module/` 下，真正的 id 以 `module/module.prop` 为准。
> 装到设备上之后目录名会是 `/data/adb/modules/insmod-loader/`。

```txt
insmod-loader-module/          # 仓库目录名；安装到设备后是 /data/adb/modules/insmod-loader/
├── pack.sh                 # 打包脚本: 只把 module/ 打成 zip 到 output/
├── README.md               # 面向使用者的简明说明
├── README_AGENTS.md        # 本文档（实现细节 / 安全约定 / 测试清单）
├── module/                 # 模块本体（会进 zip）
│   ├── module.prop         #   id=insmod-loader, name=Insmod Loader
│   ├── customize.sh        #   安装: 建目录 + 写 config.txt，失败即 abort
│   ├── post-fs-data.sh     #   阶段入口: 读 post-fs-data/，日志 post-fs-data.txt
│   ├── service.sh          #   阶段入口: 读 late_start/，日志 late_start.txt
│   └── insmod-loader.sh    #   共用实现: 解析/校验/排序/insmod/写日志/覆写描述
├── tests/                  # 测试（不会进 zip）
│   ├── run-tests.sh        #   功能测试（53 个用例）
│   └── security-tests.sh   #   安全性专项测试（39 个用例: 穿越/符号链接/误删/环境异常/属主回归）
└── output/                 # 打包产物（不会进 zip）
    └── insmod-loader_1.0.0.zip
```

### 打包

```sh
./pack.sh                     # -> output/insmod-loader_<version>.zip
./pack.sh --name my.zip       # 自定义产物文件名
```

`pack.sh` 只做打包一件事：检查 `module/module.prop`（`id` 合法性、`versionCode` 为整数、LF 换行）、
按规则打 zip（**`-0` 只存储不压缩** —— 模块安装后是直接使用的，压缩过的 `.ko` 内核无法加载；
同时排除点文件 / `node_modules` / `*.zip` / 编辑器临时文件，保留可执行位），
再校验「`module.prop` 在 zip 根、没有嵌套 module.prop、没有混入 `tests/`+`README`+`pack.sh`」，失败即非零退出。
它不跑测试、不生成文档、不修改 `module/` 里的任何文件。

### 离线测试

不需要设备；两个套件在 BusyBox ash 与 dash 下均全绿：

```sh
PATH=/path/to/busybox:$PATH bash tests/run-tests.sh
TEST_SH=sh bash tests/security-tests.sh
```
