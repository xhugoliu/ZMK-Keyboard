# P31n BLE Telemetry

ZMK 外部模块，将 P31n 的 31 个物理位置事件发给 [P31n Insight](https://github.com/xhugoliu/p31n-insight) 或独立 Telemetry Probe。只在当前已配对主机订阅并发送 START 时采集；默认不记录，不写按键到闪存。

`p31n/p31n.conf` 启用 `CONFIG_P31N_TELEMETRY=y`，本仓库本地脚本和 GitHub Actions 使用 `ZMK_EXTRA_MODULES` 包含本模块。其他 shield 默认关闭遥测。

## 本地构建

```sh
./scripts/build_p31n.sh --public --copy-to-shield
```

脚本复用已验证的 SDK 0.16.9、本机 Python 环境和 `.omx/ci-workspace`。SDK 可通过 `--sdk` 指定；可用 `--repo`、`--workspace`、`--venv` 适配其他路径。构建本身不刷机。公开 UF2 使用已有占位宏，不包含 Git 忽略的本地宏，并使用独立构建目录与 `-public.uf2` 输出。平时不加 `--public` 的本机构建仍会使用个人宏。仓库内的 UF2 应从公开构建产物更新。

明确需要刷机时，可在 bootloader 已挂载后执行：

```sh
./scripts/build_p31n.sh --flash-only
```

当前 P31n keymap 的进入方式：按住底排中央 `&mo 8` 键，再按顶排 O 位置的 `&bootloader`。Mac 通常挂载 `/Volumes/NICENANO`。按键配置修改后应以实际 keymap 为准。

## 行为与协议

监听器链接到 `app`，在 combo/hold-tap 前采集并冒泡原事件。以位置、状态和原始时间戳剔除 combo 重派发；非阻塞队列和独立发送线程避免在按键回调中等待蓝牙发送。队列溢出和发送错误计入状态特征的 dropped。

事件服务 UUID `A0310000-5B5A-4B4D-9A6E-5033314E0001`，事件特征 `A0310001`，控制特征 `A0310002`。20 字节事件包含版本、位置、状态、序号、设备时间、启动标识和采集会话。字段及验收说明在 [p31n-insight 的协议文档](https://github.com/xhugoliu/p31n-insight/blob/main/docs/protocol.md)。

## 去重回归测试

```sh
cc -std=c11 -Wall -Wextra -Werror -I modules/p31n-telemetry \
  modules/p31n-telemetry/tests/replay_filter_test.c -o /tmp/p31n-replay-test
/tmp/p31n-replay-test
```

真机验证覆盖 A 20 次、B＋N 20 次并击、Q 短按/长按、断电重连。续航、长期采集及 Mac 睡眠恢复仍需测量。Studio 仅用于改键或初步链路验证，正式遥测不依赖 Studio。
