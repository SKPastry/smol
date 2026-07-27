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
    └── bootstrap.sh
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

## Bootloader 构建

bootloader 不需要激活 west 环境。推荐从顶层配置独立构建目录，并显式使用
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

有意升级到 `.gitmodules` 中配置分支的最新版本：

```bash
git submodule update --remote \
  boot/Adafruit_nRF52_Bootloader \
  recv/SlimeVR-Tracker-nRF-Receiver \
  tracker/SlimeVR-Tracker-nRF
git diff --submodule
```

升级顶层源码引用后，应再次执行 `./scripts/bootstrap.sh --init-only`，使内部
子模块与新的源码提交一致。确认变更后，需要在本仓库提交更新后的顶层子模块
引用。

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
