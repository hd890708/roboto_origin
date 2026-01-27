# roboto_origin 同步脚本维护文档

本文档用于指导后续 AI Agent 理解和维护 `sync_subtrees.sh` 脚本。

---

## 1. 背景和设计目标

### 1.1 仓库结构

```
roboto_origin/                    # 本仓库（聚合仓库）
├── modules/
│   ├── Atom01_hardware/          # 主模块 1（subtree，无 squash）
│   ├── atom01_deploy/            # 主模块 2（subtree，无 squash）
│   │   ├── inference/            # 子模块（subtree，有 squash）
│   │   ├── motors/               # 子模块（subtree，有 squash）
│   │   ├── imu/                  # 子模块（subtree，有 squash）
│   │   └── create_ap/            # 子模块（subtree，有 squash）
│   ├── atom01_train/             # 主模块 3（subtree，无 squash）
│   │   ├── robolab/              # 子模块（subtree，有 squash）
│   │   └── rsl_rl/               # 子模块（subtree，有 squash）
│   └── atom01_description/       # 主模块 4（subtree，无 squash）
├── .scripts/
│   ├── sync_subtrees.sh          # 同步脚本
│   └── README.md                 # 本文档
└── .gitignore                    # 忽略 .scripts/ 目录
```

### 1.2 核心设计原则

1. **完整快照**：本仓库必须包含所有模块的完整代码，不能依赖 submodule
2. **无 submodule 依赖**：根目录不能有 `.gitmodules`，用户不需要 `git submodule init`
3. **历史保留策略**：
   - **主模块**：使用 subtree **不使用** `--squash`，保留完整历史
   - **子模块**：使用 subtree **必须使用** `--squash`，节省空间
4. **远程不变原则**：不修改任何远程仓库，只在本仓库聚合
5. **一键同步**：通过一个脚本完成所有模块的同步
6. **自动冲突解决**：脚本应能自动处理 gitlink 冲突，无需人工干预

---

## 2. 技术架构

### 2.1 为什么使用 Subtree 而不是 Submodule？

| 特性 | Submodule | Subtree（本方案） |
|------|-----------|------------------|
| 初始化 | 需要 `git submodule init` | 无需初始化 |
| 克隆 | 需要 `--recursive` | 正常克隆即可 |
| 依赖 | 引用外部仓库 | 完整代码在本地 |
| 历史记录 | 独立历史 | 聚合历史 |
| 提交 | 需要手动进入子目录提交 | 直接提交 |
| .git 大小 | 较小 | 较大（通过 squash 控制） |

### 2.2 Gitlink 冲突问题

**问题描述**：

部分主模块的远程仓库包含 submodule（gitlink，mode 160000）：
- `atom01_train`: robolab, rsl_rl
- `atom01_deploy`: inference, motors, imu, create_ap

本仓库将这些 submodule 转换为 subtree（普通目录，mode 40000）。

**实际情况**：
- `atom01_train`: 每次拉取都会产生 gitlink 冲突，需要特殊处理
- `atom01_deploy`: 通常不会产生冲突，子模块可正常拉取

**解决策略（针对 atom01_train）**：
1. 检测到 `.gitmodules` 文件时，准备处理冲突
2. 冲突发生时，删除 gitlink 目录和冲突标记文件
3. 恢复 `.gitmodules` 文件（用于脚本自动发现子模块）
4. 完成合并提交
5. 在第二阶段将子模块作为 subtree 重新拉取

---

## 3. 脚本工作流程

### 3.1 第一阶段：同步主模块

```
遍历 MAIN_MODULES 数组
  ↓
检查模块目录是否存在
  ↓
不存在 → git subtree add
  ↓
存在 → git subtree pull
  ↓
[特殊处理] atom01_train + .gitmodules
  ↓
检测是否有冲突
  ├─ 无冲突 → 检查 .gitmodules 是否被清空，如有则恢复
  └─ 有冲突 → 自动解决：
      1. 删除带 ~ 标记的冲突目录
      2. 删除 robolab 和 rsl_rl 的 gitlink 目录
      3. 恢复 .gitmodules 内容
      4. git add .gitmodules
      5. git commit 完成合并
```

### 3.2 第二阶段：同步子模块

```
遍历所有主模块
  ↓
检查是否存在 .gitmodules
  ↓
解析 .gitmodules 文件
  ├─ 提取 submodule 名称
  ├─ 提取 path（相对路径）
  └─ 提取 url
  ↓
对每个子模块：
  ↓
自动检测默认分支（git ls-remote --symref）
  ↓
检查子模块目录状态
  ├─ 不存在 → git subtree add --squash
  ├─ 存在但为空 → 删除空目录，重新 add
  └─ 存在有内容 → git subtree pull --squash
```

---

## 4. 核心代码解析

