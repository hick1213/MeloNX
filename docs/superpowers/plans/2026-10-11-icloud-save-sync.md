# Manual iCloud Save Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户只选择游戏，通过手动上传/下载将当前模拟器用户及游戏共享存档保存到应用管理的 iCloud 目录，并能安全恢复。

**Architecture:** Foundation 状态机管理快照、身份绑定及云端版本；C# 通过真实 LibHac filesystem 导出、备份和恢复，使用持久 journal 跨记录回滚。Swift 主线程只处理交互，串行 worker 持有资源；统一 operation gate 阻止游戏/JIT 启动意图、NSZ 注册及存档修改竞争。CloudDocuments 观察器区分本地排队与真实上传完成。

**Tech Stack:** .NET10.0.100 / 现有 Ryujinx.LibHac0.21.0-alpha.129；Swift5.9 Foundation 包（iOS15/macOS12）及现有 SwiftUI app；iOS arm64 NativeAOT；CloudDocuments / NSFileCoordinator / NSMetadataQuery。不新增第三方云端服务或压缩依赖。

**Spec:** `docs/superpowers/specs/2026-10-10-icloud-save-sync-design.md`，用户2026-10-11确认书面设计，独立架构审阅80c628bbe已通过。

**Execution:** Native，保留用户已明确选择；作者逐任务实现，最后一次独立整分支审查。用户已认可书面设计并批准此实施计划及 Native 执行；当前实施与验收状态见独立 ledger。

## Global Constraints

- 正常流程只选择游戏、手动上传/下载；自动捕获当前模拟器用户，不新增 Files/文件夹选择步骤。
- Account + Device、对应 index；SpaceId.User / Primary / Normal，其他 rank/state 不猜测或冒充提交数据，返回不支持/恢复所需状态。
- 逻辑键 `(ProgramId, UserId, SaveDataType, index)`；SaveDataId 是本地映射，不能作为跨设备游戏 ID。不上传 NAND 索引、固件、keys、配对材料。
- 云端固定结构：`MeloNX/Saves/v1/<TitleID:16hex>/<UserUID:32hex-or-shared>/<Account-or-Device>/<index>/versions/<generation-UUID>/{manifest.json,payload/...}`；游戏级清单 `MeloNX/Saves/v1/<TitleID:16hex>/snapshots/<generation-UUID>/manifest.json`。
- 每次整游戏快照使用一个 generation；不可变版本、父 generation 关系，不用 mutable latest 文件，不按设备时间自动覆盖分支。
- manifest≤4MiB；记录≤64；文件/目录总数≤100000；UTF-8相对路径≤1024字节、深度≤64；复制/摘要缓冲1MiB；检查整数溢出、大小写/Unicode规范化冲突、链接/特殊文件、SHA256及实际长度。
- 本地预检包含下载/稳定快照、完整备份、恢复工作区及256MiB余量；挂载可能生成工作副本，其容量计入工作区；过程重查并捕获ENOSPC。
- 本地路径 `Documents/SaveSync/v1/{staging/<UUID>,backups/<TitleID>/<UUID>,transactions/<UUID>.json}`；只清理本次拥有的暂存，保留历史云端版本和本地备份。
- LibHac逐记录Commit，全部写句柄必须先关闭；不能Directory.Move替换物理0、复制旧SaveDataId或直接写NAND索引。
- 修改前：全部备份持久化→记录 mayHaveChanged→写入/Commit；全部成功且句柄关闭→持久completed→幂等绑定/parent更新→UI成功。未完成事务保守回滚；completed事务不回滚。
- 恢复事务启动前可取消；启动后只请求安全完成/回滚，资源与gate在worker确认结束前不能释放。重启恢复未解决时阻止受影响游戏挂载。
- iCloud身份变化撤销旧账户任务；绑定按账户/container/game/localUID隔离，成功恢复后才生效。源cloudUID与目标localUID明确分开。
- 上传确认覆盖每个payload/record清单/游戏清单；本地容器有文件不等于已上传。已知但不完整后继阻止自动选择旧父版。
- 容器拟定 `iCloud.com.hick.MeloNX`；实际团队授权/profile匹配后才允许启用。保持现有com.hick.MeloNX、同团队签名、JIThelper权限和所有用户数据，原位安装。
- 下载、缓存、工具及构建输出都在 `/Volumes/untitled/github/MeloNX`；当前NSZ源码70884d713及尚未完成的真机验收保留。

## Review Focus

- 恢复最后一个Commit成功而completed写入前终止：重启回滚所有mayHaveChanged，不能漏记录或误报成功（Task4/5）。
- completed已落盘而身份绑定未写入：重启仅补齐绑定，不把成功恢复的存档恢复回旧版本（Task4/7）。
- 子manifest先到、payload后到，或第二设备分支迟到：所有可见版本进图，不完整后继阻止默认旧父版，保留冲突（Task2/6）。
- 暂停、noJIT等待或UI关闭时native线程仍活着：启动/NSZ/save lease都不能提前重叠，取消不释放打开的资源（Task1/5/7）。
- 只有工作目录1、非零index或挂载自动修复：上传不把未提交工作数据当成提交快照，创建不顺带改变BCAT/Temporary等记录（Task3/4）。

## File Map and Shared Contracts

新Foundation包 `src/MeloNX/MeloNXOperationCore/` 只包含共享lease与blocked-games；app、ImportCore适配器和SaveSyncCore使用同一实例，不改JITCore内部引擎。新包 `src/MeloNX/MeloNXSaveSyncCore/` 包含manifest、版本图、绑定、状态机；app的CloudDocuments/native/UI适配器在 `MeloNX/Common/SaveSync/`。PBX使用现有本地Swift package模式。

新C#组件 `src/Ryujinx.SaveSync/`（独立net10、无GPU/JIT依赖）包含逻辑模型、文件校验、durable journal、备份/恢复事务。`src/Ryujinx.SaveSync.Tests/`使用现有NUnit/TestSDK版本及生成数据。真实LibHac适配器和Cexports在 `src/Ryujinx.Library/SaveSync/`，Library新增最小上下文访问与ProjectReference。

以下任务简写路径统一展开：OperationCore Sources/Tests分别在`src/MeloNX/MeloNXOperationCore/Sources/MeloNXOperationCore/`、`Tests/MeloNXOperationCoreTests/`；SaveSyncCore Sources/Tests在`src/MeloNX/MeloNXSaveSyncCore/Sources/MeloNXSaveSyncCore/`、`Tests/MeloNXSaveSyncCoreTests/`；app Common/SaveSync在`src/MeloNX/MeloNX/Common/SaveSync/`。C#核心/tests路径分别是`src/Ryujinx.SaveSync/`、`src/Ryujinx.SaveSync.Tests/`；Library路径`src/Ryujinx.Library/Library.cs`及`src/Ryujinx.Library/Ryujinx.Library.csproj`。每个包Package.swift声明上述同名targets，SaveSyncCore依赖OperationCore本地包。

主要Swift合同（每个类型在标注任务中定义）：

