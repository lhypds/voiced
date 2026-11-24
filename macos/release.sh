#!/bin/zsh
#
# 发布到 GitHub Release。
#
# 用法：
#   ./release.sh            # bump patch：1.2.3 -> 1.2.4
#   ./release.sh minor      # bump minor：1.2.3 -> 1.3.0
#   ./release.sh major      # bump major：1.2.3 -> 2.0.0
#   ./release.sh 1.5.0      # 直接指定版本
#
# 流程：读取 VERSION -> 计算新版本 -> 写回 VERSION 和 Support/Info.plist
#       -> 构建 .build/Voiced.app -> 打 zip -> commit + tag -> push
#       -> gh release create 并上传 zip。

set -euo pipefail

ROOT="${0:A:h}"
VERSION_FILE="$ROOT/VERSION"
PLIST="$ROOT/Support/Info.plist"
APP="$ROOT/.build/Voiced.app"
DIST="$ROOT/.build/dist"
BUMP="${1:-patch}"

cd "$ROOT"

die() { print -u2 "error: $*"; exit 1; }

# ---- 前置检查 -------------------------------------------------------------

command -v gh >/dev/null || die "需要 gh CLI：brew install gh"
gh auth status >/dev/null 2>&1 || die "gh 未登录：gh auth login"
[[ -f "$VERSION_FILE" ]] || die "缺少 $VERSION_FILE"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "master" ]] || die "请在 master 分支发布（当前：$BRANCH）"
[[ -z "$(git status --porcelain)" ]] || die "工作区有未提交的改动，请先提交或 stash"

git fetch origin master --quiet
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/master)"
[[ "$LOCAL" == "$REMOTE" ]] || die "本地 master 与 origin/master 不一致，请先 pull/push"

# ---- 计算版本 -------------------------------------------------------------

CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$CURRENT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION 格式不对：$CURRENT（需要 X.Y.Z）"

IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$BUMP" in
    patch) PATCH=$((PATCH + 1)) ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    [0-9]*.[0-9]*.[0-9]*)
        [[ "$BUMP" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式不对：$BUMP"
        IFS=. read -r MAJOR MINOR PATCH <<< "$BUMP"
        ;;
    *) die "未知参数：$BUMP（可用 patch | minor | major | X.Y.Z）" ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW"

[[ "$NEW" != "$CURRENT" ]] || die "新版本与当前版本相同：$NEW"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG 已存在"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "远端已有 tag $TAG"

print "发布 $CURRENT -> $NEW"

# ---- 写入版本 -------------------------------------------------------------

print "$NEW" > "$VERSION_FILE"
# 用 perl 原地替换，保留 plist 原有缩进和 key 顺序（PlistBuddy 会重排）。
perl -0pi -e "s|(<key>CFBundleShortVersionString</key>\\s*<string>)[^<]*|\${1}$NEW|; s|(<key>CFBundleVersion</key>\\s*<string>)[^<]*|\${1}$NEW|" "$PLIST"

# ---- 构建并打包 -----------------------------------------------------------

"$ROOT/Scripts/build-app.sh"

rm -rf "$DIST"
mkdir -p "$DIST"
ZIP="$DIST/Voiced-$NEW.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
print "打包 $ZIP"

# ---- 提交、打 tag、推送 ---------------------------------------------------

git add "$VERSION_FILE" "$PLIST"
git commit -q -m "Release $TAG"
git tag -a "$TAG" -m "Release $TAG"
git push -q origin master "$TAG"
print "已推送 $TAG"

# ---- 创建 GitHub Release --------------------------------------------------

gh release create "$TAG" "$ZIP" \
    --title "Voiced $NEW" \
    --generate-notes

print "发布完成：$(gh release view "$TAG" --json url --jq .url)"
