# Git 协作与发布

## 仓库与授权

本工程已建立 GitHub 仓库：

- 仓库：`https://github.com/xiaohonghua661/Banana-Pi-R3-Mini-Toolkit`
- Git 远端：`git@github.com:xiaohonghua661/Banana-Pi-R3-Mini-Toolkit.git`
- 当前默认分支：`main`
- 首个 Release：`v1.0.0`

用户已授权 Agent 把本工程中有用、完成测试且通过公开内容审计的更新提交并上传到该仓库，无需为普通 push 重复询问。此授权不包含强制推送、改写历史或标签、发布敏感资料、覆盖其他任务改动，以及把未完成内容制作成 Release。

仓库可能改名、转移或调整默认分支。每次上传前运行 `git remote -v` 和 `gh repo view --json url,visibility,defaultBranchRef`，让 `gh` 从当前 Git 远端识别仓库；不要把当前 HEAD 或“最新版本永远是 v1.0.0”写成长期事实。

## 并发规则

多个 Agent 同时工作时先用 dd 声明任务和文件范围。默认使用独立 worktree 与唯一功能分支，只普通 push 自己的分支。共享工作目录中的主线 Agent 只有在明确负责收口、确认远端未分叉且不会覆盖其他任务时，才能普通 push `main`。

```powershell
dd join Banana_Pi_r3mini
dd note '正在修改 <owned-paths>，完成测试后上传到 Git 功能分支'
git fetch origin
git worktree add ..\Banana_Pi_r3mini-<topic> -b agent/<topic> origin/main
```

`<topic>` 使用简短英文任务名，每个 Agent 必须唯一。无法使用独立 worktree 时，只允许主线收口 Agent 在共享目录提交，并严格限定暂存路径。

遇到脏工作树时：

1. 运行 `git status --short`，识别自己的改动、他人的改动和未跟踪文件。
2. 只用 `git add -- <owned-paths>` 暂存本任务文件；禁止在并发工作树中使用 `git add .`。
3. 不执行 `git reset --hard`、`git checkout -- <file>`、`git clean` 或其他会丢弃文件的命令。
4. 不提交、移动、改写或删除其他 Agent 的未完成改动；范围重叠时先通过 dd 协调。
5. 禁止 `git push --force` 和 `git push --force-with-lease`，禁止覆盖共享分支、标签或他人分支。

## 提交与上传闸门

按以下顺序执行：

1. 读取完整 `docs/必读/`，再读取改动模块的代码、测试和操作文档。
2. 运行对应的离线测试、语法检查和必要的 fresh 黑盒验收。涉及真实路由器时先做可恢复备份，再变更，最后验收。

   ```powershell
   # 两个本地 Dashboard
   python fan-dashboard/test_dashboard.py
   python device-dashboard/test_dashboard.py

   # Netdata 中文覆盖层
   python third_party/netdata-chinese-patch/compat/test_overlay.py
   python third_party/netdata-chinese-patch/compat/test_deploy_upload.py
   bash -n third_party/netdata-chinese-patch/compat/deploy-openwrt.sh

   # 仅语法检查本次修改涉及的 Python 目录和 Shell 文件
   python -m compileall -q <changed-python-directories>
   bash -n <changed-shell-file>
   ```

   `filemanager-fix/` 使用 `bash -n filemanager-fix/apply-router.sh` 与 `python -m py_compile filemanager-fix/verify_filemanager_ui.py`；`openclash-ui-patch/` 使用 `python -m compileall -q openclash-ui-patch` 并对涉及的 Shell 文件运行 `bash -n`；`scripts/router/` 对涉及的 Shell 文件运行 `bash -n`。文档改动派 fresh 黑盒 Agent 做阅读理解、实际测试和疑问三段验收。真实路由器功能测试按改动模块的验收脚本执行，不用在线设备替代离线语法检查。
3. 检查暂存区，只保留本任务文件：

   ```powershell
   git diff --cached --stat
   git diff --cached
   ```

4. 确认未包含敏感资料、大体积设备产物或临时文件，再创建小而完整的提交。
5. 上传前运行 `git fetch origin`。远端已推进或存在冲突时停止，先在干净 worktree 中合并或变基并重新测试；不要在含他人改动的共享工作树中强行处理。
6. 普通 push 当前功能分支；由主线收口时再把已验证提交推送到 `main`：

   ```powershell
   git push -u origin HEAD
   ```

   主线推送前再次确认 `git branch --show-current`、`git status --short` 和 `git log --oneline origin/main..HEAD`；不能证明提交范围时停止。
7. 交付时报告提交哈希、远端分支或提交 URL、实际测试输出和仍未验证的项目。

## 禁止公开的内容

不得提交或上传：

- `docs/私密/`、`backups/`、设备镜像、MTD/eMMC 转储和配置归档。
- DPAPI 文件、离线安装包、管理/Wi-Fi 密码、代理订阅、节点、密钥、令牌和密码辅助脚本。
- `.tmp/`、`tmp/`、缓存、`.bak`、运行日志、临时截图和其他可再生成产物。

提交前确认 `.gitignore` 仍覆盖这些路径，并对暂存区执行敏感模式和大文件检查。发现疑似凭据时立即取消暂存，保留本机原件，不把匹配内容打印到公开日志。