```swift
// Task1
public enum LocalOperationKind { case launch, emulation, packageImport, saveExport, saveRestore, recovery }
@MainActor public final class LocalOperationGate {
    public init()
    public func acquire(_ kind: LocalOperationKind, gameID: UInt64?) throws -> LocalOperationLease
    public func block(gameIDs: Set<UInt64>)
    public func unblock(gameID: UInt64)
    public var busy: Bool { get }
}
@MainActor public final class LocalOperationLease {
    public func finish(workerHasEnded: Bool) throws
}
// Task2: typed UInt64 at API boundary; wire/path IDs are exact hex strings.
public struct SaveSlotKey: Hashable, Codable, Sendable {
    public let programID: UInt64; public let userID: String
    public let type: SaveSlotType; public let index: UInt16
}
public enum SaveSlotType: String, Codable, Sendable { case account = "Account", device = "Device" }
public struct SaveFileEntry: Codable, Sendable {
    public let path: String; public let length: Int64; public let sha256: String
}
public struct SaveRecordManifest: Codable, Sendable {
    public let schemaVersion: Int; public let generation: UUID; public let key: SaveSlotKey
    public let files: [SaveFileEntry]; public let emptyDirectories: [String]
}
public struct SaveRecordReference: Codable, Sendable {
    public let key: SaveSlotKey; public let manifestRelativePath: String
    public let manifestSha256: String; public let totalBytes: Int64
}
public struct SaveSnapshot: Codable, Sendable {
    public let schemaVersion: Int; public let generation: UUID; public let parent: UUID?
    public let titleID: UInt64; public let ownerUserID: String; public let createdUTC: String
    public let installationID: UUID; public let totalBytes: Int64
    public let records: [SaveRecordReference]
}
public enum SnapshotAvailability: Sendable { case pending, verified }
public struct VisibleSnapshot: Sendable {
    public let snapshot: SaveSnapshot; public let availability: SnapshotAvailability
}
public struct CloudListing: Sendable {
    public let versions: [VisibleSnapshot]; public let unreadableGenerations: Set<UUID>
}
public enum CloudHeadSelection: Equatable { case none, ready(UUID), pending(Set<UUID>), conflict(Set<UUID>) }
public struct SnapshotVersionGraph {
    public init(_ versions: [VisibleSnapshot], unreadableGenerations: Set<UUID> = []) throws
    public func select(ownerUserID: String) throws -> CloudHeadSelection
}
// Task6
public struct CloudIdentity: Hashable, Sendable { public let localAccountKey: UUID; public let container: String }
public protocol CloudSaveStore: Sendable {
    func identity() async throws -> CloudIdentity
    func list(titleID: UInt64, identity: CloudIdentity) async throws -> CloudListing
    func publish(localRoot: URL, snapshot: SaveSnapshot, identity: CloudIdentity) async throws
    func waitUploaded(snapshot: SaveSnapshot, identity: CloudIdentity) async throws
    func download(snapshot: SaveSnapshot, into: URL, identity: CloudIdentity) async throws
}
// Task7
public struct SaveGameSelection: Sendable {
    public let titleID: UInt64; public let gamePath: String
    public init(titleID: UInt64, gamePath: String)
}
@MainActor public final class SaveSyncEngine {
    public func upload(_ selection: SaveGameSelection) async
    public func prepareDownload(_ selection: SaveGameSelection) async
    public func restorePrepared(generation: UUID, allowUserBinding: Bool) async
    public func cancel()
    public var phase: SaveSyncPhase { get }
    public var canStart: Bool { get }
}
```

Task2为所有wire value structs提供与全部成员同名的public initializer；Task6为CloudIdentity提供`init(localAccountKey:container:)`。API中的UInt64以手写Codable编码为16hex字符串，不允许JSON浮点ID。只有record manifest保存文件列表；游戏manifest只保存record引用，避免两个可修改文件列表成为冲突来源。`VisibleSnapshot`不是云端schema：pending表示清单/记录/文件尚未完整下载校验，verified表示本机已验证整个generation。读取图先发现所有后继，主动下载校验候选头；pending后继绝不默认退回已verified父版。

C#合同：`SaveKey(ulong ProgramId,string UserId,SaveKind Kind,ushort Index)`、`SaveKind { Account, Device }`；跨语言JSON的UserId统一32hex，Device是`shared`。`SaveSelection(Guid Id,ulong TitleId,string LocalUserId,IReadOnlyList<SaveKey> Keys,SaveCreateControl? Control)`仅存在本机。`SaveCreateControl`存OwnerId、Account/Device数据/日志大小及flags，来自真实NACP；不从名称推测。

`SaveCreateControl(ulong OwnerId,long AccountSize,long AccountJournalSize,long DeviceSize,long DeviceJournalSize,uint Flags)`、`SaveEntry(string Path,bool IsDirectory,long Length)`及`SaveMapping(SaveKey Key,ulong LocalSaveDataId)`是本机类型；控制缺失用`SaveCreateControl?`。snapshot的C#类型对应以上Swift字段，UInt64手写hex转换；调用原生恢复时显式从源cloudUID映射到捕获的localUID。

```csharp
public interface ISaveRepository {
    SaveSelection Describe(ulong titleId, string gamePath, string currentUser);
    SaveSelection AuthorizeRestore(SaveSelection selection, SaveSnapshot snapshot);
    bool Exists(SaveKey key);
    ILogicalSave OpenCommitted(SaveKey key);
    ILogicalSave OpenWritable(SaveKey key);
    SaveMapping CreateExact(SaveKey key, SaveCreateControl control);
    void DeleteExact(SaveKey key);
}
public interface ILogicalSave : IDisposable {
    IEnumerable<SaveEntry> Entries();
    int Read(string path, long offset, Span<byte> buffer);
    void ReplaceFrom(string localPayload);
    void Commit();
}
public interface IDurableStore {
    void WriteAtomic(string path, ReadOnlySpan<byte> bytes);
    void SyncTree(string root);
}
public enum RestoreStatus { Completed, RolledBack, RecoveryRequired }
public sealed record BindingIntent(Guid AccountKey, string Container, ulong TitleId,
    string LocalUserId, string CloudUserId, Guid Generation);
public sealed record RestoreOutcome(RestoreStatus Status, Guid TransactionId,
    BindingIntent? CompletedBinding, IReadOnlySet<ulong> BlockedGames);
```

`SaveBindingKey(localCloudAccountUUID: UUID,container: String,titleID: UInt64,localUID: String)`及`SaveBinding(cloudUID: String,lastGeneration: UUID)`为Task7 Codable/Hashable value structs，带同名public initializer。`SaveUserBindings`合同：`read(key:) throws -> SaveBinding?`；`recordUploaded(key:cloudUID:generation:) throws`原子持久更新；`applyCompleted(intentFile: URL,transactionID: UUID) throws`幂等补齐原账户绑定。旧账户completed意图保存至原键，不能使新账户UI成功；仅确认整次上传isUploaded后调用recordUploaded，离线排队不前移parent。

Repository只允许预先描述/授权的逻辑集合。AuthorizeRestore核对title/type/index及源cloud身份，再将Account目标用户改为本机currentUser、Device保持shared；可授权快照中合法但本机尚不存在的index，禁止触及未列入快照的记录。Replace精确重建、截断并关闭文件句柄，Commit另调用。`FakeSaveRepository`实现上述接口；测试factory `CreateTwoRecords()`提供Account/index0、Device/index0，`CreateExact`可返回与另一实例不同的SaveDataId。

