# smol firmware workspace

这个仓库用于固定并初始化 SlimeVR nRF 固件工作区。应用源码通过 Git
子模块管理，Nordic/Zephyr SDK 依赖继续由各应用自己的 west 清单管理。

## 目录结构

```text
smol/
├── .venv-west/                              # 本地生成，west CLI
├── .venv-bootloader/                        # 本地生成，bootloader Python 工具
├── boot/
│   └── Adafruit_nRF52_Bootloader/          # Git 子模块
├── recv/
│   └── SlimeVR-Tracker-nRF-Receiver/       # Git 子模块 + west manifest
├── tracker/
│   └── SlimeVR-Tracker-nRF/                # Git 子模块 + west manifest
└── scripts/
    ├── bootstrap.sh
    ├── build-sk-cheesecake-nrf-p00.sh
    ├── clean-sk-cheesecake-nrf-p00.sh
    └── update-sources.sh
```

`recv` 和 `tracker` 是彼此独立的 west 工作区。`west update` 生成的
`nrf`、`zephyr`、`modules` 等目录是本地依赖，不会提交到本仓库。

## 首次初始化

需要预先安装：

- Git
- Python 3（包含 `venv` 模块）
- 足够的磁盘空间；两个完整 west 工作区当前合计约 11 GB

执行：

```bash
git clone https://github.com/SKPastry/smol.git
cd smol
./scripts/bootstrap.sh
```

初始化脚本直接使用虚拟环境中的绝对路径，不要求手动激活 `.venv-west`。

不需要给 `git clone` 增加 `--recurse-submodules`。初始化脚本会：

1. 拉取三个顶层源码子模块；
2. 只初始化 bootloader 的直接依赖，避免递归拉取 TinyUSB 中无关的平台仓库；
3. 递归初始化 tracker 的 `vqf-c` 依赖；
4. 创建 `.venv-west` 并安装固定版本的 `west`；
5. 创建 `.venv-bootloader` 并安装固定版本的 `intelhex`；
6. 分别执行 receiver 和 tracker 的 `west init`、`west update`。

如果只想建立 Git 子模块、Python 环境和 west 元数据，暂时不执行
`west update` 下载 SDK：

```bash
./scripts/bootstrap.sh --init-only
```

`--init-only` 仍会下载缺失的 Git 子模块和 Python 包。之后再次执行不带参数
的脚本即可下载或更新 SDK。脚本可重复执行。

## Python 环境

两个 Python 环境放在顶层仓库，不会进入子模块或修改其中受版本控制的文件。
初始化脚本执行的 `git submodule sync/update` 可能更新本地 Git 配置，但不会
修改子模块源码：

- `.venv-west`：只保证提供固定版本的 west CLI 及其直接依赖。
- `.venv-bootloader`：提供 bootloader 构建后处理所需的 `intelhex`。

需要手动调用 west 时，可以激活环境：

```bash
source .venv-west/bin/activate
```

也可以始终使用完整路径，不激活环境：

```bash
cd recv/SlimeVR-Tracker-nRF-Receiver
../../.venv-west/bin/west topdir
```

该命令应输出顶层仓库中的 `recv` 路径。实际开发时，可以用相同的完整路径
替代原命令中的 `west`，其余 `west build` 参数保持原项目用法不变。

tracker 的检查方式相同：

```bash
cd tracker/SlimeVR-Tracker-nRF
../../.venv-west/bin/west topdir
```

执行实际 `west build` 前，仍需保证对应版本的 nRF Connect SDK Toolchain 和
项目所需 Python 依赖已经准备完成。`.venv-west` 本身不提供编译器、NCS
Toolchain，也不会自动安装全部 NCS Python 依赖。

旧的 `.venv` 不再由脚本使用，但仍保留在 `.gitignore` 中，方便已有工作区平滑
迁移。初始化脚本不会自动删除它。

## sk_cheesecake_nrf_p00 一键构建

工作区、west SDK、`.venv-bootloader` 和编译器工具链初始化完成后，从顶层目录
执行：

```bash
./scripts/build-sk-cheesecake-nrf-p00.sh
```

脚本依次构建以下两个目标：

- tracker app：`sk_cheesecake_nrf_p00/nrf52840/uf2`
- bootloader：`sk_cheesecake_nrf_p00`，`MinSizeRel`

