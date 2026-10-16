# 联合复审证据

基线：c3a64ed + 2026-10-15 当前未提交板端表情保存改动。主报告：../../FUNCTION_INTERFACE_JOINT_REAUDIT_2026_10_15_ZH.md。

`probe-main.swift` 调用当前生产 MultiBoardFaceSaveCoordinator；`probe-stubs.swift` 提供没有无线/硬件副作用的依赖。真实 DraftStorage 写入独立随机临时目录，结束删除该目录。假表情库模拟同 ID 被他端改变，触发 production conflict 分支。sameBoard 函数直接从生产源提取，不重写逻辑。它不代替完整 App 测试或 UI/硬件复现。

当次输出见 probe-output.txt。源取证开始/结束的360个源文件指纹未变，排序指纹清单摘要：d6bd1affce794b2b2d3358f9ca3fab565c2b7605516182bb32037909056de5a2。

复现方式（macOS，仓库根目录，所有产物写 /tmp）：

```bash
mkdir -p /tmp/rina-reaudit-20261015
CLANG_MODULE_CACHE_PATH=/tmp/rina-reaudit-20261015/clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/tmp/rina-reaudit-20261015/module-cache swift build --disable-sandbox --package-path ios/Packages/RinaCore --scratch-path /tmp/rina-reaudit-20261015/swift-build
python3 - <<'PY'
from pathlib import Path
source = Path('ios/RinaBoard/Features/Faces/MultiBoardFaceSaveCoordinator.swift').read_text()
Path('/tmp/rina-reaudit-20261015/production-coordinator.swift').write_text('import Observation\n' + source)
source = Path('ios/RinaBoard/Features/Faces/FaceLibraryModel.swift').read_text()
start = source.index('    nonisolated static func sameBoard(')
end = source.index('\n    }', start) + 6
Path('/tmp/rina-reaudit-20261015/production-identity.swift').write_text('import Foundation\nenum ProductionIdentity {\n' + source[start:end] + '\n}\n')
PY
CLANG_MODULE_CACHE_PATH=/tmp/rina-reaudit-20261015/clang-cache swiftc -parse-as-library -I /tmp/rina-reaudit-20261015/swift-build/out/Products/Debug -L /tmp/rina-reaudit-20261015/swift-build/out/Products/Debug -lRinaCore ios/RinaBoard/Services/DraftStorage.swift docs/audits/2026-10-15-joint-reaudit/probe-stubs.swift /tmp/rina-reaudit-20261015/production-coordinator.swift /tmp/rina-reaudit-20261015/production-identity.swift docs/audits/2026-10-15-joint-reaudit/probe-main.swift -o /tmp/rina-reaudit-20261015/probe
/tmp/rina-reaudit-20261015/probe
```

RinaCore 产物目录取决于本机 SwiftPM 后端；本次为 out/Products/Debug。若目录不同，以本机生成的 RinaCore.swiftmodule 与 libRinaCore.a 所在目录为准。受限执行器中的 Swift 宏编译可能需要其正常系统服务权限。

R4附加探针：`python3 docs/audits/2026-10-15-joint-reaudit/default-rename-probe.py`。运行原有faces_transfer host harness，并仅在临时生成的C++末尾加入默认项改名行为断言；既有生产源/测试不改动。结果见default-rename-output.txt。