`SaveRestoreTransaction`（Task4）合同：构造`(ISaveRepository repository,IDurableStore durable,string ownedRoot)`；`RestoreOutcome Run(SaveSelection selection,string snapshotRoot,BindingIntent bindingIntent)`、`void RequestSafeStop()`、`IReadOnlyList<RestoreOutcome> RecoverIncomplete()`。durable方法返回成功或抛错，不把普通write当持久化。

Swift Task5/7合同：

```swift
public struct SaveNativeSelection: Sendable {
    public let id: UUID; public let titleID: UInt64; public let localUserID: String
    public let keys: [SaveSlotKey]; public let canCreateMissing: Bool
}
public struct SaveExportIdentity: Sendable {
    public let cloudUserID: String; public let parent: UUID?
    public let generation: UUID; public let installationID: UUID; public let createdUTC: String
}
public struct NativeExportResult: Sendable { public let localRoot: URL; public let manifest: SaveSnapshot }
public enum SaveNativeStatus: Sendable { case completed, safelyStopped, failed, recoveryRequired }
public struct SaveNativeResult: Sendable {
    public let status: SaveNativeStatus; public let resultFile: URL?
    public let blockedGames: Set<UInt64>; public let errorCode: String?
}
public protocol SaveNativeService: Sendable {
    func describe(_ game: SaveGameSelection) async throws -> SaveNativeSelection
    func export(_ selection: SaveNativeSelection, identity: SaveExportIdentity, into: URL) async throws -> NativeExportResult
    func restore(_ selection: SaveNativeSelection, snapshotRoot: URL, bindingIntentFile: URL) async throws -> SaveNativeResult
    func recover() async throws -> SaveNativeResult
    func requestSafeStop() async
    func confirmEnded() async -> Bool
}
```

Task5的`NativeSaveWorker`实现SaveNativeService，内部每job的`run() async throws -> SaveNativeResult`等待真实线程结束、借用归零并free后才返回。测试`HeldSaveWorker`实现同合同、通过`finish(status:)`释放completion continuation。Task7 `SaveSyncEngine`初始化注入`(gate: LocalOperationGate,native: any SaveNativeService,cloud: any CloudSaveStore,bindings: SaveUserBindings,ownedRoot: URL,installationID: UUID)`；phase为只读状态，恢复/冲突/身份选择数据由独立viewmodel发布，不把UIKit带入Core。

## Task 1: Shared Local Operation Gate and Launch Integration

**Files:** Create `src/MeloNX/MeloNXOperationCore/Package.swift`, `Sources/MeloNXOperationCore/LocalOperationGate.swift`, `Tests/MeloNXOperationCoreTests/LocalOperationGateTests.swift`（后两者相对该包）；create `src/MeloNX/MeloNX/Common/Operations/LocalOperations.swift`；modify `src/MeloNX/MeloNX/Core/RyujinxController.swift`, `src/MeloNX/MeloNX/Common/JIT/BuiltIn/BuiltInJITCoordinator.swift`, `src/MeloNX/MeloNX/UI/Main/NoJITView.swift`, `src/MeloNX/MeloNX/Common/Import/NSZImportCoordinator.swift`, `src/MeloNX/MeloNX/UI/Main/ContentView.swift`, `src/MeloNX/MeloNX.xcodeproj/project.pbxproj`。

**Consumes:** 现有emulationThreadActive、.started(noJIT)、JIT canRetry、NSZ worker结束信号。**Produces:** 上述LocalOperationGate/Lease和单实例`LocalOperations.shared`；游戏launch lease在同一generation交给NoJIT继续启动，不能新建一个冲突lease。

blocked games限制launch/export/restore/packageRegistration，recovery lease允许处理该blocked游戏；bootstrap尚未扫描journal时全局初始化屏障尚未完成，全部启动入口等待。单独JIT重试也可能使用native helper，BuiltInJITCoordinator为它取得launch-kind lease（gameID nil），已有launch流程则借用同一个lease，不能以设置页没有选择游戏为由绕过gate。

- [x] 写Gate测试：noJIT等待持有launch、active native线程阻止save、`finish(false)`拒绝释放、stale lease不释放新generation、recovery只阻止其游戏。

```swift
@MainActor func testCancellationDoesNotReleaseLiveLease() throws {
    let gate = LocalOperationGate()
    let lease = try gate.acquire(.saveRestore, gameID: 0x100)
    XCTAssertThrowsError(try lease.finish(workerHasEnded: false))
    XCTAssertThrowsError(try gate.acquire(.launch, gameID: 0x100))
    try lease.finish(workerHasEnded: true)
    XCTAssertFalse(gate.busy)
}
```

- [x] `swift test --package-path src/MeloNX/MeloNXOperationCore`观察RED缺少类型；配置/空target可与测试同一任务建立。实现UUID/generation lease、blockedSet、single owner，拒绝重复finish，保留可追踪错误。
- [x] 接入所有Controller.startGame/URL启动、NoJIT同一请求继续、NSZ begin及per-file注册；游戏mainRyu返回后才交还emulation lease。NSZ callbacks注册结束才结束packageImport lease；scope与handle规则保持。

完成NSZ queue的owned run及全部per-file registration后才调用`lease.finish(workerHasEnded: true)`；取消请求本身不执行finish。Gate的测试还要以held native completion断言lease仍占用，避免仅检查UI状态。

- [x] 运行OperationCore、ImportCore、JITCore及一次真实iOS build；预期原有NSZ22/JIT37测试不回归，新增gate用例通过。提交Task1源文件；不安装新app或修改iCloud权限。

## Task 2: Snapshot Schema, Safe Paths and Visible Version Graph

**Files:** Create SaveSyncCore `Package.swift`, Sources `SaveSnapshot.swift`, `SnapshotPaths.swift`, `SnapshotValidation.swift`, `SnapshotVersionGraph.swift`; Tests对应文件。Create C# `Ryujinx.SaveSync.csproj`, `SaveModels.cs`, `SnapshotFiles.cs`及测试csproj/生成fixtures；复用现有Crypto/SHA256，不新增包。

**Produces:** Shared Contracts的SaveSnapshot/SaveRecordReference/SaveRecordManifest/VisibleSnapshot/SnapshotVersionGraph；schemaVersion1（整数）、generation/parent UUID、TitleID16hex、ownerUserID32hex、createdUTC、installationID随机UUID、records数组。引用含manifestRelativePath/manifestSha256/totalBytes；record manifest含files及emptyDirectories；每file含path、length(Int64)、sha25664hex；Device user为shared。totalBytes使用checked Int64求和且必须匹配清单。物理SaveDataId只允许本地journal/private backup，不在云端schema。

- [x] 写cross-language canonical fixture与恶意路径、case/NFC collision、manifest超4MiB、overflow、空目录、unknown type/schema测试。定义 `SnapshotFixture.oneAccountAndDevice()`生成两条公开测试记录及固定hash，无用户数据。

