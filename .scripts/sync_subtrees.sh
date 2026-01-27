#!/bin/bash

###############################################################################
# roboto_origin 自动同步脚本
# 功能：
#   1. 自动拉取四个主模块的最新代码（使用 subtree）
#   2. 读取各主模块的 .gitmodules，自动拉取其子模块（使用 subtree --squash）
#   3. 确保本地永远是四个主模块的快照
###############################################################################

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 获取脚本所在目录的绝对路径，然后切换到仓库根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
cd "$REPO_DIR"

log_info "开始同步 roboto_origin 所有 subtree 模块"
echo "========================================"

###############################################################################
# 辅助函数
###############################################################################

# 函数：获取远程仓库的默认分支
get_default_branch() {
    local repo_url="$1"

    # 使用 git ls-remote --symref 自动检测 HEAD 指向的分支
    # 输出格式: ref: refs/heads/main	HEAD
    local output=$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null)

    if [ $? -ne 0 ]; then
        log_error "git ls-remote 失败: $repo_url"
        return 1
    fi

    # 提取分支名
    local default_branch=$(echo "$output" | grep '^ref:' | sed 's/^ref: refs\/heads\///' | awk '{print $1}')

    if [ -z "$default_branch" ]; then
        log_error "无法从远程仓库获取默认分支: $repo_url"
        return 1
    fi

    echo "$default_branch"
}

###############################################################################
# 第一部分：同步四个主模块
###############################################################################

# 定义主模块数组：格式 "模块名|仓库URL|分支名"
MAIN_MODULES=(
    "Atom01_hardware|https://github.com/Roboparty/Atom01_hardware.git|main"
    "atom01_deploy|https://github.com/Roboparty/atom01_deploy.git|main"
    "atom01_train|https://github.com/Roboparty/atom01_train.git|main"
    "atom01_description|https://github.com/Roboparty/atom01_description.git|main"
)

log_info "步骤 1/2: 同步四个主模块"
echo ""

for module_config in "${MAIN_MODULES[@]}"; do
    IFS='|' read -r module_name module_url module_branch <<< "$module_config"
    module_path="modules/$module_name"

    echo "----------------------------------------"
    log_info "处理主模块: $module_name"

    # 检查模块目录是否存在
    if [ ! -d "$module_path" ]; then
        log_warn "模块目录 $module_path 不存在，首次添加..."
        git subtree add --prefix="$module_path" "$module_url" "$module_branch"
    else
        log_info "更新已存在的模块: $module_name"

        # 特殊处理 atom01_train 的 gitlink 冲突
        if [ "$module_name" = "atom01_train" ] && [ -f "$module_path/.gitmodules" ]; then
            log_info "  检测到 atom01_train 包含 .gitmodules，准备处理可能的 gitlink 冲突"

            # 保存 .gitmodules 内容
            gitmodules_backup=$(cat "$module_path/.gitmodules" 2>/dev/null || echo "")

            # 尝试拉取更新
            if ! git subtree pull --prefix="$module_path" "$module_url" "$module_branch" 2>&1 | tee /tmp/subtree_output.txt | grep -q "CONFLICT"; then
                # 无冲突，检查 .gitmodules 是否被清空
                if [ -f "$module_path/.gitmodules" ] && [ ! -s "$module_path/.gitmodules" ]; then
                    log_warn "  .gitmodules 被清空，恢复内容..."
                    if [ -n "$gitmodules_backup" ]; then
                        echo "$gitmodules_backup" > "$module_path/.gitmodules"
                        git add "$module_path/.gitmodules"
                        git commit --amend --no-edit > /dev/null 2>&1 || true
                        log_success "  .gitmodules 已恢复"
                    fi
                fi
            else
                # 有冲突，自动解决
                log_warn "  检测到 gitlink 冲突，自动解决..."

                # 查找并删除所有冲突标记的目录
                find "$module_path" -maxdepth 1 -type d -name "*~*" | while read conflict_dir; do
                    log_info "    删除冲突目录: $(basename "$conflict_dir")"
                    rm -rf "$conflict_dir"
                done

                # 删除 submodule 的实际目录（它们是 gitlink，需要删除以避免冲突）
                if [ -d "$module_path/robolab" ]; then
                    log_info "    删除冲突目录: robolab"
                    git rm -rf "$module_path/robolab" > /dev/null 2>&1 || rm -rf "$module_path/robolab"
                fi
                if [ -d "$module_path/rsl_rl" ]; then
                    log_info "    删除冲突目录: rsl_rl"
                    git rm -rf "$module_path/rsl_rl" > /dev/null 2>&1 || rm -rf "$module_path/rsl_rl"
                fi

                # 恢复 .gitmodules
                if [ -n "$gitmodules_backup" ]; then
                    echo "$gitmodules_backup" > "$module_path/.gitmodules"
                fi

                # 添加 .gitmodules 并完成合并
                git add "$module_path/.gitmodules"

                # 提交合并
                if ! git commit -m "Merge $module_name (保留 .gitmodules)" > /dev/null 2>&1; then
                    log_error "    自动合并失败，请手动处理"
                    return 1
                fi

                log_success "  冲突已自动解决，.gitmodules 已恢复"
            fi
        else
            # 普通模块，直接拉取
            git subtree pull --prefix="$module_path" "$module_url" "$module_branch"
        fi
    fi

    log_success "主模块 $module_name 同步完成"
    echo ""
