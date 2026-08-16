# NR n78 下一步研究：从 activeBands 到 serving cell 遥测

**日期**: 2026-08-16
**目标**: iPhone14,3 / iOS 15.1.1 (19B81)
**前提**: `activeBands` 是 allowed-band 配置，不是 serving band；设备可回落 LTE B3

---

## 核心结论

iOS 15 的 **Cell Monitor** 私有 API 提供了一个**纯只读、无需写入 modem** 的途径，可以回答当前返回的小区条目，但不能保证一次快照包含所有已配置载波：
- 当前 serving cell 的 RAT（LTE / NR NSA / NR SA）
- LTE PCC（主载波）的频点、PCI、band
- NR 辅载波（NSA）或 serving band（SA）的频点、PCI、band
- 信号强度、小区 ID、TA 等

这意味着之前的 n78 写实验完全可以先以只读观测来验证，不需要从 `activeBands` 推断 serving 状态。

---

## 1. 核心 API：Cell Monitor

### 1.1 调用路径

**底层 C API**（从 .tbd 导出，iOS 15+ 可用）：
```
_CTServerConnectionCellMonitorStart(connection, context, 0)
_CTServerConnectionCellMonitorCopyCellInfo(connection, context) → NSArray
_CTServerConnectionCellMonitorStop(connection, context)
```

**高层 ObjC API**（iOS 15.5 头文件）：
```objc
// CoreTelephonyClient.h:107
- (void)copyCellInfo:(CTXPCServiceSubscriptionContext *)context completion:(void(^)(CTCellInfo *, NSError *))completion;

// CoreTelephonyClient.h:409
- (void)refreshCellMonitor:(CTXPCServiceSubscriptionContext *)context completion:(void(^)(NSError *))completion;
```

**委托回调**（实时更新）：
```objc
// CoreTelephonyClientRegistrationDelegateInternal-Protocol.h
- (void)cellMonitorUpdate:(CTXPCServiceSubscriptionContext *)context info:(CTCellInfo *)info;
- (void)cellChanged:(CTXPCServiceSubscriptionContext *)context cell:(NSDictionary *)cell;
```

### 1.2 CTCellInfo 结构

```objc
@interface CTCellInfo : NSObject <NSCopying, NSSecureCoding>
@property(retain, nonatomic) NSArray *legacyInfo;  // NSArray of NSDictionary
@end
```

`legacyInfo` 数组包含每个小区（serving + neighbor）的字典，键如下（来自 .tbd 符号）：

| 键 | 类型 | 含义 |
|---|---|---|
| `kCTCellMonitorCellType` | NSString | `Serving` / `Detected` / `Neighbor` / `Monitor` |
| `kCTCellMonitorCellRadioAccessTechnology` | NSString | `LTE` / `NR` / `UMTS` / `GSM` |
| `kCTCellMonitorIsSA` | NSNumber(bool) | `true` = NR SA, `false` = NR NSA |
| `kCTCellMonitorNRARFCN` | NSNumber | NR 绝对频点号 |
| `kCTCellMonitorChannelNumber` | NSNumber | 部分系统版本中的通用频点号 |
| `kCTCellMonitorBandInfo` | NSNumber | 频段号（如 3, 78） |
| `kCTCellMonitorBandwidth` | NSNumber | 带宽 (MHz) |
| `kCTCellMonitorPCI` | NSNumber | 部分系统版本中的物理小区 ID |
| `kCTCellMonitorPID` | NSNumber | 目标 iPhone14,3 / iOS 15.1.1 样本中的值与 LTE PCI 一致 |
| `kCTCellMonitorGSCN` | NSNumber | 全局同步信道号 |
| `kCTCellMonitorSCS` | NSNumber | 子载波间隔 |
| `kCTCellMonitorCellId` | NSNumber | 小区标识 |
| `kCTCellMonitorTAC` | NSNumber | 跟踪区码 |
| `kCTCellMonitorMCC` | NSString | 移动国家码 |
| `kCTCellMonitorMNC` | NSString | 移动网络码 |
| `kCTCellMonitorRSRP` | NSNumber | 参考信号接收功率 |
| `kCTCellMonitorRSRQ` | NSNumber | 参考信号接收质量 |
| `kCTCellMonitorSNR` | NSNumber | 信噪比 |
| `kCTCellMonitorRSSI` | NSNumber | 接收信号强度指示 |
| `kCTCellMonitorBaseStationId` | NSNumber | 基站 ID |
| `kCTCellMonitorSectorId` | NSString | 扇区 ID |
| `kCTCellMonitorTimingAdvance` | NSNumber | 时间提前量 |
| `kCTCellMonitorDeploymentType` | NSNumber/NSString | 部署类型；目标设备样本返回 NSNumber |
| `kCTCellMonitorLAC` | NSNumber | 位置区码 |
| `kCTCellMonitorPSC` | NSNumber | 主扰码 (UMTS) |
| `kCTCellMonitorUARFCN` | NSNumber | UMTS 频点；目标设备 LTE B3 样本中的值落在 B3 EARFCN 范围 |
| `kCTCellMonitorARFCN` | NSNumber | GSM 频点 |