```swift
func testIncompleteVisibleChildBlocksItsCompleteParent() throws {
    let parent = SnapshotFixture.complete(generation: UUID())
    let child = SnapshotFixture.pending(parent: parent.snapshot.generation)
    let selection = try SnapshotVersionGraph([parent, child]).select(ownerUserID: parent.snapshot.ownerUserID)
    XCTAssertEqual(selection, .pending([child.snapshot.generation]))
}
```

- [x] 观察Swift/C#测试RED。实现手写/受控Codable/JsonSerializerContext，定长hex/UUID校验，路径分段验证及每次落盘再次containment检查；拒绝symlink/special file，不读取整个save到内存。C#合同`SaveRecordReference SnapshotFiles.Export(string root,SaveKey cloudKey,Guid generation,ILogicalSave save,CancellationToken ct)`写payload+record清单；`void SnapshotFiles.Verify(string root,SaveSnapshot snapshot,CancellationToken ct)`逐文件长度/hash。`SnapshotFixture.complete(generation:) -> VisibleSnapshot`和`pending(parent:) -> VisibleSnapshot`都使用同一固定TitleID/owner；前者verified，后者pending。
- [x] 实现所有可见manifest进图、parent必须同TitleID/身份、cycle/重复generation拒绝；限制图至8192节点。先判后继与分支，再判完整性；无parent独立分支保留，不按UTC选赢家。

```swift
func selectVisibleHead(_ listing: CloudListing, cloudUserID: String) throws -> CloudHeadSelection {
    try SnapshotVersionGraph(listing.versions, unreadableGenerations: listing.unreadableGenerations)
        .select(ownerUserID: cloudUserID)
}
```

- [x] 测所有Review Focus云端先manifest后payload用例、两个同时上传分支、未知父版、设备时钟回拨、目录已见但game manifest未下载。unreadableGenerations非空时返回pending并阻止默认选择；已下载但解析非法返回malformedSnapshot，不把generation默默当不存在。跑两套fixture字节/hex一致性、完整Core套件，提交Task2。

## Task 3: Real LibHac Logical Save Enumeration, Safety Backup and Export

**Files:** Create Library `SaveSync/SaveContext.cs`, `LibHacSaveRepository.cs`, `SaveControlLoader.cs`; modify `Library.cs`新增受gate控制的context accessor；Create Tests `SaveRepositoryTests.cs`（linked生产适配器+既有LibHac包，不引入GPU graph）。

**Consumes:** SaveKey/ILogicalSave/SnapshotFiles。**Produces:** ISaveRepository/FakeSaveRepository/SaveCreateControl、stable SaveSelection。`SaveContext.ReadCurrentSaveSelection(ulong titleId,string gamePath) -> SaveSelection`；`SaveContext.ExportSelection(SaveSelection selection,SaveExportIdentity identity,string localRoot,CancellationToken ct) -> SaveSnapshot`，其中C# SaveExportIdentity字段逐一对应Swift。Scope/FSID只在本地，cloud never carries them。

- [x] 写生成临时LibHac FsServer上下文测试：同ProgramId不同SaveDataId、Account与Device、多index、不同用户隔离、Primary/Normal过滤、only1拒绝、0/1不一致时挂载前安全备份、写句柄未关闭Commit失败。helper `SaveRepositoryFixture.Create(accountIndexes:[0,2],device:true)`返回独立fake NAND/Horizon/client，Dispose只删除其临时root。

```csharp
[Test]
public void RestoreAuthorizationPreservesIndexesAndMapsOnlyAccountUser() {
    using var f = SaveRepositoryFixture.Create(accountIndexes: [0, 2], device: true);
    SaveSelection local = f.Repository.Describe(f.TitleId, f.GamePath, f.LocalUserId);
    SaveSnapshot cloud = f.SnapshotForOtherUser();
    SaveSelection mapped = f.Repository.AuthorizeRestore(local, cloud);
    Assert.That(mapped.Keys.Where(k => k.Kind == SaveKind.Account).Select(k => k.Index),
        Is.EquivalentTo(new ushort[] { 0, 2 }));
    Assert.That(mapped.Keys.Where(k => k.Kind == SaveKind.Account).All(k => k.UserId == f.LocalUserId), Is.True);
    Assert.That(mapped.Keys.Single(k => k.Kind == SaveKind.Device).UserId, Is.EqualTo("shared"));
}
```

fixture的`Repository`、`TitleId`、`GamePath`、`LocalUserId`属性提供真实临时LibHac上下文；NACP loader可注入生成的合法ApplicationControlProperty，避免测试依赖用户游戏/keys。`SnapshotForOtherUser()`生成相同title/index集合但不同cloudUID，不携带SaveDataId。真实包NACP读取由Task9验证。
- [x] 观察RED。从 `_libHacHorizonManager.RyujinxClient.Fs` 获取privileged client；当前用户 `_accountManager.LastOpenedUser.UserId.ToLibHac()`，不新建VFS/Horizon singleton。分页 `OpenSaveDataIterator`→ReadSaveDataInfo，精确ProgramId/type/user/index/rank/state筛选。

```csharp
SaveDataAttribute.Make(out var attribute, new ProgramId(key.ProgramId), type, user,
    0, key.Index, SaveDataRank.Primary).ThrowIfFailure();
using var proxy = fs.Impl.GetFileSystemProxyServiceObject();
using var serviceFs = new SharedRef<LibHac.FsSrv.Sf.IFileSystem>();
proxy.Get.OpenReadOnlySaveDataFileSystem(ref serviceFs, SaveDataSpaceId.User, in attribute).ThrowIfFailure();
using var logical = new FileSystemServiceObjectAdapter(in serviceFs);
```

- [x] 首次逻辑open前检查该SaveDataId物理目录状态（不解析/改写NAND索引）；only1、transient `_`、非Normal返回恢复所需。0存在也先将该save的0/1/ExtraData原态安全复制并SyncTree至本地 `backups/<TitleID>/<UUID>/preopen/<SaveDataId>`，覆盖会被LibHac初始化丢弃的旧1；原态备份绝不上传、也不直接回写物理0。确认空间后才mount，导出仅committed逻辑数据。
- [x] Describe只短时持有gate，selection保存在native registry；export/restore开始时重新核验当前用户、ProgramId、索引映射及NACP不变。AuthorizeRestore只绑定合法源cloudUID到明确的localUID；记录集扩展至源manifest中的合法index，不依赖当前本机是否已创建它。
- [x] 读取真实游戏控制NACP；Library现有GameInfo不包含完整NACP，新增loader复用PFS/XCI/NCA/control读取及owned keys，不从名称推测。ApplicationId是attribute.ProgramId；NACP.SaveDataOwnerId只是creation owner，不能替代ProgramId。缺合法NACP则describe已有save可上传，创建缺失save返回错误。
- [x] `CreateExact`使用proxy.CreateSaveDataFileSystem + SaveDataCreationInfo.Make + SaveDataMetaPolicy；按Account/Device NACP size/journal/owner/flags及非零index精确创建，禁用会顺带创建BCAT/Temporary的EnsureApplicationSaveData便捷路径。用ReadExtraData记录本地大小/flags，Create/DeleteExact重新核验attribute。
- [x] 操作逻辑Fsa.IFileSystem，以1MiB循环Read/Write，CreateFile/SetSize截断，关闭所有写IFile后Commit。测试长文件变短、文件变目录、旧额外文件删除、empty dirs与原working副本保留。运行真实临时LibHac适配器测试+Core，记录platform durability限制，提交Task3。

