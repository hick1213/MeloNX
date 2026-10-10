# 手动 iCloud 游戏存档同步设计

日期：2026-10-10。状态：用户已认可调整后的会话方案；此文档待书面审阅。

## 目标与范围

用户希望在 MeloNX 的多台 iOS 设备之间保存和恢复游戏进度。操作是手动的：选择游戏，再点击“上传存档”或“下载存档”。应用自动定位当前模拟器用户的存档，管理 iCloud 目录，用户无需选择本地文件、iCloud 文件或文件夹。操作显示游戏名、当前用户、版本时间、进度及结果。

本期包括该游戏当前用户的 Account 存档，以及游戏共享的 Device 存档和对应 index。采用用户自己的 iCloud Drive / CloudDocuments；不引入 CloudKit 数据库、服务器、自动同步、付费服务或存档文件格式转换。不传输游戏、固件、keys、配对材料或整个 NAND。已有 NSZ 功能继续按已批准计划实施；两项功能通过统一的本地操作互斥边界交互。

假设：应用使用同一开发团队、bundle ID 和 iCloud container；目标设备登录可用的同一 iCloud 账户。跨账户迁移不属于本期。iCloud 本身在网络恢复后传输用户手动排队的上传，这不算新增自动触发游戏存档上传。

## 已核实的代码与环境约束

- Swift 当前没有存档导出/导入及 ubiquity 容器服务，需要新增 Swift UI/服务和 C# 原生存档桥。
- 现有物理路径为 `Documents/bis/user/save/<SaveDataId:16hex>/0`（提交数据）；`1` 是工作数据。`SaveDataId` 不是游戏 TitleID，不能跨设备复制目录名及 NAND 索引。桌面代码 `ApplicationHelper.TryFindSaveData` 和 `SaveModel` 使用 LibHac `SaveDataFilter/SaveDataInfo` 将 ProgramId、UserId、类型和 index 映射到本地 SaveDataId。
- 默认模拟器用户 UID 固定；自定义用户可能使用不同 UID。UI 自动捕获当前用户，不要求每次再选用户；不把手机设备 ID 当作模拟器用户 UID。
- `RyujinxController.emulationThreadActive` 只在 `mainRyu` 返回后清除。仅暂停、UI 显示 stopped、请求 StopEmulation 都不能证明存档已停止被访问。
- 已解码当前 `com.hick.MeloNX` development provisioning profile：没有 iCloud/ubiquity entitlement。CloudDocuments capability、容器授权和包含该权限的新 profile 是真机验收前置条件，当前尚未修改开发者门户或签名。

## 用户流程

游戏详情/长按菜单进入“iCloud 存档”，当前游戏固定，另可从设置入口选择游戏。正常流程只需要游戏选择和上传/下载动作。

上传：确认模拟器已完全停止 → 读取当前用户及共享存档 → 在本地生成稳定快照并校验 → 复制到应用 iCloud 容器 → 显示“等待 iCloud 上传” → 全部文件确认上传后显示“已上传”。找不到存档时显示原因，不创建假存档。游戏未主动保存的内存进度无法上传；界面提示先在游戏内保存并退出。

下载：检索该游戏/用户的完整云端快照 → 若只有一个明确的最新分支，自动选择；显示版本来源/时间和本地备份说明 → 用户确认恢复 → 下载全部文件到本地暂存并校验 → 备份当前存档 → 恢复并 Commit → 显示完成。首次本地没有存档时仍使用合法 LibHac 创建流程和游戏控制属性，不能凭目录伪造索引。

不同设备同时上传导致多个分支时保留所有版本，要求选择明确版本后恢复；这是异常冲突处理，不增加正常流程的文件选择器。系统时间不证明版本先后，只有父版本关系可用于判定唯一后继。同一身份从未下载过云端版本的上传形成独立分支，不静默覆盖已有云端进度。

自定义用户 UID 没有匹配云端身份时，不猜测另一个人的存档。云端只有一个其他 Account 用户时，可在恢复确认中明确将该用户快照恢复到“当前用户”，记录绑定供后续使用；多用户歧义时要求明确身份绑定或取消。任何跨 UID 绑定都不改变云端原始用户路径。默认用户无需绑定。Device 存档用 shared 身份，不做用户映射。

## iCloud 目录和快照一致性

使用显式的 app-owned ubiquity container（拟定 `iCloud.com.hick.MeloNX`，须经团队实际可用性核实），在其 `Documents` 下展示 MeloNX；所有访问由 app entitlement 限定，不使用文件选择器。