```powershell
$patterns = @(
  'gho_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{20,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----',
  'https?://[^/[:space:]]+:[^@[:space:]]+@',
  'option[[:space:]]+(key|password|passwd)[[:space:]]+''[^'']+'''
)
foreach ($pattern in $patterns) {
  $matches = git grep --cached -I -l -E -- $pattern 2>$null
  if ($matches) { $matches; throw 'sensitive_pattern_match' }
}

$staged = git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR
$blocked = $staged | Where-Object {
  $_ -match '(^|/)(docs/私密|backups|tmp|\.tmp)(/|$)' -or
  $_ -match '(^|/)fan-dashboard/ssh-askpass\.cmd$' -or
  $_ -match '\.(bak|dpapi|img|tar\.gz|ipk|key|pem)$'
}
if ($blocked) { $blocked; throw 'forbidden_public_path_staged' }

$limit = 50MB
foreach ($file in $staged) {
  if ((Get-Item -LiteralPath $file).Length -gt $limit) {
    $file
    throw 'staged_file_exceeds_50MiB'
  }
}
```

扫描只打印命中文件路径，不打印疑似凭据正文。50 MiB 是本工程的提交闸门，不是 GitHub 的服务端极限；确需发布的大文件先确认许可和用途，再使用专门的 Release 资产或其他存储方案。

## Release 规则

普通更新只需提交和 push，不为每个提交创建 Release。仅在用户要求或形成可恢复里程碑时发布 Release，并满足：

- 标签指向已合并、已测试、已完成敏感信息审计的提交。
- 源码备份由已提交 Git 树生成，不从脏工作目录直接压缩。
- 上传源码压缩包和独立 SHA-256 文件；从 GitHub 重新下载后比对哈希。
- Release 说明按“新增、修改、修复、移除或不再发布、安全、验证”记录。
- 不在 Release 说明中写运行地址、密码、订阅或私密备份路径。

标准发布流程如下。只在工作树无已跟踪改动、远端 `main` 与本地目标提交一致、版本号尚不存在时执行：

```powershell
$version = 'vX.Y.Z'
$name = "Banana-Pi-R3-Mini-Toolkit-$version"

git fetch origin
if ($LASTEXITCODE -ne 0) { throw 'git_fetch_failed' }
git diff --quiet
if ($LASTEXITCODE -ne 0) { throw 'tracked_worktree_not_clean' }
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'index_not_clean' }

$target = git rev-parse HEAD
$remoteMain = git rev-parse origin/main
if ($target -ne $remoteMain) { throw 'release_target_not_origin_main' }
if (git tag -l $version) { throw 'local_version_tag_exists' }
if (git ls-remote --exit-code --tags origin "refs/tags/$version" 2>$null) {
  throw 'remote_version_tag_exists'
}

git tag -a $version -m "Banana Pi R3 Mini Toolkit $version"

New-Item -ItemType Directory -Force -Path '.release' | Out-Null
$zip = ".release/$name.zip"
$sha = ".release/$name.sha256"
git archive --format=zip --prefix="$name/" --output=$zip $version
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $sha -Value "$hash  $name.zip" -Encoding ascii

git push origin $version
if ($LASTEXITCODE -ne 0) { throw 'release_tag_push_failed' }

gh release create $version "$zip#源码与公开文档备份" "$sha#SHA-256 校验文件" `
  --verify-tag --title "$version" --notes-file CHANGELOG.md
if ($LASTEXITCODE -ne 0) { throw 'release_create_failed_remote_tag_preserved' }

$download = ".release/downloaded-$version"
New-Item -ItemType Directory -Force -Path $download | Out-Null
gh release download $version --dir $download --pattern "$name.*" --clobber
$downloaded = (Get-FileHash "$download/$name.zip" -Algorithm SHA256).Hash.ToLowerInvariant()
if ($downloaded -ne $hash) { throw 'downloaded_release_hash_mismatch' }
if (-not (Get-Content "$download/$name.sha256").StartsWith($hash)) {
  throw 'downloaded_manifest_mismatch'
}
```

创建标签前另行检查 `git status --short` 中的未跟踪文件；它们不会进入 `git archive`，但必须确认没有本次应交付而尚未提交的文件。Release 创建后运行 `gh release view $version --json url,name,tagName,isDraft,isPrerelease,assets`，确认不是草稿或预发布且两个资产均为 `uploaded`。

`git archive` 和本地哈希在远端标签推送前完成；它们失败时停止，不推送标签。远端标签推送后若 `gh release create` 失败，保留并报告该标签，修复原因后使用同一标签和同一已审计资产重试创建 Release；禁止删除、移动或强推该标签来掩盖失败。

## 失败处理

- `gh auth status` 未通过：停止上传，报告需要恢复 GitHub 登录，不改用网页复制令牌。
- push 被拒绝：先 `git fetch origin` 核对远端提交；不强推，不覆盖远端。
- 敏感扫描命中：取消相关文件暂存，确认 `.gitignore` 和提交历史均未包含该内容。
- 测试失败或证据不足：保留本地改动，不 push，不创建标签或 Release。
- 已经误传敏感信息：停止后续发布，立即报告；仅删除最新文件不等于清除 Git 历史。