## Task 4: Crash-Safe Multi-Save Restore and Journal Replay

**Files:** Create C# `SaveRestoreTransaction.cs`, `RestoreJournal.cs`, `DurableFileStore.cs`, `DarwinDurability.cs`, Tests `RestoreTransactionTests.cs`, `JournalRecoveryTests.cs`。

**Consumes:** ISaveRepository/SaveSelection、已完整校验本地snapshot；**Produces:** IDurableStore、RestoreOutcome、`Run/RequestSafeStop/RecoverIncomplete`。journal字段包含transactionID、selection/keys、本地原存在性/SaveDataId、所有backup路径/hash、mayHaveChanged、completed、bindingIntent与bindingApplied；fields严格本地，不上传。`RestoreJournal.WithMayHaveChanged(SaveKey) -> RestoreJournal`和`WithCompleted(BindingIntent) -> RestoreJournal`返回新immutable记录；`Encode() -> byte[]`有64KiB上界，backup文件目录列表存另一个受限manifest，避免journal超界。

- [x] 写每个mutation/durable-write/Commit前后fault injection：枚举既存keys→全部逻辑备份持久化→新建前mayHaveChanged→Commit成功但journal未更新→final completed写入→binding应用。fixture `RestoreFixture.StopAfter(point)`重启同一临时repository/journal，不能用线程取消当进程崩溃。

测试合同`RestoreFault { BeforeFirstMutation,AfterCreate,AfterFirstCommit,AfterLastCommit,AfterCompleted,AfterBinding }`；`RestoreFixture.StopAfter(RestoreFault) -> RestoreFixture`，`RunInterrupted()`模拟持久状态已写但后续指令不执行，`RestartAndRecover()`重建transaction实例，`AllLogicalHashes() -> IReadOnlyDictionary<SaveKey,string>`；`OriginalHashes`、`Binding`、`OriginalBinding`为断言值。进程级终止/重启另在Task9实际device验证。

```csharp
[Test]
public void CrashAfterCommitBeforeCompletedRollsBackAllMayHaveChanged() {
    using var f = RestoreFixture.StopAfter(RestoreFault.AfterLastCommit);
    f.RunInterrupted();
    f.RestartAndRecover();
    Assert.That(f.AllLogicalHashes(), Is.EqualTo(f.OriginalHashes));
    Assert.That(f.Binding, Is.EqualTo(f.OriginalBinding));
}
```

- [x] 观察RED。实现IDurableStore：同卷临时文件→Flush(true)→atomic rename→父目录fsync（Darwin P/Invoke open/fsync/close，返回值/errno必须核实）；SyncTree包括备份所有文件及目录。不能完成durability则在修改前失败；测试writer、rename、parent fsync各失败保存旧journal/备份。
- [x] 精确恢复流程，不只覆盖已有文件：validate全部snapshot→预估空间→备份所有受影响记录→持久journal→每record持久mayHaveChanged→CreateExact或OpenWritable→ReplaceFrom→关闭write handles→Commit。创建目标前持久记完整attribute，重启按attribute找新建ID，不能仅靠Create返回后记录ID。

```csharp
journal = journal.WithMayHaveChanged(key);
durable.WriteAtomic(journalPath, journal.Encode());
using (var save = repository.OpenWritable(key)) {
    save.ReplaceFrom(payloadRoot);
    save.Commit();
}
// Only after every record and handle finishes:
journal = journal.WithCompleted(bindingIntent);
durable.WriteAtomic(journalPath, journal.Encode());
```

- [x] 失败/未完成重启回滚全部mayHaveChanged（原存在性false则DeleteExact，true则备份精确恢复+Commit），验证rollback后的hash；回滚失败保留journal并返回rollbackRequired/blocked-game集合。completed重启不回滚，向Task7返回binding补齐意图；重复replay幂等。
- [x] 测ENOSPC、用户取消beforeMutation/afterMutation、后台截止、多个index、创建部分失败、重复恢复、原0/1原态备份可读、成功后重启不退回旧进度。跑full C#事务套件，提交Task4。

## Task 5: Bounded Native Save Jobs, Recovery Bootstrap and Swift Resource Adapter

**Files:** Create Library `SaveSync/SaveSyncNative.cs`, `SaveSyncJob.cs`; create Core `MeloNXSaveSync.h`及bridge include；create app `Common/SaveSync/NativeSaveWorker.swift`, `SaveRecoveryBootstrap.swift`; modify Library/Controller startup。Test portable `SaveJobLifetimeTests.cs`及SaveSyncCore `SaveWorkerLifetimeTests.swift`。

**Produces C ABI:**

```c
// request/result max64KiB; manifests are validated files, never huge JSON in the ABI.
void *save_sync_create(const char *request_json, char **error);
int32_t save_sync_run(void *handle); // 0 success,1 safely stopped/cancelled,2 failure,3 recovery required
char *save_sync_result(void *handle);
char *save_sync_progress(void *handle);
void save_sync_request_stop(void *handle);
void save_sync_free(void *handle); // only after Run and borrowers finish
void save_sync_string_free(char *value);
```

请求schema1字段id、operation(describe/export/restore/recover)、titleID16hex、gamePath(可选)、selectionID、snapshotRoot、bindingIntent文件路径及exportIdentity（Shared Contracts全部字段）；恢复路径仅app-owned SaveSync/staging/backup/journal allowlist。describe结果包含本机selectionID/currentUID/slot列表/control可创建性；export结果指向已验证本地game manifest，restore/recover结果文件含transactionID/completed binding意图/blocked games。ID都是定长字符串，saveDataId不进入cloud结果。

- [x] 写RED：Run once、active free拒绝、safeStop后必须等Commit/rollback结束、结果beforeEnd不可用、UTF8分配/free匹配、oversized/duplicate JSON、typed sanitized errors、borrow/free竞态。定义`HeldSaveWorker`保持真实worker lease直到confirmEnded。

C# `SaveJobFixture.BlockBeforeCommit()`提供真实`Job: SaveSyncJob`，`WaitBeforeCommit()`等待mutation barrier（5秒失败），`ReleaseCommit()`允许安全完成。SaveSyncJob合同`Run() -> int`、`RequestSafeStop() -> void`、`TryFree() -> bool`；TryFree只在Run与borrowers都结束后为true。Swift worker测试通过HeldSaveWorker直接等待confirmEnded与借用归零，不依赖尚未实现的Task7 engine。

```csharp
[Test]
public void StopRequestDoesNotFreeRunningRestoreJob() {
    using var f = SaveJobFixture.BlockBeforeCommit();
    Task<int> run = Task.Run(f.Job.Run);
    f.WaitBeforeCommit();
    f.Job.RequestSafeStop();
    Assert.That(f.Job.TryFree(), Is.False);
    f.ReleaseCommit();
    run.GetAwaiter().GetResult();
    Assert.That(f.Job.TryFree(), Is.True);
}
```
- [x] 实现owned registry与64KiB wire校验、pointer/string所有权；C入口catch所有managed异常，错误码不输出keys/opaque token。Swift dedicated queue通过Core handle lifetime pattern借用、停止poll、free native、确认真实结束后才允许owner释放gate；`NativeSaveWorker`实现Shared Contracts的SaveNativeService。
- [x] 初始化Library FSserver后、任何game/pendingJIT/package/save FS操作前执行bootstrap：读durable journals→mark blocked games→Run recover→completed事务binding补齐→unblock。恢复工作期间UI可以显示status，不能因页面先出现就开始游戏；测试cold launch/deep link/自动last-game启动都等待bootstrap。
- [x] 真实AOT/full iOS build验证exports与actor默认隔离；Core/NCA/NSZ/JIT回归套件通过。提交Task5；真实手机CABI执行仍在Task9，不以portable lifetime测试替代。