### 4.1 主模块拉取逻辑

```bash
if [ ! -d "$module_path" ]; then
    # 首次添加：不使用 squash
    git subtree add --prefix="$module_path" "$module_url" "$module_branch"
else
    # 更新：不使用 squash
    git subtree pull --prefix="$module_path" "$module_url" "$module_branch"
fi
```

**关键点**：
- 主模块必须保留完整历史，不使用 `--squash`
- 这样可以追溯每个模块的完整开发历史

### 4.2 atom01_train 冲突处理

```bash
if [ "$module_name" = "atom01_train" ] && [ -f "$module_path/.gitmodules" ]; then
    # 保存 .gitmodules 内容
    gitmodules_backup=$(cat "$module_path/.gitmodules" 2>/dev/null || echo "")

    # 尝试拉取，并捕获输出
    if ! git subtree pull ... 2>&1 | tee /tmp/subtree_output.txt | grep -q "CONFLICT"; then
        # 无冲突：检查 .gitmodules 是否被清空
        if [ ! -s "$module_path/.gitmodules" ]; then
            echo "$gitmodules_backup" > "$module_path/.gitmodules"
            git add "$module_path/.gitmodules"
            git commit --amend --no-edit
        fi
    else
        # 有冲突：自动解决
        find "$module_path" -maxdepth 1 -type d -name "*~*" | while read dir; do
            rm -rf "$dir"  # 删除冲突标记目录
        done
        git rm -rf "$module_path/robolab" "$module_path/rsl_rl"  # 删除 gitlink
        echo "$gitmodules_backup" > "$module_path/.gitmodules"  # 恢复配置
        git add "$module_path/.gitmodules"
        git commit -m "Merge $module_name (保留 .gitmodules)"
    fi
fi
```

**关键点**：
1. 必须在拉取前保存 `.gitmodules`
2. 使用 `tee` 保存输出以便检测冲突
3. 删除所有带 `~` 后缀的冲突目录
4. 使用 `git rm` 删除 gitlink 目录
5. 恢复 `.gitmodules` 并提交

### 4.3 子模块自动拉取

```bash
sync_one_submodule() {
    local submodule_branch=$(get_default_branch "$submodule_url")

    if [ ! -d "$full_submodule_path" ]; then
        git subtree add --prefix="$full_submodule_path" "$submodule_url" "$submodule_branch" --squash
    elif [ -z "$(ls -A "$full_submodule_path" 2>/dev/null)" ]; then
        # 目录为空：删除并重新添加
        rmdir "$full_submodule_path"
        git subtree add --prefix="$full_submodule_path" "$submodule_url" "$submodule_branch" --squash
    else
        git subtree pull --prefix="$full_submodule_path" "$submodule_url" "$submodule_branch" --squash
    fi
}
```

**关键点**：
- 子模块必须使用 `--squash` 压缩历史
- 自动检测默认分支，不需要硬编码
- 处理空目录的边界情况

### 4.4 默认分支检测

```bash
get_default_branch() {
    local repo_url="$1"
    local output=$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null)
    local default_branch=$(echo "$output" | grep '^ref:' | sed 's/^ref: refs\/heads\///' | awk '{print $1}')
    echo "$default_branch"
}
```

**关键点**：
- 使用 `--symref` 获取符号引用
- 兼容 main 和 master 分支
- 失败时返回错误码

---

## 5. 常见问题和处理原则

### 5.1 Gitlink 冲突

**症状**：
```
CONFLICT (modify/delete): modules/atom01_train/robolab deleted in HEAD and modified in <commit>
Automatic merge failed; fix conflicts and then commit the result.
```

**处理原则**：
1. 不要修改远程仓库
2. 删除本地冲突的 gitlink 目录
3. 保留 `.gitmodules` 文件（供脚本使用）
4. 完成合并提交
5. 后续在第二阶段将子模块作为 subtree 拉取

### 5.2 .gitmodules 被清空

**症状**：`.gitmodules` 文件存在但大小为 0 字节

**原因**：Git 合并时可能清空文件

**处理原则**：
1. 在拉取前保存内容到变量
2. 拉取后检查文件大小
3. 如果为空，从备份恢复
4. 使用 `git commit --amend` 修改合并提交

### 5.3 冲突标记文件残留

**症状**：存在 `robolab~<commit_hash>` 格式的目录

**原因**：Git 创建冲突标记但未删除

**处理原则**：
1. 使用 `find` 查找所有带 `~` 的目录
2. 使用 `rm -rf` 删除
3. 确保在 `git add` 之前删除

### 5.4 合并未完成

**症状**：`git status` 显示 "Unmerged paths"
```
DU modules/atom01_train/robolab
DU modules/atom01_train/rsl_rl
```