```text
MeloNX/Saves/v1/<TitleID:16hex>/<UserUID:32hex-or-shared>/
  <Account-or-Device>/<index>/versions/<generation-UUID>/
    manifest.json
    payload/<relative-save-path> ...
MeloNX/Saves/v1/<TitleID:16hex>/snapshots/<generation-UUID>/
  manifest.json
```

一次游戏快照使用一个 generation，汇集 Account 和 Device 的多个逻辑记录。每个记录版本目录不可修改；游戏级 manifest 列出全部记录、父 generation、身份、记录 manifest 摘要和总字节数，用于作为整体恢复，避免从不同时间拼装多个存档。它不保存物理 SaveDataId。

每个记录 manifest 含 schemaVersion、TitleID/ProgramId、源 UserUID 或 shared、SaveDataType、index、generation、文件相对路径/长度/SHA-256（含空目录）；游戏级 manifest 含创建时间、匿名随机安装标识、父 generation 和记录引用。ID 用定长十六进制字符串，时间用 UTC ISO-8601，版本 UUID；不把标题文字作为路径。安装标识不包含 UDID/Apple ID。

本地构建全部内容并验证后才发布到云端 UUID 路径，最后写游戏级 manifest。iCloud 传输顺序不保证 manifest 最后抵达，所以 manifest 存在不等于快照可用：读者必须等待全部记录下载并校验长度/摘要。未完成版本显示“待下载/不完整”，不可恢复。上传成功也必须确认每个文件及 manifest 的 `ubiquitousItemIsUploaded`，只复制到本地容器不能宣称已经上传。

不依赖 mutable latest 文件；通过不可变 generation 和 parent 关系发现分支。保留历史版本，不自动删除云端或现有本地备份。本期没有清理历史版本功能。

## 原生存档桥与本地事务

新增 `Ryujinx.Library/SaveSync`，使用现有 Horizon/LibHac 初始化方式，提供枚举、导出、备份、恢复接口。逻辑键为 `(ProgramId, UserId, SaveDataType, index)`。枚举只允许目标游戏当前用户的 Account、该游戏的 Device（SpaceId.User）；拒绝 system、cache、temporary、BCAT 等不在本期的类型。根据应用控制属性中合法的 save owner 关系核对 ProgramId，不猜 TitleID 的位掩码。找不到合法控制属性/映射时给出错误，不试写任意位置。

所有导出/恢复在独占本地操作期间完成。通过 LibHac 挂载逻辑 save filesystem，导出已经提交的稳定内容；禁止直接用 `Directory.Move` 替换物理 `0` 或绕过 NAND 索引。若只剩工作目录或存档存在未完成事务，不把它冒充提交数据；返回可恢复/损坏状态，用户先启动游戏确认保存。

恢复前完整校验云端到本地的快照，备份所有受影响逻辑记录和“原来不存在”的记录状态并写持久事务 journal。通过 LibHac 对每个本地逻辑记录写入并 Commit；所有文件句柄关闭后报告完成。多个记录不具备跨记录原子 Commit，所以事务 journal 记录每个记录的阶段和已提交列表。任何失败由备份回滚已修改记录；新建记录仅能通过合法 LibHac 删除 API 回滚；回滚失败保留 journal/备份、阻止启动该游戏，显示恢复工具入口，不宣称完成。应用重启先扫描 journal，完成恢复/回滚前不允许挂载该游戏。

本地持久路径：`Documents/SaveSync/v1/staging/<UUID>`、`backups/<TitleID>/<UUID>`、`transactions/<UUID>.json`。所有清理只处理本任务拥有的 staging；保留成功恢复前的备份。备份和暂存按程序规则管理，不能遍历删除其他 Documents 内容。

## 生命周期与资源边界

Swift `SaveSyncCoordinator` 是 MainActor 状态所有者；独立串行 worker 做文件、摘要和 native 工作。容器 URL 在后台查询，容器不可用返回“请登录 iCloud 并开启 iCloud Drive”。NSMetadataQuery / 文件资源值观察下载和上传状态，NSFileCoordinator 只用于短时协调读取/写入；不在协调锁中等待网络或运行长轮询。

本地互斥由 shared operation gate 管理：游戏启动（包括等待 JIT 的启动意图）、NSZ 导入注册、存档导出/恢复不允许竞争；游戏停止返回后才能取得 save lease。所有游戏启动入口都检查 lease，恢复重启 journal 也占用 gate。纯云端上传观察不长期占用本地 gate：稳定快照落盘以后可释放本地 save lease；恢复从本地备份到 Commit/回滚完成一直持有 lease。