脚本不会调用 `bootstrap.sh`、`west update`、安装依赖或烧录设备。默认使用
`--pristine=auto`，因此第一次运行会配置构建目录，后续运行可增量构建。修改
板级配置、切换 SDK 或怀疑 CMake 缓存失效时，可强制重新配置 app：

```bash
./scripts/build-sk-cheesecake-nrf-p00.sh --pristine
```

如果当前终端已经激活兼容的 NCS/Zephyr Toolchain 环境，脚本会直接使用其中的
`west` 和 Zephyr SDK。在普通终端运行时，脚本会从
`~/ncs/toolchains/toolchains.json` 中自动选择已安装的 v3.2.x 工具链。非默认
安装位置可以显式指定：

```bash
NCS_TOOLCHAIN_ROOT=/path/to/ncs/toolchain \
  ./scripts/build-sk-cheesecake-nrf-p00.sh
```

自动选择只负责加载已安装的工具链，不会下载或修改工具链。单独激活
`.venv-west` 仍不等同于完整构建环境；脚本发现缺少 Zephyr SDK 时会继续尝试
已安装的 NCS Toolchain。app 的 ccache 默认放在
`build/sk_cheesecake_nrf_p00/.ccache`，不会依赖用户目录可写。

中间构建文件位于 `build/sk_cheesecake_nrf_p00/`。成功后可烧录或发布的文件
统一复制到 `artifacts/sk_cheesecake_nrf_p00/`：

```text
app.uf2
app.hex
app-merged.hex
bootloader_mbr.uf2
bootloader_mbr.hex
SHA256SUMS
```

`app-merged.hex` 是 west sysbuild 生成的合并 HEX；日常 UF2 更新通常使用
`app.uf2`。bootloader 产物包含 MBR，优先使用 `bootloader_mbr.uf2` 或
`bootloader_mbr.hex`。脚本不会复制具有异常大逻辑尺寸的 `bootloader.bin`。

## 清理 sk_cheesecake_nrf_p00 构建文件

先预览将被删除的目录：

```bash
./scripts/clean-sk-cheesecake-nrf-p00.sh --dry-run
```

确认后清理：

```bash
./scripts/clean-sk-cheesecake-nrf-p00.sh
```

脚本直接删除以下内容：

- 整个顶层 `build/`，包括所有板型的中间文件和 ccache；
- 整个顶层 `artifacts/`，包括其中已有的 factory-test 和发布文件；
- 旧流程产生的
  `boot/Adafruit_nRF52_Bootloader/cmake-build-sk_cheesecake_nrf_p00/` 和
  `tracker/SlimeVR-Tracker-nRF/build_sk_ck_p00/`。

清理不可撤销。脚本不会删除源码子模块、west SDK、`.west` 元数据或 Python
虚拟环境。不要在构建仍在运行时执行清理。

## Bootloader 构建

同时构建 app 和 bootloader 时，推荐使用上一节的一键脚本。只需要手动构建
bootloader 时，不需要激活 west 环境；从顶层配置独立构建目录，并显式使用
`.venv-bootloader`：

```bash
cmake \
  -S boot/Adafruit_nRF52_Bootloader \
  -B build/bootloader/sk_cheesecake_nrf_p00 \
  -G Ninja \
  -DBOARD=sk_cheesecake_nrf_p00 \
  -DPython_EXECUTABLE="$PWD/.venv-bootloader/bin/python" \
  -DCMAKE_BUILD_TYPE=MinSizeRel

cmake --build build/bootloader/sk_cheesecake_nrf_p00 --parallel
```

现有构建目录如果已经缓存 `.venv-bootloader/bin/python`，仍可直接增量构建。
CMake 构建目录包含绝对路径，不应提交或复制到其他 clone。

发布或烧录应优先使用 `bootloader_mbr.hex` 或 `bootloader_mbr.uf2`。
`bootloader.bin` 可能因为 ELF 中的高地址 UICR 段具有很大的逻辑文件尺寸，
即使它在支持稀疏文件的文件系统上只占用少量实际空间。

## 日常同步

完整初始化三个源码仓库、bootloader 直接依赖、tracker 的 `vqf-c` 和 west
元数据：

```bash
./scripts/bootstrap.sh --init-only
```