**处理原则**：
1. `git rm -rf` 删除冲突路径
2. `git add` 添加需要的文件（如 .gitmodules）
3. `git commit` 完成合并
4. 脚本必须确保退出前完成合并

### 5.5 空目录问题

**症状**：子模块目录存在但为空

**原因**：之前的操作失败留下空目录

**处理原则**：
1. 检测目录是否为空（`ls -A`）
2. 使用 `rmdir` 删除空目录
3. 重新执行 `git subtree add`

### 5.6 工作目录错误

**症状**：`fatal: not a tree` 或路径错误

**原因**：脚本在错误的目录执行

**处理原则**：
1. 脚本必须切换到仓库根目录
2. 使用 `REPO_DIR=$(dirname "$SCRIPT_DIR")` 获取根目录
3. 在脚本开头执行 `cd "$REPO_DIR"`

---

## 6. 修复脚本时的指导原则

### 6.1 核心原则

1. **最小修改原则**：只修改问题相关的部分，不重构无关代码
2. **保持向后兼容**：不要改变主模块配置或子模块 URL
3. **错误处理原则**：
   - 预期错误：使用 `set -e` 让脚本在错误时退出
   - 非预期错误：不要捕获，让脚本失败以便调试
   - 禁止使用 `|| true` 掩盖错误
4. **自动化优先**：脚本应能自动完成所有操作，无需人工干预
5. **日志清晰**：使用颜色和结构化日志，便于调试

### 6.2 诊断流程

当用户报告脚本问题时，按以下步骤诊断：

1. **检查 git 状态**
   ```bash
   git status
   ```
   看是否有未合并的路径或冲突

2. **检查最近的提交**
   ```bash
   git log --oneline -10
   ```
   看是否有合并提交异常

3. **检查 .gitmodules 状态**
   ```bash
   cat modules/atom01_train/.gitmodules
   ls -la modules/atom01_train/
   ```
   看配置文件和目录状态

4. **检查子模块状态**
   ```bash
   git ls-files -s modules/atom01_train/robolab
   ```
   看文件模式（160000 表示 gitlink，40000 表示普通目录）

5. **手动测试命令**
   ```bash
   git subtree pull --prefix=modules/atom01_train https://github.com/Roboparty/atom01_train.git main
   ```
   看是否能重现问题

### 6.3 修复步骤

1. **回档到干净状态**
   ```bash
   git reset --hard origin/main
   ```

2. **应用修复**
   - 编辑 `.scripts/sync_subtrees.sh`
   - 更新永久备份：`cp .scripts/sync_subtrees.sh /tmp/sync_subtrees_permanent_backup.sh`

3. **测试修复**
   - 运行脚本：`./.scripts/sync_subtrees.sh`
   - 检查是否自动完成所有同步
   - 验证 git 状态是否干净

4. **验证结果**
   ```bash
   git status          # 应该干净或只有预期修改
   git log --oneline -5  # 检查提交记录
   ```

### 6.4 测试清单

修复脚本后，验证以下内容：

- [ ] 四个主模块都成功同步
- [ ] atom01_train 的冲突自动解决
- [ ] .gitmodules 文件保留且内容正确
- [ ] 所有子模块成功拉取（robolab, rsl_rl, motors, imu, inference, create_ap）
- [ ] 无未合并的路径残留
- [ ] 无冲突标记文件残留
- [ ] 提交历史清晰（有 "Merge" 提交）
- [ ] 脚本正常退出（exit code 0）

---

## 7. 同步日志规范

### 7.1 日志记录要求

**每次执行同步操作后，必须编写日志**，无论是否遇到问题。日志用于：

1. 问题追溯：当同步出现异常时，可以通过历史日志了解类似问题的解决方案
2. 维护交接：让其他 AI Agent 或维护者快速了解项目同步历史
3. 经验积累：记录常见问题和解决模式，优化脚本

### 7.2 日志存放位置

所有同步日志存放在：`.scripts/logs/` 目录

### 7.3 日志编写时机

以下情况必须编写日志：
- ✅ 每次成功执行同步后（无论是否有问题）
- ⚠️ 同步过程中遇到任何冲突或错误
- 🔧 需要手动干预才能完成的同步
- 📝 脚本版本更新或配置变更

### 7.4 日志命名规范

文件名格式：`YYYY-MM-DD.md`
- 示例：`2026-01-27.md`
- 如果同一天多次同步，使用后缀：`2026-01-27-2.md`

### 7.5 日志内容要求

每个日志文件必须包含：

#### 基本信息
```markdown
- 日期时间: YYYY-MM-DD HH:MM
- 执行人: AI Agent 或人工
- 脚本版本: sync_subtrees.sh (vx.x)
```

#### 同步概况
- 主模块同步状态
- 子模块同步状态
- 是否遇到问题

