#!/bin/bash
#
# ============================================================================
# PonWrt 云编译定制脚本（对应 Actions-OpenWrt 的 diy-part2.sh 阶段）
# ============================================================================
# 被 .github/workflows/upstream-release.yml 调用，运行目录就是 OpenWrt 源码根
# （yml 里会先把本文件拷进源码树再执行）。
#
# 设计约定：**以后要改的东西都写在这里，尽量不要动 yml。**
#   - 这个脚本每次构建都会执行，必须可重复执行（幂等）
#   - 脚本在 set -euo pipefail 下运行：任何"可能无匹配"的命令都要处理退出码
#   - 定位不到目标（上游改结构）时，默认【警告并跳过】，不要让整个构建挂掉；
#     只有"确实发现异常/修补失败"才 exit 1
#
# 当前做的事：
#   1. 删除 luci feed 自带的旧 luci-app-passwall2 / luci-app-passwall（防遮挡）
#   2. 删除 packages feed 的旧 xray-core，让 passwall_packages 版透出来
#   3. v2ray-geodata 去遮挡：只保留 passwall_packages 的版本
#      （passwall_packages 用 Loyalsoldier 直连源的新版数据；
#        immortalwrt packages feed 的版本更旧，且 luci-app-passwall2
#        依赖 +v2ray-geoip +v2ray-geosite，不清干净就会被旧版遮挡）
#   4. 修补 passwall2 的 dns-in: protocol "tunnel" -> "dokodemo-door"
#      （x64 版实测的 passwall2 源码 bug；全文有 3 处 protocol = "tunnel"，
#        只能改 dns-in 入站块里那一处）
#   5. 校验上面几步的结果
#
# 不做 passwall feed 钉版：直接用上游最新版（需要钉版见文件末尾注释）。
# ============================================================================

set -euo pipefail

say() { echo ">>> $*"; }
warn() { echo ">>> [警告] $*"; }
die() { echo ">>> [ERROR] $*" >&2; exit 1; }

# 安全检查：必须在 OpenWrt 源码根目录执行
if [ ! -f rules.mk ] || [ ! -x scripts/feeds ]; then
  die "diy.sh 必须在 OpenWrt 源码根目录执行（当前目录: $(pwd)）"
fi

say "diy.sh 开始执行（工作目录: $(pwd)）"

# ---------------------------------------------------------------------------
# 1. luci feed 排序靠前且自带旧 passwall2，删掉防遮挡
# ---------------------------------------------------------------------------
say "Removing passwall copies shipped by the luci feed..."
rm -rf feeds/luci/applications/luci-app-passwall2 feeds/luci/applications/luci-app-passwall
rm -rf package/feeds/luci/luci-app-passwall2 package/feeds/luci/luci-app-passwall

# ---------------------------------------------------------------------------
# 2. 删 packages feed 的旧 xray-core，让 passwall_packages 的新版透出来
# ---------------------------------------------------------------------------
say "Removing shadowed xray-core from packages feed..."
rm -rf feeds/packages/net/xray-core
rm -rf package/feeds/packages/xray-core

# ---------------------------------------------------------------------------
# 3. v2ray-geodata 去遮挡
# ---------------------------------------------------------------------------
# 必须在下面的 feeds install 之前删：feeds/ 是源，package/feeds/ 是安装后的
# 副本，两处都要清。用 mapfile + 显式判断，避免 `find | grep -v` 在无匹配时
# grep 返回 1 被 pipefail 判成失败而中断整个步骤。
# 注意：package/feeds/ 下是 symlink，find 不能加 -type d。
# ---------------------------------------------------------------------------
say "Removing shadowing v2ray-geodata from all feeds except passwall_packages..."
mapfile -t GEO_DATA_DIRS < <(find feeds package/feeds -name "v2ray-geodata" 2>/dev/null | grep -v "passwall_packages" || true)
if [ "${#GEO_DATA_DIRS[@]}" -eq 0 ]; then
  say "没有需要移除的 v2ray-geodata 副本。"
else
  for d in "${GEO_DATA_DIRS[@]}"; do
    say "Removing $d"
    rm -rf "$d"
  done