## Task 6: CloudDocuments Container, Immutable Publication and Transfer Observation

**Files:** Create app `Common/SaveSync/CloudDocumentsStore.swift`, `CloudTransferObserver.swift`, `CloudIdentityStore.swift`; SaveSyncCore Tests `CloudStoreTests.swift`。Core定义前述CloudIdentity/CloudSaveStore/CloudListing；测试用`ControlledCloudStore`实现CloudSaveStore，可按file key控制uploaded/downloaded/conflict/identityEpoch。`CloudFixture.accountAndDevice()`返回`(root: URL,snapshot: SaveSnapshot,identity: CloudIdentity)`，生成payload+两层manifest及摘要；fixture Dispose/tearDown只删自建临时root。

- [x] 写RED测试：容器nil、离线排队、Quota错误、manifest先到、部分files未上传、identity切换、NSFileVersion冲突、长reader阻塞upload（fake coordinator明确短锁退出再观察）。uploaded只在所有文件确认后产生。

```swift
func testLocalPublicationDoesNotMeanUploaded() async throws {
    let cloud = ControlledCloudStore()
    let fixture = CloudFixture.accountAndDevice()
    try await cloud.publish(localRoot: fixture.root, snapshot: fixture.snapshot, identity: fixture.identity)
    let wait = Task { try await cloud.waitUploaded(snapshot: fixture.snapshot, identity: fixture.identity) }
    await cloud.waitUntilObserving()
    XCTAssertFalse(cloud.confirmedUploaded)
    cloud.confirmAllFilesUploaded()
    try await wait.value
}
```

ControlledCloudStore的test-only合同：`waitUntilObserving() async`等候upload waiter已注册；锁保护只读`confirmedUploaded: Bool`；同步`confirmAllFilesUploaded()`设置全部file状态并resume待观察continuation。它不调用真实iCloud。

- [x] 实现container URL后台获取，使用明确identifier；url=nil为cloudUnavailable。每任务捕获opaque ubiquityIdentityToken，不能解析/上传它；本地identityUUID/token匹配信息保存在Keychain，无法安全恢复旧token时采用新identityUUID，不复用旧绑定。每次协调/观察边界复核token，退出/切换账户取消旧cloud请求。
- [x] 发布payload+record manifests至新UUID目录、游戏manifest最后；NSFileCoordinator只做短时本地copy/move/read，不能包围网络等待/循环。采用NSMetadataQuery/FilePresenter按metadata事件更新资源值，uploaded要求每个文件+清单的isUploaded且无unresolved NSFileVersion；deadline超时为queued/offline，任务不假成功。
- [x] list先枚举可见generation目录及清单，无法读取的目录保留unreadableGenerations；已知头版本请求manifest/record/payload downloads并进行全量本地验证，verified后重新评估图。列表刷新/等待有deadline、可取消，不能在Core图中靠本地文件存在标成verified。选择后download再次短协调copy到owned staging→长度/hash验证；pending后继不能退回父版，显式选版本也必须完整验证。失败保留旧本地存档、完整cloud generations，不自动delete/resolve conflicts。
- [x] 跑fake-cloud状态/图/身份测试；用真实签名手机再验上传/下载在Task9。提交Task6（逻辑测试通过并不表示真实iCloud可用）。

## Task 7: Manual Coordinator, Identity Binding and Safe Cancellation

**Files:** SaveSyncCore `SaveSyncEngine.swift`, `SaveUserBindings.swift`, `SaveSyncPhase.swift`, Tests `SaveSyncEngineTests.swift`；app `Common/SaveSync/SaveSyncCoordinator.swift`及background-task adapter。

**Consumes:** Task1 gate、Task2 graph/manifest、Task5 worker/bootstrap、Task6 CloudSaveStore。**Produces:** 前述SaveSyncEngine、SaveGameSelection、UI-ready状态/版本选择/绑定请求；SaveSyncPhase包含idle/exporting/publishing/queued/uploaded/listing/downloading/validating/awaitingRestoreConfirmation/restoring/finishing/recoveryRequired/failed/cancelled。

`SaveEngineFixture.heldRestore()`为测试提供已prepare/confirm的engine、同一gate和HeldSaveWorker；`beginRestore() -> Task<Void,Never>`启动恢复，`waitUntilNativeMutation() async`等候fake mutation barrier，`worker.finish(status:)`只有在释放barrier后报告线程已结束。`SaveSyncPhase`是无关联值的Equatable enum，进度/typed error单独存viewmodel，保持phase测试稳定。

- [x] 写held-worker/cloud测试：只选game捕获current-user描述；upload稳定快照后释放local gate但cloud观察继续；restore开始前可取消；修改后取消只能安全结束；页面关闭/后台/身份切换不释放运行中worker；foreign generation不能改本地。

```swift
@MainActor func testCancelDuringRestoreKeepsLeaseUntilWorkerEnds() async throws {
    let f = SaveEngineFixture.heldRestore()
    let task = f.beginRestore()
    await f.waitUntilNativeMutation()
    f.engine.cancel()
    XCTAssertEqual(f.engine.phase, .finishing)
    XCTAssertTrue(f.gate.busy)
    f.worker.finish(status: .safelyStopped)
    await task.value
    XCTAssertFalse(f.gate.busy)
}
```
- [x] 实现本地bindings键`(localCloudAccountUUID,container,titleID,localUID)`→`(cloudUID,lastGeneration)`，upload读取localUID但使用cloudUID路径/manifest/parent。无匹配且唯一其他cloudUID时提供明确绑定确认；多用户歧义不猜测。Device user=shared。绑定意图写入Task4 journal，仅completed后应用，幂等重启补齐。

绑定写入沿用同卷临时文件、文件同步、atomic rename和parent fsync，返回值失败不得将bindingApplied/成功状态提前落盘。completed本地事务的binding修复不访问云端账户；即使当前已切换账户也只补齐journal原账户键并等待用户开启新任务。回滚失败的恢复工具提供重试journal rollback入口，不增添删除备份或强行解锁启动按钮。