#### 问题描述（如有）
- 错误信息
- 根本原因分析
- 解决步骤
- 相关 commit hash

#### 最终结果
- 同步是否成功
- 新增/修改的文件
- 后续注意事项

### 7.6 日志模板

使用日志模板：`.scripts/logs/README.md`

参考示例：`.scripts/logs/2026-01-27.md`

### 7.7 日志质量标准

**合格的日志**:
- ✅ 包含完整的错误信息（命令输出、堆栈跟踪）
- ✅ 说明为什么会出现这个问题（根本原因）
- ✅ 记录完整的解决步骤（可复现）
- ✅ 包含相关的 commit hash
- ✅ 提供后续建议或改进点

**不合格的日志**:
- ❌ 只写"同步成功"没有任何细节
- ❌ 省略错误信息或解决步骤
- ❌ 没有说明为什么这样做
- ❌ 缺少 commit hash

---

## 8. 维护记录

### 2026-01-27
- 创建 `.scripts/logs/` 目录和日志系统
- 编写首次同步日志，记录 atom01_deploy 重构问题
- 更新维护文档，添加日志规范

### 2026-01-27 (早期)
- 创建 `.scripts/` 目录和本维护文档
- 移动 `sync_subtrees.sh` 到新目录
- 修复工作目录逻辑（切换到仓库根目录）
- 添加 atom01_train gitlink 冲突自动处理
- 移除主模块的 `--squash` 参数（保留完整历史）

---

## 9. 快速参考

### 运行脚本
```bash
cd /home/tcmofashi/proj/roboto_origin
./.scripts/sync_subtrees.sh
```

### 手动检查仓库状态
```bash
git status
git log --oneline -10
git ls-files -s modules/atom01_train/ | grep "^160000"
```

### 手动解决 atom01_train 冲突
```bash
cd modules/atom01_train
git rm -rf robolab rsl_rl
cd ../..
git add modules/atom01_train/.gitmodules
git commit -m "Merge atom01_train (保留 .gitmodules)"
```

### 手动拉取子模块
```bash
git subtree add --prefix=modules/atom01_train/robolab https://github.com/Luo1imasi/robolab.git master --squash
git subtree pull --prefix=modules/atom01_train/rsl_rl https://github.com/Luo1imasi/rsl_rl.git main --squash
```

### 清理仓库大小
```bash
git gc --aggressive --prune=now
```

---

## 10. 已知问题和待优化

### 已知问题
1. **目录重构无法自动处理**
   - 当远程仓库进行大规模目录重构时（如 atom01_deploy 的 src/ 和 tools/ 重构），脚本无法自动处理
   - 需要手动删除旧的 subtree，接受远程变更，然后重新添加

2. **冲突处理局限**
   - 脚本的冲突处理逻辑主要针对 atom01_train 的 gitlink 冲突
   - 对于其他类型的冲突（rename/delete, modify/delete）可能无法自动解决

3. **.gitmodules 检测时机**
   - 脚本只在第一阶段的特殊处理中检测 .gitmodules
   - 如果在第二阶段子模块拉取时出现问题，可能需要手动干预

### 待优化项
- [ ] 添加脚本参数支持
  - [ ] `--dry-run`: 仅显示将要执行的操作，不实际执行
  - [ ] `--verbose`: 输出更详细的日志
  - [ ] `--module <name>`: 仅同步指定的模块
  - [ ] `--skip-main`: 跳过主模块同步，仅同步子模块

- [ ] 增强冲突处理
  - [ ] 检测 .gitmodules 变化并提示用户
  - [ ] 自动识别大规模目录重构
  - [ ] 提供半自动模式，遇到冲突时暂停并提供建议

- [ ] 添加回滚功能
  - [ ] 同步失败时自动回档到同步前的状态
  - [ ] 创建临时备份点

- [ ] 优化日志输出
  - [ ] 减少不必要的输出
  - [ ] 添加进度指示器
  - [ ] 使用结构化日志格式（JSON）

- [ ] 性能优化
  - [ ] 并行拉取独立的模块
  - [ ] 使用浅克隆减少网络传输

---

## 11. 联系和上下文

- **仓库路径**: `/home/tcmofashi/proj/roboto_origin`
- **脚本路径**: `.scripts/sync_subtrees.sh`
- **日志目录**: `.scripts/logs/`
- **日志模板**: `.scripts/logs/README.md`
- **永久备份**: `/tmp/sync_subtrees_permanent_backup.sh`
- **主模块**: Atom01_hardware, atom01_deploy, atom01_train, atom01_description
- **子模块**: robolab, rsl_rl, motors, imu, inference, create_ap

如果脚本出现问题，请参考本文档的诊断流程和修复步骤，或查看历史同步日志了解类似问题的解决方案。
