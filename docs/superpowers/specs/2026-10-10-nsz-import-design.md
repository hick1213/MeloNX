# MeloNX NSZ 导入设计

## 已确认的目标

用户确认：在 hick 手机的 MeloNX 中选择 NSZ，手机后台流式还原成 NSP，
兼容普通及分块 NCZ，显示进度并允许取消，检查可用空间、验证结果，
保留源 NSZ 和已有游戏。工具、下载、缓存及构建继续放在
`/Volumes/untitled/github/MeloNX` 下。

本轮优先交付 NSZ。XCI 已有真实导入、元数据及 LoadXci 路径；其行为需回归。
XCZ、独立 NCZ、ZIP/7Z/RAR、解包目录及其他平台游戏不随本轮添加。
更新与 DLC 的 NSZ 可以转换，仍使用现有更新/DLC 管理入口；不作为本体自动启动。

## 现状与选择

Swift 添加游戏直接同步复制到 Documents/roms；GameFileType 没有 NSZ。
核心能加载 NSP/PFS0，未实现 NCZ/Zstandard。文件选择器在同步 completion
结束时释放访问权限，新的异步导入必须独立持有 security-scoped URL。

采用导入时转换：结果是现有加载器可用的 NSP，不增加运行期压缩存储后端。
替代方案为核心直接随机读取 NSZ，需改变存储/缓存/启动路径，风险和工作量更大；
Mac 预转换则不能实现已确认的手机内置导入目标。

## 组件与接口

1. 独立 C# 转换组件，依赖固定 `ZstdSharp.Port 0.8.8`；使用纯托管
   Zstandard 流与块解压，不调用手机 Python 或外部程序。组件本身不引用 GPU、
   JIT 或用户账户。AES-CTR 与 SHA-256 使用现有 .NET 密码学能力。
2. Ryujinx.Library 的小型 C ABI 桥提供 `create / run / progress / cancel / free`。
   create 返回拥有 CancellationTokenSource 和进度快照的 opaque handle；run
   在 Swift 专用串行工作队列阻塞执行；progress/cancel 可并发调用；free 只能在
   run 返回且轮询停止后执行。错误以固定代码和脱敏说明返回；所有字符串由匹配
   free 函数释放。不得向 Swift 返回 NCA section key/counter 或原始异常堆栈。
3. Swift NSZImportCoordinator 持有 URL 访问权限、任务 UUID、工作线程与 native
   handle；主线程只发布进度。UI 消失、后台或取消立即撤销自动启动意图，向 native
   发取消请求，并保留资源到工作线程确认结束。未结束前禁止第二个转换。
4. 添加游戏、打开游戏、更新/DLC 文件入口共用 NSZ 标准化服务。添加游戏将结果
   提交到 roms；打开游戏成功后交给现有启动/JIT 流程；更新/DLC 结果保存在其持久
   导入目录，现有配置引用该 NSP。调用者不得引用将要清理的临时文件。

所有回调和轮询归属同一个 UUID；旧结果不得覆盖新 UI 或启动游戏。
NSZ 导入不是 JIT 获取操作，也不修改固件、keys、存档或配对凭据。

## 转换规则

解析输入 PFS0 目录，保留条目顺序。普通条目（包括 NCA、ticket、证书和元数据）
逐块复制；NCZ 条目还原为 NCA 并以原始名称写入新的 PFS0/NSP。
预先计算还原后的每个条目大小和整个输出大小，重建容器偏移与字符串表。

NCZ 保留原始前 0x4000 字节。按 NCZSECTN section 信息读取连续还原数据，
支持普通 Zstandard 流及 NCZBLOCK 独立压缩/原样块；对 cryptoType 3/4 按绝对
NCA 偏移应用 AES-CTR，其余受支持的未加密 section 原样写入。
CTR 前缀和计数器偏移遵循上游格式及公开实现，不使用猜测的填充或重加密规则。
非连续/重叠 section、未知 block 版本/type、截断、溢出、重复名称、非法路径或
超出容器边界的条目必须明确失败，不产生“成功但不可运行”的输出。