### 1.3 NSA 场景下的行为

目标设备 iOS 15.1.1 的首轮实机结果修正了原先的假设：`currentRat` 可以是
`CTRadioAccessTechnologyNRNSA`，而同一时刻的 Cell Monitor 快照只返回 LTE serving
cell。该 LTE 条目使用 `kCTCellMonitorPID` 表示 PCI，使用
`kCTCellMonitorUARFCN` 表示 EARFCN。

这不证明 NR n78 当时正在承载流量，也不证明 Cell Monitor 永远不会返回 NR 条目。
NSA 的 NR secondary cell 可能在空闲时被释放；只有实际返回的 NR serving 条目及其
`NRARFCN`/band 才是当前 NR 载波证据。`cellmonprobe2` 因此会在首次刷新后以 1 秒间隔
采集 10 份快照。实机应先启动持续蜂窝数据流量，再触发采样，检验目标网络是否会暴露
LTE PCC 与 NR secondary cell。该版本尚待目标机复跑；复跑必须同时确认三个新符号已
解析，以及规范化字段和来源标签实际出现在输出中。

当设备处于 NR SA 且快照返回 NR serving cell 时，预期 `isSA=true`；只有 LTE 时则只
返回 LTE 小区。因此，一次 `copyCellInfo:` 只能回答该快照实际包含的条目，不能从 RAT
状态或 allowed-band 列表补推一个缺失的 NR serving cell。

---

## 2. 其他相关 API 能力矩阵

| API | 读/写 | 能回答什么 | 限制 |
|---|---|---|---|
| **Cell Monitor** | 只读 | 快照中小区的 RAT、频点、band、PCI、信号强度 | NSA 空闲快照可能只含 LTE PCC；`CTCellInfo.legacyInfo` 是字典数组 |
| `getBandInfo:error:` | 只读 | active/supported bands 字典（同 `activeBands`） | 已证明是 allowed-set，不是 serving |
| `getCurrentRat:error:` | 只读 | 当前 RAT 字符串（NR/LTE/etc） | 不区分 NSA/SA，不含频点 |
| `copyRadioAccessTechnology:error:` | 只读 | RAT 字符串 | 同上 |
| `getRatSelection:error:` | 只读 | `CTRatSelection`（selection/preferred/mask） | 只反映用户选择，不反映实际驻留 |
| `getNRDisableStatus:error:` | 只读 | `CTNRStatus`（isSADisabled/isNSADisabled） | 不反映当前是否实际驻留 NR |
| `getSupports5GStandalone:error:` | 只读 | 设备是否支持 SA | 静态能力 |
| `getPublicNrFrequencyRange:error:` | 只读 | FR1/FR2/Sub6/MmWave | 粗略频段范围 |
| `getSignalStrengthInfo:error:` | 只读 | `CTSignalStrengthInfo`（bars, raw, graded） | 只有信号强度，无频点 |
| `getSignalStrengthMeasurements:error:` | 只读 | `CTSignalStrengthMeasurements` | 同上 |
| `copyRegistrationStatus:error:` | 只读 | 注册状态字符串 | 不含频点信息 |
| `setActiveBandInfo:bands:error:` | 写 | 改变 allowed bands | 已证明不强制驻留 |
| `_CTServerConnectionSetRATSelection` | 写 | 切换 RAT 模式 | 不传频段，不保证驻留 |
| `setRatSelection:selection:preferred:completion:` | 写 | 切换 RAT 模式 | 同上 |
| `setRatSelectionMask:selection:preferred:completion:` | 写 | 切换 RAT 选择掩码 | 同上 |

---

## 3. RAT 模式控制语义

### 当前已知的 RAT 选择值

```
kCTRegistrationRATSelection0  → GSM
kCTRegistrationRATSelection1  → UMTS
kCTRegistrationRATSelection3  → CDMA
kCTRegistrationRATSelection4  → EVDO
kCTRegistrationRATSelection6  → LTE
kCTRegistrationRATSelection7  → Automatic
kCTRegistrationRATSelection9  → NR StandAlone
kCTRegistrationRATSelection10 → NR NonStandAlone
kCTRegistrationRATSelection11 → NR
```