如果只需要恢复顶层仓库记录的三个直接子模块，可以使用
`git submodule update --init`；它不会初始化 bootloader 和 tracker 的内部
子模块。

如果需要升级到 `.gitmodules` 中配置分支的最新版本，请使用下一节的
`update-sources.sh`，不要在有未提交开发内容时直接执行
`git submodule update --remote`。

## 更新源码分支

`.gitmodules` 为三个顶层源码仓库配置了跟踪分支：

- bootloader：`devc`
- receiver：`dev`
- tracker：`dev-p0`

从这些远端分支安全更新顶层子模块：

```bash
./scripts/update-sources.sh
```

脚本会执行以下保护：

1. 要求父仓库在三个子模块路径之外没有其他修改；
2. 要求三个子模块没有未提交或未跟踪文件；
3. 如果子模块正处于其他功能分支，则停止而不切换分支；
4. 如果跟踪分支包含未推送提交或已经和远端分叉，则停止；
5. 只允许 fast-forward，不执行 rebase、reset 或强制检出；
6. 更新顶层源码后，将内部子模块恢复到新源码记录的固定提交；
7. 只显示父仓库的 gitlink 变化，不自动提交或推送。

更新中断后可以再次运行脚本。已经 fast-forward 的子模块会保持在远端分支
提交，脚本继续检查其他仓库；它不会通过删除目录或 reset 来修复冲突。

更新后先检查和测试：

```bash
git diff --submodule
git status
```

确认三个固件仍能正常构建后，再提交父仓库记录的新引用：

```bash
git add \
  boot/Adafruit_nRF52_Bootloader \
  recv/SlimeVR-Tracker-nRF-Receiver \
  tracker/SlimeVR-Tracker-nRF
git commit -m "Update firmware sources"
git push origin main
```

父仓库固定的是具体 commit，而不是每次 clone 时自动取得分支最新版本。因此，
只有在明确准备升级并完成测试时才应运行更新脚本。

## 在子模块中开发

可以直接把任意子模块作为独立项目文件夹打开。它们仍是完整 Git 仓库，编辑、
构建、创建分支、提交和推送都按各自项目的原有流程进行；顶层虚拟环境和 west
工作区不会改变其中受版本控制的文件。

推荐流程：

```bash
cd tracker/SlimeVR-Tracker-nRF
git switch -c feature/my-change

# 编辑、构建和测试
git add -p
git commit -m "Describe tracker change"
git push -u origin feature/my-change
```

功能分支合并到 `.gitmodules` 配置的跟踪分支后，回到父仓库运行：

```bash
cd ../..
./scripts/update-sources.sh
```

如果直接在跟踪分支开发，也必须先在子模块中提交并推送，再在父仓库中提交
更新后的子模块引用。不要让父仓库引用一个尚未推送的子模块 commit，否则其他
用户无法通过 `git submodule update` 取得它。

需要注意：

- 父仓库只记录子模块 commit，不会把子模块文件内容纳入父仓库提交。
- 子模块存在未提交修改时，父仓库的 `git status` 会显示对应路径已修改。
- `git submodule update` 和 `bootstrap.sh` 可能把干净的子模块切换到父仓库
  固定的 commit，并进入 detached HEAD；分支和提交不会被删除，但继续开发前
  应先用 `git switch` 返回准备开发的分支。
- `update-sources.sh` 遇到活动中的其他分支、本地提交或未提交修改会停止，
  不会覆盖开发现场。

## 工具链说明

`bootstrap.sh` 完成的是工作区初始化，不等同于完整构建环境部署。它负责源码
子模块、两个 Python 环境和 west SDK 仓库，不安装系统级编译器或烧录工具。

- bootloader 构建需要 ARM GNU Toolchain（`arm-none-eabi-gcc`）、CMake 和 Ninja。
- receiver/tracker 构建还需要与其 NCS 版本匹配的 nRF Connect SDK Toolchain
  和项目要求的 Python 包。
- 激活 `.venv-west` 只会提供 west CLI，不能替代 NCS Toolchain 环境。
- 实际烧录脚本应明确指定板型和设备，避免初始化工作区时意外写入硬件。

两个应用当前在 `west.yml` 中使用可移动的 `v3.2-branch`。顶层 Git
仓库会固定应用源码提交，但如果需要完全可复现的 SDK，仍应在应用仓库中把
该 revision 改为经过验证的 commit SHA。