```swift
// upload body: game/ownedRoot/installationID are engine inputs;
// gate/native/cloud/bindings are the injected Shared Contracts instances.
let identity = try await cloud.identity()
let lease = try gate.acquire(.saveExport, gameID: game.titleID)
let current = try await native.describe(game)
let key = SaveBindingKey(localCloudAccountUUID: identity.localAccountKey,
    container: identity.container, titleID: game.titleID, localUID: current.localUserID)
let binding = try bindings.read(key: key)
let generation = UUID()
let exportIdentity = SaveExportIdentity(cloudUserID: binding?.cloudUID ?? current.localUserID,
    parent: binding?.lastGeneration, generation: generation, installationID: installationID,
    createdUTC: ISO8601DateFormatter().string(from: Date()))
let root = ownedRoot.appendingPathComponent("staging/\(generation.uuidString)")
let snapshot = try await native.export(current, identity: exportIdentity, into: root)
let ended = await native.confirmEnded()
try lease.finish(workerHasEnded: ended)
try await cloud.publish(localRoot: snapshot.localRoot, snapshot: snapshot.manifest, identity: identity)
try await cloud.waitUploaded(snapshot: snapshot.manifest, identity: identity)
guard try await cloud.identity() == identity else { throw SaveSyncError.identityMismatch }
try bindings.recordUploaded(key: key, cloudUID: exportIdentity.cloudUserID, generation: generation)
```

此成功路径配套do/catch：describe/export抛错仍等待confirmEnded，再结束lease；若未结束进入finishing并保留lease，不能靠defer释放。发布/观察失败不推进binding parent。Task2定义`SaveSyncError: Error` cases `noSave,busy,cloudUnavailable,queued,quota,incompleteSnapshot,conflict,identityMismatch,malformedSnapshot,restoreFailed,rollbackRequired`；错误展示在Task8。Task7给SaveExportIdentity/public result structs提供同成员public initializer，installationID是app首次运行生成并持久保存的UUID。

- [x] 恢复确认先展示选择的generation/当前用户/将生成备份；user按恢复后取得独占lease→完整验证→native事务；background task expiration只requestSafeStop，不终止Commit/rollback。有限时间无法完成则journal/recoveryRequired保持blocked state，冷启动bootstrap replay。UI成功只能跟随nativecompleted+bindings持久化，不能跟随下载结束。
- [x] 测最后Commit/completed/绑定间三个中断顺序、旧账户完成消息不能污染新账户、冲突保留版本、未提交working数据不可上传、queued可重连观察但不自动再导出新进度。Core全套通过，提交Task7。

## Task 8: Game-Only Manual UI and Meaningful Failure States

**Files:** Create `src/MeloNX/MeloNX/UI/Main/SaveSync/GameSaveSyncView.swift`, `CloudSaveVersionsView.swift`, `SaveRestoreConfirmation.swift`（后两者同目录）；modify `src/MeloNX/MeloNX/UI/Main/GamesList/Elements/GameInfoSheet.swift`, `src/MeloNX/MeloNX/UI/Main/GamesList/GamesListView.swift`, `src/MeloNX/MeloNX/UI/Main/Settings/SettingsView.swift`, `src/MeloNX/MeloNX/UI/Main/ContentView.swift`。修改既有ScopeLease入口只在真实需要时提取共有接口，不展开其他格式功能。

- [x] 写UI-viewmodel测试：游戏选择→自动current-user→手动upload/download；没有文件或文件夹picker；noSave/busy/offline/quota/conflict/identityMismatch/rollbackRequired各有独立可操作反馈。正常唯一最新无需版本picker，冲突/foreign UID仅异常时显式选择。

Core新增`SaveSyncPresentation`合同`init(phase: SaveSyncPhase,error: SaveSyncError?)`，只读`canRetry: Bool,showsVersionChoice: Bool`，文案资源放app。以此测试恢复安全结束阶段；没有picker及真正按钮/tap/scene行为由后续真实UI gate验证，不能用一个恒定false的属性代替交互证据。

```swift
func testFinishingCannotExposeImmediateRetry() {
    let view = SaveSyncPresentation(phase: .finishing, error: nil)
    XCTAssertFalse(view.canRetry)
}
```
- [x] 游戏详情/菜单加入“iCloud 存档”；设置入口列已安装games供选择。停止并保存提示不能用pause按钮代替退出native线程。禁用重复任务按钮，finishing不能再按立即重试；恢复confirmation显示备份与替换说明，cloud成功文案只用uploaded状态。
- [ ] 用已知fake adapter的Debug UI只检查布局和interaction，不宣称云端/游戏验收；真实用户save验证在Task9。检查小屏/横屏/VoiceOver基本可用，保留现主题/英文产品文本风格，Native真实进度不带API/handle实现细节。
- [ ] 跑SaveSyncCore/OperationCore/ImportCore/JITCore及full iOS build；记录实际手机图像/互动证据，有设备断开则该UI gate保持未验收。提交Task8源文件。

## Task 9: Capability, Signing and Two-Device Real Save Acceptance

**Files:** modify `src/MeloNX/MeloNX/MeloNX.entitlements`, `src/MeloNX/MeloNX/Info.plist`, `src/MeloNX/MeloNX.xcodeproj/project.pbxproj`；create `distribution/ios/verify-save-sync-signing.sh`, `tests/ios/save-sync/README.md`和公开测试snapshot fixture清单。helper沿用原有权限，禁止把iCloud entitlement额外加给JIThelper。

- [x] 先只读核对实际开发团队KWP42AEP6Q是否授权CloudDocuments/container及已登录凭据，列明将改的com.hick.MeloNX App ID和container。沿任务已授权功能启用现有团队capability、关联iCloud.com.hick.MeloNX并生成新development profile；若权限/凭据缺失只记录确切阻塞和最小账号动作，继续完成本地测试，不购买服务/空间或切换团队。
- [x] host最小实际entitlement由Xcode/官方配置生成：CloudDocuments service、ubiquity-container-identifiers及对应iCloud-container-identifiers只用授权identifier；不为了文档同步开CloudKit数据库。Info `NSUbiquitousContainers`显示名称MeloNX、document scope/subfolder配置。签名verify比较embedded profile允许值与codesign实际entitlements；保持get-task-allow/increased-memory及既有bundle ID。
- [ ] 外部缓存/AOT/full app/helper build；全部单位/事务/临时LibHac集成通过。签名deep strict校验、LICENSE包含、NSZ生产exports保持、Release不含测试probe。先抓设备Documents元数据后原位更新，不卸载、不清NAND；devices目标hick及同iCloud第二设备，不在线不声明验收。
- [ ] 实际游戏先在游戏内保存退出，再上传；观察所有cloud文件isUploaded、第二设备完全下载/hash一致、仅该游戏Account+Device记录；断网queued、quota错误、身份切换、双设备分支冲突实测。无真实存档样本则该gate未完成，不把假目录当游戏进度。
- [ ] 第二设备合法local mapping可不同SaveDataId；恢复前备份，实际游戏启动确认进度；测试未完成journal重启回滚与completed只补绑定。再次核对keys/固件/其他游戏/原存档备份保留，并确认NSZ导入/启动gate及JIT绿色状态未回归。
- [x] 以一次最强模型 fresh-context reviewer检查整分支/不可信manifest、transaction durability、cloud propagation、UI资源寿命；仅一次作者实质修复，每项RED→GREEN并运行影响套件。保留真实proof、commit、未验收项；没有merge/push/publication请求。

## Commands, Ownership and Handoff