### 关键限制

- `_CTServerConnectionSetRATSelection(connection, value, 0)` 第三个参数是 `0`，不传 band、mask、SIM 标识或持久化标志
- 新 ObjC API `setRatSelection:selection:preferred:completion:` 接受 `selection` 和 `preferred` 两个字符串
- `setRatSelectionMask:selection:preferred:completion:` 接受 `unsigned char mask`

**即使选择 NR NSA + n78 allowed-set，也无法保证设备持续驻留 n78**。RAT 选择只指定无线接入技术，不指定具体频段。modem 的频段选择由基带算法、信号质量、负载均衡等因素决定。

---

## 4. 只读设备探针设计

### 探针 A：Serving Cell 遥测（优先级最高）

使用 `CoreTelephonyClient` 的 Cell Monitor 路径，**纯只读，不写 modem**：

```
1. 获取 CTXPCServiceSubscriptionContext（slot 1）
2. 调用 refreshCellMonitor:completion: 触发刷新
3. 首次等待 0.5 秒，然后以 1 秒间隔调用 10 次 copyCellInfo:completion:
4. 每次独立保留 CTCellInfo、legacyInfo、解析结果、时间戳和失败状态
5. 遍历每份 legacyInfo 数组，按 cellType 过滤
6. 对 cellType=Serving 的条目输出：
   - cellRadioAccessTechnology → NR/LTE/UMTS
   - isSA (NR only) → true/false
   - bandInfo → 频段号
   - `nrarfcn` / `channelNumber` / `uarfcn`，并记录规范化 `frequency` 的来源
   - `pci` / `pid`，并记录规范化 `physicalCellId` 的来源
   - cellId / TAC / MCC / MNC
7. 汇总所有 serving 条目；只有样本中明确的 NR serving 条目才能将 nrServingCellObserved 置为 true
8. 输出所有频段条目（serving + neighbor）的原始字典
```

**成功标准**：
- 对实际返回的条目区分 LTE PCC、NR NSA 辅载波、NR SA serving band
- 输出各频段各自的实际频点号
- NR 条目缺失时保持“未观测到”，不从 `currentRat`、`activeBands` 或 `supportedBands` 推断 n78
- 不写 modem，不改变设备状态

### 探针 B：RAT 状态快照（辅助）

```
1. getCurrentRat:error: → 当前 RAT 字符串
2. getNRDisableStatus:error: → SA/NSA 禁用状态
3. getRatSelection:error: → CTRatSelection
4. copyRegistrationStatus:error: → 注册状态
5. getPublicNrFrequencyRange: → FR1/FR2
```

### 探针 C：信号强度快照（辅助）

```
1. getSignalStrengthInfo:error: → bars, raw, graded
2. getSignalStrengthMeasurements:error: → 测量数据
```

---

## 5. 首轮生命周期插桩设计

首轮 n78 写入后没有进入 60 秒观察，也没有自动恢复。**纯粹通过无 modem 写入的日志**定位原因：

### 插桩点

1. **入口日志**：记录调用栈、操作名、时间戳
2. **Guard 检查**：isSimPresent、isSimGood、slot、uuid 验证结果
3. **Snapshot/Intent/Marker 检查**：是否存在、是否匹配当前操作
4. **Timer 注册**：`performSelector:withObject:afterDelay:` 或 `dispatch_after` 的注册时间
5. **Process exit**：`UIApplicationDidEnterBackgroundNotification`、`UIApplicationWillTerminateNotification`
6. **Prefs 关闭**：`viewWillDisappear:` 或 `dealloc`
7. **异常路径**：任何 catch/error 分支

### 实现方式

- 使用 `NSLog` 或 `os_log` 输出到系统日志
- 或者在 `CCNMRootListController` 中通过临时 `CCNMNr78ProbeLog` 函数写入 plist
- 不写额外的 plist 到 `me.nixuge.networkmanager.bandwrite.*` 命名空间，避免干扰 marker 逻辑

---

## 6. `cellmonprobe2` 目标机结果（2026-08-17）

附件 SHA256：`23a8488b021a3e9121e76a5d3c4ba02d68f902397bc90fbab257b23630d64c9d`。