done

###############################################################################
# 第二部分：自动读取并同步主模块的子模块
###############################################################################

echo "========================================"
log_info "步骤 2/2: 自动同步主模块的子模块"
echo ""

# 函数：解析 .gitmodules 文件并同步子模块
sync_submodules() {
    local main_module_path="$1"
    local gitmodules_file="$main_module_path/.gitmodules"

    # 检查 .gitmodules 是否存在
    if [ ! -f "$gitmodules_file" ]; then
        log_info "$main_module_path 没有子模块，跳过"
        echo ""
        return
    fi

    local main_module_name=$(basename "$main_module_path")
    log_info "发现 $main_module_name 包含子模块，正在解析..."

    # 解析 .gitmodules 文件
    # 格式：
    # [submodule "xxx"]
    #     path = xxx
    #     url = xxx

    local in_submodule=false
    local submodule_name=""
    local submodule_path=""
    local submodule_url=""

    while IFS= read -r line || [ -n "$line" ]; do
        # 去除首尾空白
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # 跳过空行和注释
        if [ -z "$line" ] || [[ "$line" == \#* ]]; then
            continue
        fi

        # 检测 [submodule "xxx"]
        if [[ "$line" =~ ^\[submodule\ \"(.+)\"\]$ ]]; then
            # 如果之前有子模块信息，先处理它
            if [ -n "$submodule_name" ] && [ -n "$submodule_path" ] && [ -n "$submodule_url" ]; then
                sync_one_submodule "$main_module_name" "$submodule_name" "$submodule_path" "$submodule_url"
            fi

            # 开始新的子模块
            submodule_name="${BASH_REMATCH[1]}"
            submodule_path=""
            submodule_url=""
            in_submodule=true
            continue
        fi

        # 解析 path 和 url
        if [ "$in_submodule" = true ]; then
            if [[ "$line" =~ ^path\ =\ (.+)$ ]]; then
                submodule_path="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^url\ =\ (.+)$ ]]; then
                submodule_url="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$gitmodules_file"

    # 处理最后一个子模块
    if [ -n "$submodule_name" ] && [ -n "$submodule_path" ] && [ -n "$submodule_url" ]; then
        sync_one_submodule "$main_module_name" "$submodule_name" "$submodule_path" "$submodule_url"
    fi

    echo ""
}

# 函数：同步单个子模块
sync_one_submodule() {
    local main_module_name="$1"
    local submodule_name="$2"
    local submodule_rel_path="$3"  # 相对于主模块的路径
    local submodule_url="$4"

    local full_submodule_path="modules/$main_module_name/$submodule_rel_path"

    echo "  → 处理子模块: $submodule_name"
    log_info "    路径: $full_submodule_path"
    log_info "    仓库: $submodule_url"

    # 自动检测默认分支
    local submodule_branch
    submodule_branch=$(get_default_branch "$submodule_url")
    if [ $? -ne 0 ] || [ -z "$submodule_branch" ]; then
        log_error "    自动检测分支失败，跳过 $submodule_name"
        return 1
    fi
    log_info "    检测到默认分支: $submodule_branch"

    # 检查子模块目录是否存在
    if [ ! -d "$full_submodule_path" ]; then
        log_warn "    子模块目录不存在，首次添加..."
        git subtree add --prefix="$full_submodule_path" "$submodule_url" "$submodule_branch" --squash
    else
        log_info "    更新已存在的子模块..."
        git subtree pull --prefix="$full_submodule_path" "$submodule_url" "$submodule_branch" --squash
    fi

    log_success "    子模块 $submodule_name 同步完成"
}

# 遍历所有主模块，查找并同步子模块
for module_config in "${MAIN_MODULES[@]}"; do
    IFS='|' read -r module_name module_url module_branch <<< "$module_config"
    module_path="modules/$module_name"

    echo "----------------------------------------"
    sync_submodules "$module_path"
done

###############################################################################
# 完成
###############################################################################

echo "========================================"
log_success "所有模块同步完成！"
echo ""
log_info "当前仓库状态："
git status --short
echo ""
log_info "最近的同步提交："
git log --oneline -5
echo ""
log_info "========================================"
log_info "📝 重要提醒：请编写同步日志！"
echo ""
echo "请按照以下步骤编写本次同步的日志："
echo "  1. 查看日志模板: cat .scripts/logs/README.md"
echo "  2. 参考示例日志: cat .scripts/logs/2026-01-27.md"
echo "  3. 创建新日志: vi .scripts/logs/$(date +%Y-%m-%d).md"
echo ""
echo "日志内容应包括："
echo "  - 基本信息（日期、执行人、脚本版本）"
echo "  - 同步概况（各模块状态）"
echo "  - 遇到的问题和解决方案"
echo "  - 最终结果和后续注意事项"
echo ""
log_info "======================================"
