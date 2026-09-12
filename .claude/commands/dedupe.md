---
description: 盘点重复的 UI/逻辑样板代码，抽取成带显式参数的共享组件，并验证行为等价
argument-hint: [范围，如 ios/RinaBoard/Features/Text 或 "LEDBoardPreview 的调用点"；留空=整个 iOS target]
---

# 复用性检查与精简

范围：$ARGUMENTS
（留空则扫描 `ios/RinaBoard/` 整个 app target。）

按下面四个阶段走。**阶段 1 结束后停下来，把清单给我确认再动手**，除非我在范围里写了 `--auto`。

---

## 阶段 1 · 盘点（只读，一个文件都不要改）

找出这四类重复，每一类都要给 `文件:行` 和重复次数：

1. **同一组件 + 同一串 modifier**：一个共享 View 被多处调用，而每个调用点后面都跟着逐字相同的修饰链（`.listRowInsets(EdgeInsets())`、`.listRowBackground(Color.clear)`、固定 `.frame(width:height:)`、同样的 `clipShape`）。
2. **重复的依赖声明**：同一个 `@AppStorage` / `@Environment` 在多个 View 里各声明一遍，而它**只**为同一个子组件服务。
3. **重复的参数推导**：同一段取值表达式散落多处（例如 `Color(hex: controlCenter.colorHexDraft) ?? .rinaPink`、`Int(controlCenter.brightnessDraft)`）。
4. **重复的魔数**：同样的尺寸 / 圆角 / 间距字面量出现在多个调用点（例如 `44×36`、`cornerRadius: 6`、`maxHeight: 420`）。

判定门槛，不要越线：
- **≥3 处逐字重复** → 值得抽取。
- **2 处** → 只有在两处完全没有差异、且它们表达的是同一个概念时才抽。
- **1 处** → 不抽。"以后可能会用到"不是理由。
- 形状不同的重复（整板预览 vs 小缩略图）算**两个**候选，不要硬塞进同一个组件。

每个候选输出：重复了什么 / 哪些部分逐字相同 / 哪些部分每处不同（这些是留在调用点的） / 建议抽还是不抽 + 一句理由。

---

## 阶段 2 · 设计抽取

- **划分归属**：调用点只应该说明「显示什么数据」和「行为开关」；布局、insets、全局取值来源、尺寸常量归共享件。每个调用点都不一样的东西（`header` / `footer`、`.bootReveal(index:)`、导航目的地）必须留在调用点。
- **把隐式约定改成显式参数**。`onToggle: ((Int) -> Void)? = nil` 这种「传 nil 就代表不可点」的写法，读代码时看不出意图；换成命名清楚的类型：
  ```swift
  enum LEDBoardInteraction {
      case inert                      // 纯展示，点击穿透到下层
      case editable((Int) -> Void)    // 点中 LED 回报 logical index
  }
  ```
- **可选覆盖用 `nil` 表示"跟随全局"**：`var color: Color? = nil` → nil 时取全局草稿值，需要时显式传参覆盖。
- **禁止投机参数**：没有任何现有调用点会用到的参数、enum case、配置项，一律不加。
- **SwiftUI 陷阱自查**：`listRow*` / `listSectionSeparator` 等只在 List row 上生效的修饰符，被包进自定义 View 的 body 之后是否还绑定到行上；`@Environment` 依赖是否在所有调用点（含 Xcode Preview）都存在；把共享件所在文件里**只服务于它**的 helper（尺寸 modifier 等）一并移过去，让"预览窗代码"真的只有一个位置。

---

## 阶段 3 · 修改

- 一次只处理一类重复，改完一类再开下一类。
- **严格行为等价**。任何视觉或行为变化都必须先说出来让我决定，不要顺手"改好"：某个调用点原本用的是硬编码色值而不是全局色值，就显式传参把它保持原样，并在报告里单独列出来。
- 抽取完顺手清掉因此变成死代码的 `@AppStorage` / `@Environment` / 私有常量 / 私有 enum —— 但只清跟这次抽取相关的，别顺带重构别的东西。
- 不改本地化字符串的 key 和内容。

---

## 阶段 4 · 验证

```bash
cd ios && xcodebuild -project RinaBoard.xcodeproj -scheme RinaBoard -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|warning:" | sort -u
```

1. build 必须 **0 error 0 warning**。
2. grep 确认旧写法没有残留（老参数名、被移走的 helper 的旧调用、已删除的属性）。
3. 装到已启动的模拟器上，逐个 tab 截图，跟改动前肉眼对比：
   ```bash
   xcrun simctl install booted <APP_PATH> && xcrun simctl launch booted com.rinachan.board -initialTab control
   xcrun simctl io booted screenshot /tmp/tab-control.png
   ```
4. 交互路径若无法用自动化点击验证，**如实说明这一项没验到**，不要含糊带过。

---

## 输出

最后给我：

| | |
|---|---|
| 统一了什么 | 新共享件的路径 + 消掉的重复行数 |
| 新增的参数 | 每个参数一句话：为什么它是参数而不是写死 |
| 故意没动 | 候选清单里被判定"不抽"的项 + 理由 |
| 行为变化 | 有就列，没有就写"无" |
| 验证 | build 结果、截图了哪几个屏、哪些没验到 |

按我的 model routing 规则来：阶段 1 的盘点交给 `scout`（可并行按目录切分），阶段 3 的机械改动交给 `implementer`，阶段 4 完成后用 `reviewer` 做一次独立 diff 复查（不能是实现者自己）。