fi

# ---------------------------------------------------------------------------
# 4. passwall2 dns-in 补丁
# ---------------------------------------------------------------------------
# 只在【确实存在该 bug】时才修补：
#   - 文件/块找不到      -> 警告跳过，不中断构建
#   - 已经修好           -> 跳过（幂等）
#   - 多个 dns-in 入站块 -> 报错退出（不猜，交给人看）
#   - 修补后仍未修好     -> 报错退出（保证不会带着坏配置编出固件）
# ---------------------------------------------------------------------------
say "Checking passwall2 dns-in patch..."
UTIL_XRAY=$(find feeds/passwall2 -name "util_xray.lua" 2>/dev/null | head -1 || true)
if [ -z "$UTIL_XRAY" ] || [ ! -f "$UTIL_XRAY" ]; then
  warn "feeds/passwall2/util_xray.lua 未找到，跳过 dns-in 补丁。"
else
  say "dns-in patch target: $UTIL_XRAY"
  # 4.1 所有 dns-in 入站块（tag = "dns-in"，两种引号都算）
  DNSIN_TAGS=$(grep -nE "tag[[:space:]]*=[[:space:]]*[\"']dns-in[\"']" "$UTIL_XRAY" | cut -d: -f1 || true)
  DNSIN_COUNT=$(printf '%s\n' "$DNSIN_TAGS" | grep -c . || true)
  if [ "$DNSIN_COUNT" -eq 0 ]; then
    warn "未找到 dns-in 入站块，跳过该补丁。"
  elif [ "$DNSIN_COUNT" -ne 1 ]; then
    echo ">>> [ERROR] 找到 $DNSIN_COUNT 个 dns-in 入站块（预期 1 个），请人工确认后再修补：" >&2
    printf '%s\n' "$DNSIN_TAGS" >&2
    exit 1
  else
    DNSIN_LINE=$(printf '%s\n' "$DNSIN_TAGS" | head -n1)
    # 4.2 该块之前是否已经出现过 dokodemo-door（幂等判断）
    if sed -n "1,${DNSIN_LINE}p" "$UTIL_XRAY" | grep -q "dokodemo-door"; then
      say "dns-in 已经修补过，跳过（幂等）。"
    else
      # 4.3 在块内向上 8 行范围内定位 protocol = "tunnel"，取最靠近 tag 的那一行
      patch_line=""
      start=$(( DNSIN_LINE - 8 ))
      [ "$start" -lt 1 ] && start=1
      for ((n=DNSIN_LINE; n>=start; n--)); do
        if sed -n "${n}p" "$UTIL_XRAY" | grep -qE 'protocol[[:space:]]*=[[:space:]]*["'"'"']tunnel["'"'"']'; then
          patch_line=$n
        fi
      done
      if [ -z "$patch_line" ]; then
        warn "dns-in 块附近没有 protocol = \"tunnel\"，上游可能已改结构，跳过。"
      else
        say "patching line ${patch_line} (dns-in block at line ${DNSIN_LINE})"
        sed -i "${patch_line}s/[\"']tunnel[\"']/\"dokodemo-door\"/" "$UTIL_XRAY"
        say "diff:"
        sed -n "$(( patch_line - 4 )),$(( patch_line + 4 ))p" "$UTIL_XRAY"
        # 4.4 验证：修补后 tag=dns-in 之前必须出现 dokodemo-door
        sed -n "$(( DNSIN_LINE - 8 )),${DNSIN_LINE}p" "$UTIL_XRAY" \
          | grep -q "dokodemo-door" \
          || die "dns-in protocol patch failed!"
        say "dns-in protocol patched."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. 重装这两个 feed，让上面的修改生效
# ---------------------------------------------------------------------------
say "Re-installing passwall feeds (no pin, use upstream latest)..."
./scripts/feeds install -f -a -p passwall2
./scripts/feeds install -f -a -p passwall_packages