工作于现有外部linked worktree；计划获批后另建feature分支隔离iCloud修改，保留70884d713及NSZ workspace，不清理它。iCloud计划只使用自己的 `.superpowers/sdd/2026-10-11-icloud-save-sync/` ledger，不能借用NSZ ledger标成完成。Native任务逐个执行，不在任务间重复确认继续；已知设备/cloud凭据阻塞时推进独立本地工作。

dotnet：先 `restore --configfile /Volumes/untitled/github/MeloNX/.local/nuget-build.config`，后 `test src/Ryujinx.SaveSync.Tests --no-restore --disable-build-servers`；sdk `/Volumes/untitled/github/MeloNX/.local/build-tools/dotnet10/dotnet`，DOTNET_CLI_HOME/NUGET_PACKAGES/TMPDIR均沿外部路径。不把NuGet --configfile传给test。

Swift：`swift test --package-path src/MeloNX/MeloNXOperationCore`、`.../MeloNXSaveSyncCore`、现有ImportCore/JITCore；缓存/临时目录外部。Xcode沿现有MeloNXBuild/swift-packages及com.hick.MeloNX override，Legacy target保留env0并显式传configuration，不重引已验证的env-forwarding错误。

可执行基础测试命令（在linked worktree root运行；新测试项目建成后运行，不把计划中的预期结果当执行结果）：

```bash
export DOTNET_CLI_HOME=/Volumes/untitled/github/MeloNX/.local/build-tools/dotnet-cli
export NUGET_PACKAGES=/Volumes/untitled/github/MeloNX/.local/nuget
export NUGET_HTTP_CACHE_PATH=/Volumes/untitled/github/MeloNX/.local/nuget-http
export TMPDIR=/Volumes/untitled/github/MeloNX/.local/tmp
export MSBUILDDISABLENODEREUSE=1
export DOTNET_CLI_USE_MSBUILD_SERVER=0
/Volumes/untitled/github/MeloNX/.local/build-tools/dotnet10/dotnet restore src/Ryujinx.SaveSync.Tests --configfile /Volumes/untitled/github/MeloNX/.local/nuget-build.config
/Volumes/untitled/github/MeloNX/.local/build-tools/dotnet10/dotnet test src/Ryujinx.SaveSync.Tests --no-restore --disable-build-servers -m:2 -p:UseSharedCompilation=false
swift test --package-path src/MeloNX/MeloNXOperationCore
swift test --package-path src/MeloNX/MeloNXSaveSyncCore
swift test --package-path src/MeloNX/MeloNXImportCore
swift test --package-path src/MeloNX/MeloNXJITCore
```

Task9读取实际签名/profile的基础命令（app变量指定本次外部build candidate，不能误指旧NSZ candidate）：

```bash
codesign --verify --deep --strict "$save_sync_candidate_app"
codesign -d --entitlements :- "$save_sync_candidate_app"
security cms -D -i "$save_sync_candidate_app/embedded.mobileprovision"
```

signing verifier解析profile与实际entitlements，仅报告allowed identifier/service匹配、get-task-allow/increased-memory布尔及签名结果；不要将profile的其他敏感字段原样记录到proof。真机proof记录操作/进程结束/当前cloud generation/匿名安装UUID/摘要/实际结果，不包含存档内容、账户token或keys。

验收顺序：纯模型/故障注入→真实临时LibHac逻辑FS→iOS AOT/签名→实际iCloud两设备→真实游戏进度。任何前层通过不能替代后层。当前手机连接、第二设备账户及游戏/存档样本未提供；这些是实际验证前置条件，不是停止写计划或后续本地实现的理由。

## Author Plan Self-Review (2026-10-11)

- Spec coverage：游戏-only手动流程Task7/8；完整目录/schema及传播图Task2/6；合法存档映射/NACP/多index Task3；跨记录备份与持久恢复Task4/5；所有启动和worker生命周期Task1/5/7；身份绑定与上传parent Task7；签名/两设备/真实进度Task9。没有把NSZ未完成真机项目标成完成。
- Placeholder scan：删除未定义展示helper及schema占位，明确record与game清单分工；fixture、NativeService、journal、binding签名写入合同。
- Type consistency：VisibleSnapshot/CloudListing的可用状态不写入wire，缺manifest的generation单独阻止默认父版；gamePath/native selection分开；Task7调用Task5实际定义的export/confirmEnded，binding使用原账户/localUID及源cloudUID。
- Review Focus：五种风险逐一绑定Task1/2/3/4/5/7故障测试，Task9负责真实进程/设备/cloud再验。计划自审不等于产品测试通过；本阶段没有运行未存在的SaveSync测试或修改账户。

## Official and Source Evidence

- Apple [Configuring iCloud services](https://developer.apple.com/documentation/xcode/configuring-icloud-services)；[container access](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29)；[upload confirmation and observer guidance](https://developer.apple.com/documentation/foundation/urlresourcekey/ubiquitousitemisuploadedkey)；[download requests](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29)。
- Repo `Library.cs` initializer、`LibHacHorizonManager.RyujinxClient`、Account.UserId.ToLibHac；外部精确LibHac源 `Fs/Shim/SaveDataManagement.cs`（iterator/create/delete）、`Fs/Shim/SaveData.cs`（真实Fs.UserId版本）、`FsSrv/Sf/IFileSystemProxy.cs`、`FsSystem/DirectorySaveDataFileSystem.cs`（Initialize修复、Commit写句柄条件）。
- 不调用 `LibHac.Fs.SaveData.MountSaveData(...LibHac.Account.Uid)` stub；不把NACP.SaveDataOwnerId误当attribute.ProgramId。此证据来自只读源码核对，非已执行的用户存档恢复试验。

## Verification checkpoint after sole final review

2026-10-11：一次独立整分支审查完成，8项Important作者修复已提交edd6c14f9；保存/恢复 .NET57、Swift48均实际通过，签名服务wildcard测试及旧候选实际entitlement/profile检查通过。外置盘AppleDouble源文件/项目元数据问题由d309730a7/ee8d88fca修正，最终Debug全量iOS/AOT签名构建及最新候选实际profile/entitlement检查已通过；7个save exports和NSZ生产exports存在，LICENSE文件保留。外部候选 `.local/build-tools/icloud-install-candidate-ee8d88fca` 含源commit和二进制摘要，130163892字节。Release全量签名构建也已通过；生产exports保留、测试probe实际不存在，host/helper/profile签名均通过。签名helper枚举忽略外置盘普通AppleDouble文件，拒绝符号链接/异常bundle。另存Release候选 `.local/build-tools/icloud-release-candidate-ee8d88fca`。

Task8实机布局/点击/横屏/VoiceOver仍未验收。hick手机从可用转为paired但tunnel unavailable（CoreDevice4016），已请求连接解锁；真实游戏样本和同一iCloud第二设备仍未提供。Task9真实云上传、两设备下载/恢复、游戏内进度、离线/配额/冲突及新包JIT/NSZ实机回归均保持未验收。没有卸载应用、清理NAND或向云端写游戏存档。

上传恢复细节已按审查修复：云端发布前持久化prepared receipt，发布中断重启恢复同一个UUID且只接受相同不可变文件；完成恢复后通过持久化的restore provenance退役旧queued receipt，下一次上传使用已恢复版本作parent。设备阻塞经CoreDevice4016和USBmux目标缺失双重确认，源构建成功不代替安装/实机验收。