流式累计还原 NCA 的 SHA-256，与标准 NCA 内容 ID 文件名的 16 字节前缀匹配；
带 `.cnmt` 的名称按内容 ID 部分验证。无法验证或哈希不符时不提交。
最终重新读取输出 PFS0，验证条目名称/大小/边界，并通过现有核心解析其内容类型：
本体进入游戏库，更新/DLC 转给对应入口。缺少运行所需 keys 明确报告，不能以
GameInfo 返回 Unknown/全零 TitleID 作为校验通过。

## 磁盘、内存与文件所有权

输出写入目标持久目录内的 `.imports/<UUID>/result.partial`，与最终文件同一卷；
只有全部转换、哈希与包结构验证通过，才 rename 到最终 NSP 路径。
同名已有文件保留并生成新的无冲突文件名，不自动覆盖或删除源文件。
取消/失败只删除本任务创建的临时目录，启动时清理可证明没有活动拥有者的残留。

源文件由其已持有的安全作用域直接读取，避免再复制完整 NSZ。内存不随游戏大小
增长：固定复制缓冲（1 MiB），一个有上限的 NCZ block 缓冲及有限 Zstd window。
初始上限：block exponent 不超过 26（64 MiB）、Zstd window 不超过 128 MiB、
section 不超过 64、PFS0 条目不超过 8192；超限明确报告格式/资源限制。
所有长度与偏移使用受检查的 64 位算术。

转换前按预计完整 NSP 大小加 256 MiB 余量检查手机空间；写入期间重新检查实际
可用空间并捕获 ENOSPC。空间不足不能删除用户原件来换空间。进度按预计输出
字节数计算，在 UI 显示“准备/转换/校验/完成”；不能在校验前显示 100% 成功。

首次只处理一个导入任务；用户选择批量 NSZ 时顺序排队，取消结束当前队列。
后台中断取消当前导入并清理临时文件，不承诺无限后台执行或断点续传。

## 验证与交付条件

- 转换组件测试使用自生成数据和公开格式向量：普通/分块/原样末块、跨块读取、
  多 section、CTR 偏移、混合 NCZ/NCA/普通条目；还原 NSP 与预期字节及哈希一致。
- 失败测试覆盖损坏/截断/越界/重复路径/未知格式/哈希不符/超限、磁盘不足、
  转换中取消、校验中取消、重复导入与晚到回调；原件及已有目标逐字节不变。
- Swift 导入状态测试证明作用域及 handle 在 worker 返回前不释放、取消不会启动
  游戏、成功/失败只完成一次，普通 NSP/XCI 导入保持正常。
- 固定依赖许可证随应用打包。iOS arm64 NativeAOT 发布与完整 Xcode 构建必须
  实际通过；NuGet 的框架兼容声明不代替 AOT 验证。
- 在 hick 手机上用小型合成 NSZ 验证解压、输出字节哈希、进度/取消/残留清理；
  在普通界面选择文件验证导入入口。安装采用同 bundle 原位更新，核验数据保留。
- 若没有用户提供的可运行 NSZ 游戏，区分“转换/导入已验证”与“商业游戏玩法未验证”；
  不下载游戏或密钥来填补验收。实际样本的运行验证继续使用已通过的内置 JIT。

## 原始依据

- [NSZ 格式说明](https://github.com/nicoboss/nsz/blob/master/docs/formats.md)
- [NCZ 独立还原实现](https://github.com/nicoboss/nsz/blob/master/nsz/IndependentNczDecompressor.py)
- [NSZ 容器还原实现](https://github.com/nicoboss/nsz/blob/master/nsz/Decompressor.py)
- [分块读取实现](https://github.com/nicoboss/nsz/blob/master/nsz/BlockDecompressorReader.py)
- [ZstdSharp](https://github.com/oleg-st/ZstdSharp) 与
  [固定 NuGet 版本](https://www.nuget.org/packages/ZstdSharp.Port/0.8.8)
- 本地：GameFileType.swift、FileImporter.swift、RyujinxController+FilePicker.swift、
  Ryujinx.Library/GameInfo.cs 与 Library.cs。