# ---------------------------------------------------------------------------
# 6. POST-INSTALL 清理：feeds install 装依赖时会查陈旧索引，
#    把已删的 packages 版 v2ray-geodata / xray-core 又装回来，这里再清一次
# ---------------------------------------------------------------------------
say "Removing post-install v2ray-geodata stragglers..."
mapfile -t GEO_STRAGGLERS < <(find package/feeds -name "v2ray-geodata" 2>/dev/null | grep -v "passwall_packages" || true)
if [ "${#GEO_STRAGGLERS[@]}" -eq 0 ]; then
  say "没有复活出来的 v2ray-geodata 副本。"
else
  for d in "${GEO_STRAGGLERS[@]}"; do
    say "Removing straggler $d"
    rm -rf "$d"
  done
fi
rm -rf package/feeds/packages/xray-core

# 确保 passwall_packages 的在位（万一 install 跳过，手动建 symlink 兜底）
if [ ! -e "package/feeds/passwall_packages/v2ray-geodata" ]; then
  say "Manually linking v2ray-geodata from passwall_packages..."
  mkdir -p package/feeds/passwall_packages
  ln -s "../../../feeds/passwall_packages/v2ray-geodata" package/feeds/passwall_packages/v2ray-geodata
fi

# 清掉可能残留的旧构建产物（同名包先被装过时会有陈旧 build_dir）
rm -rf build_dir/target-*/v2ray-geodata build_dir/target-*/xray-core 2>/dev/null || true
rm -f staging_dir/target-*/pkginfo/v2ray-geodata.* staging_dir/target-*/pkginfo/xray-core.* 2>/dev/null || true

# ---------------------------------------------------------------------------
# 7. 校验
# ---------------------------------------------------------------------------
say "Verifying passwall/geodata state..."
[ -d "package/feeds/passwall_packages/v2ray-geodata" ] \
  || die "passwall_packages v2ray-geodata missing!"

REMAINING_COUNT=$(find package/feeds -name "v2ray-geodata" 2>/dev/null | wc -l)
if [ "$REMAINING_COUNT" -ne 1 ]; then
  echo ">>> [ERROR] Expected exactly 1 v2ray-geodata, found $REMAINING_COUNT:" >&2
  find package/feeds -name "v2ray-geodata" 2>/dev/null || true
  exit 1
fi

[ -d "package/feeds/passwall_packages/xray-core" ] \
  || die "passwall_packages xray-core missing!"

if [ -d feeds/packages/net/v2ray-geodata ]; then
  warn "packages feed 的旧版 v2ray-geodata 仍在，geo 数据可能被遮挡！"
else
  say "packages feed 的旧版 v2ray-geodata 已移除（去遮挡成功）"
fi

if [ -f feeds/passwall_packages/v2ray-geodata/Makefile ]; then
  say "生效的 geo 数据来源："
  grep -E 'GEOIP_VER|GEOSITE_VER|URL:=' feeds/passwall_packages/v2ray-geodata/Makefile || true
fi

say "v2ray-geodata 最终位置："
find package/feeds -name "v2ray-geodata" 2>/dev/null || true
say "xray-core 最终位置："
find package/feeds -name "xray-core" 2>/dev/null || true

say "diy.sh 执行完毕。"

# ===========================================================================
# 以后要加东西，直接往下写即可，例如：
#
#   # 改默认主题
#   sed -i 's/luci-theme-bootstrap/luci-theme-argon/g' feeds/luci/collections/luci/Makefile
#
#   # 删掉有循环依赖/冲突的包（记得同时清 .config 里残留的选中项）
#   rm -rf feeds/luci/applications/luci-app-fchomo feeds/packages/net/mihomo feeds/packages/net/nikki
#   rm -rf package/feeds/luci/luci-app-fchomo package/feeds/packages/mihomo package/feeds/packages/nikki
#
#   # 需要钉版 passwall feed（默认不钉）
#   # git -C feeds/passwall2 checkout -q ab1e812ec57ac7be0e213532f60ef4c46e76d962
#   # git -C feeds/passwall_packages checkout -q c6d4772cea9bec6adc66261be2c3e6679a595250
#   # 注意：钉版要在上面的 feeds install 之前做，才需要重新 install
# ===========================================================================