UI 关闭、切后台或取消：在修改本地存档前可以取消并保留云端已排队的完整 generation；恢复事务开始后进入“正在安全结束”，不强行中断 Commit/回滚。worker 未确认结束前不释放原生资源、租约或临时文件，不能开始重试。需要额外后台时间时使用有截止时间的 iOS background task；过期时保留可重启恢复的 journal。

监听 iCloud identity 变化。每项任务捕获身份 token；切换或退出账户后取消云端工作，不把旧账户路径和完成状态用于新账户。已经进入本地恢复事务时先完成 Commit 或回滚，云端重新访问须用户重试。

## 校验、容量和故障状态

- 限定 UTF-8 相对路径，拒绝绝对路径、`.`/`..`、NUL、链接/别名/特殊文件、重复及大小写/规范化冲突；每一项再次验证位于 staging 根内。cloud manifest 是不可信输入。
- 有界 manifest（≤4 MiB）、记录数≤64、文件/目录≤100000、相对路径≤1024 UTF-8 字节、目录深度≤64；检查整数溢出及实际长度。不一次把存档或清单全部内容读进内存。
- 分块复制/摘要（1 MiB），读取短读必须完整处理。校验每个文件 SHA-256、记录 manifest 和游戏级清单身份一致、未知 schema/type 拒绝；不支持可执行操作指令。
- 本地预检需要下载/稳定快照 + 完整备份 + 恢复工作区 +256 MiB 余量，过程中重查；空间不足和 ENOSPC 保留当前存档与备份。云端 quota/offline/provider errors 独立显示；不能用本地 free-space 代替 iCloud quota 成功判断。
- 区分 noSave、busy、cloudUnavailable、queued/offline、quota、incompleteSnapshot、conflict、identityMismatch、malformedSnapshot、restoreFailed、rollbackRequired，不泄漏敏感完整路径/keys。
- 系统 `NSFileVersion` 冲突也视为冲突，不自动把输家版本删除/标记已解决；不可变 generation 降低冲突概率但不能假定没有冲突。

## 组件边界与验证

Foundation-only Swift save sync core 测试 manifest、版本图、账户变化、状态机/租约和取消；UIKit/cloud/native adapters 放入 app。C# SaveSync bridge 提供受约束 JSON/C ABI、拥有任务生命周期和异常边界，不复用 NSZ 的包分类；共享文件安全/operation gate 时只提取有真实两方需求的最小接口。

测试覆盖：Account/Device/多 index 映射、不同 SaveDataId 同一逻辑键、默认用户及显式跨 UID 绑定、零文件/空目录、恶意 manifest、短读、hash/length mismatch、无空间、上传待确认、断网/账户切换、并行启动被拒绝、每个恢复阶段失败与回滚、进程中断后 journal 恢复、不同设备同时上传的多个分支。不用“写进本地 iCloud 容器”替代真实云端验证。

真机验收分层：
1. 重新生成含 CloudDocuments 的 profile，验证 app/container entitlement 与实际签名一致，保持原 app/container 数据并原位安装 hick 手机；helper 保留原必要权限。
2. 同一 iCloud 账户的第二台设备：上传一个合法测试游戏实际存档，观察两端字节/摘要一致和“已上传”状态，测试离线排队及冲突保留。
3. 恢复到原已备份存档或新合法 save mapping，启动游戏验证真实进度；证明没有交换 NAND 索引/keys/其他游戏数据。

目前没有合法游戏/存档样本且第二台 iPad 未确认在线，不能宣布第2/3步通过。缺少 iCloud 团队 capability 权限时继续本地实现/测试，报告准确阻塞和所需账号操作；不悄悄降级为文件夹选择器，不创建外部服务。

## 官方依据

- Apple [获取 ubiquity container URL](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29)：后台获取、容器可用性与访问配置。
- Apple [ubiquitousItemIsUploadedKey](https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemisuploadedkey)：区分本地存在与上传确认。
- Apple [NSFileVersion.isConflict](https://developer.apple.com/documentation/foundation/nsfileversion/isconflict)：系统文件版本冲突不能静默忽略。

## 审阅边界

已按用户选择的手动方式和只选择游戏流程落成具体设计。独立审阅检查身份/SaveDataId 映射、跨记录事务、云端非原子传播、生命周期与签名可行性。书面设计认可后编写执行计划，沿用 Native 执行偏好。此阶段未编写云端产品代码、修改开发者账号或传输存档。
