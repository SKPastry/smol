# smol firmware workspace

这个仓库用于固定并初始化 SlimeVR nRF 固件工作区。应用源码通过 Git
子模块管理，Nordic/Zephyr SDK 依赖继续由各应用自己的 west 清单管理。

## 目录结构

```text
smol/
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
source .venv/bin/activate
```

不需要给 `git clone` 增加 `--recurse-submodules`。初始化脚本会：

1. 拉取三个顶层源码子模块；
2. 只初始化 bootloader 的直接依赖，避免递归拉取 TinyUSB 中无关的平台仓库；
3. 递归初始化 tracker 的 `vqf-c` 依赖；
4. 创建 `.venv` 并安装固定版本的 `west` 和 `intelhex`；
5. 分别执行 receiver 和 tracker 的 `west init`、`west update`。

如果只想建立 Git 子模块和 west 元数据，暂时不下载 SDK：

```bash
./scripts/bootstrap.sh --init-only
```

之后再次执行不带参数的脚本即可下载或更新 SDK。脚本可重复执行。

## 日常同步

恢复顶层仓库所固定的源码版本：

```bash
git submodule update --init
```

有意升级到 `.gitmodules` 中配置分支的最新版本：

```bash
git submodule update --remote \
  boot/Adafruit_nRF52_Bootloader \
  recv/SlimeVR-Tracker-nRF-Receiver \
  tracker/SlimeVR-Tracker-nRF
git diff --submodule
```

确认变更后，需要在本仓库提交更新后的子模块引用。

## 工具链说明

`bootstrap.sh` 负责源码与 Python 工具的初始化，不安装系统级编译器或烧录工具。

- bootloader 构建需要 ARM GNU Toolchain（`arm-none-eabi-gcc`）、CMake 和 Ninja。
- receiver/tracker 构建还需要与其 NCS 版本匹配的 nRF Connect SDK Toolchain。
- 实际烧录脚本应明确指定板型和设备，避免初始化工作区时意外写入硬件。

两个应用当前在 `west.yml` 中使用可移动的 `v3.2-branch`。顶层 Git
仓库会固定应用源码提交，但如果需要完全可复现的 SDK，仍应在应用仓库中把
该 revision 改为经过验证的 commit SHA。