- 采样状态为 `complete`：requested/completed/successful 均为 10，窗口 9.567 秒，首次延迟 0.505 秒，之后九个间隔为 1.003 至 1.008 秒。
- 20 个 Cell Monitor symbol 全部解析，`cellMonitorMissingSymbols` 为空。目标机新解析器和规范化输出已经实机验证。
- 十次均返回一个 LTE serving entry：Band 3、UARFCN 1600、PID 191、Cell ID 67275832、TAC 11399、数值型 `DeploymentType=2`。
- 规范化结果正确：`physicalCellId=191` / source=`kCTCellMonitorPID`；`frequency=1600` / source=`kCTCellMonitorUARFCN`。PID 从旧样本的 95 变成 191 是 serving cell 变化，不是解析回归。
- `currentRat=CTRadioAccessTechnologyNRNSA`，但 `radioAccessTechnology` 与十份 serving entry 都是 LTE；`nrServingCellObserved=false`。active/supported band 列表虽然包含 78，仍不构成 n78 serving 证据。
- 十次 `copyCellInfo:` 返回十个不同的 `CTCellInfo` 对象地址，但去掉对象地址后的原始字典和全部规范化字段完全一致。旧样本与本次样本相隔 6233 秒且 Cell ID/PID 已变化，说明数据并非跨运行永久冻结；本轮 10 秒内仍无法区分“无线状态稳定”和“同一缓存被重复复制”。
- `publicNrFrequencyRangeRaw=0`，按当前已验证映射只能记为 unknown；`nrStatus` 表明 SA/NSA 未被禁用，但这也不是当前 NR 承载证据。

## 7. 排序后的下一步建议

### 立即做（不写 modem）

1. **探针 A：Serving Cell 遥测** —— 解析器已实机通过；下一轮对比“单次 refresh + 十次 copy”和“每次采样先 refresh 再 copy”，并在明确持续蜂窝流量下检查 payload freshness 与 NR secondary cell
2. **探针 C：生命周期插桩** —— 写入首轮观察期日志，定位为什么没走到 60 秒
3. **探针 B：RAT 状态快照** —— 辅助确认当前 RAT 模式

### 需要讨论再做

4. **RAT 模式选择 + BandInfo 组合实验** —— 先确认 Cell Monitor 可区分 NSA/SA 后，再考虑是否组合 RAT 切换 + allowed-band 写入
5. **n78 强制驻留的可行性** —— 需要通讯基带调试级别权限，不是当前 Tweak 能保证的

### No-go 路径

- **不再单独用 `activeBands` 推断 serving band** —— 已证明不可靠
- **不再写 `_CTServerConnectionSetRATSelection` 来测试频段** —— RAT 选择和频段选择是不同维度
- **不通过 `_CTServerConnectionSetActiveBands`（armv7 only）** —— iOS 15 arm64e 没有此符号

---

## 8. 证据缺口

| 缺口 | 严重程度 | 如何填补 |
|---|---|---|
| 目标机 `PID`/`UARFCN`/数值型 `DeploymentType` 解析 | 已填补 | `cellmonprobe2` 实机确认 20 个 symbol 全解析，规范化 source 与数值类型正确 |
| NSA 活跃流量下是否返回 NR secondary cell | 高 | 本轮只观测到 LTE；在明确持续蜂窝传输下复跑，并保留逐次原始字典 |
| 一次 refresh 后连续 copy 是否返回更新快照 | 高 | 本轮十个对象地址不同但 payload 相同；用“每次采样先 refresh”做只读 A/B，区分稳定状态与缓存 |
| `kCTCellMonitorIsSA` 在 NSA NR 条目中的实际值 | 中 | 捕获到 NR 条目后核对原始字典 |
| `refreshCellMonitor` 是否需要 `start` 先调用 | 中 | 在已有 `_CTServerConnection` 的上下文测试 |
| NSA 活跃时 LTE 与 NR 是否同时标为 `Serving` | 中 | 不预设 schema，以实机连续样本为准 |

---

## 9. 引用

- iOS 15.5 头文件：https://github.com/lechium/iPhone_OS_15.5
- 本地 CTBandInfo.h：`/root/.openclaw/workspace/repos/NetworkManagerReborn-Roothide/docs/research-evidence/ios15-lcsource-9091/CTBandInfo.h`
- 本地 CoreTelephonyClient.h：同上
- 本地 .tbd：`/root/.openclaw/workspace/toolchains/theos/sdks/iPhoneOS16.5.sdk/System/Library/Frameworks/CoreTelephony.framework/CoreTelephony.tbd`
- 现有研究：`/root/.openclaw/workspace/repos/NetworkManagerReborn-Roothide/docs/band-lock-research.md`