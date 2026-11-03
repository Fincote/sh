#!/bin/bash
#
# finx-install/install.sh - 从零安装 Finx
#
# 本文件由 finx-install/build-bundle.sh 生成，请勿直接编辑。
# 唯一事实来源：finx-install/install.sh.in 与 finx-install/lib/*.sh
#
# 用法：/bin/bash -c "$(curl -fsSL <本文件的地址>)" -- [选项]
#

FINX_BUNDLED=1
set -u
set -o pipefail

# ======== lib/common.sh ========
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
# shellcheck shell=bash
#
# 通用工具：输出、错误、临时目录、命令探测、校验和。
# 由 install.sh 以 . 方式加载，不单独执行。
#
# 约定：面向用户的文案一律英文，注释用中文。

FINX_TMP=""

cleanup() {
    if [ -n "$FINX_TMP" ] && [ -d "$FINX_TMP" ]; then
        rm -rf "$FINX_TMP"
    fi
    FINX_TMP=""
}

on_exit() {
    rc=$?
    cleanup
    exit $rc
}

# ---------------------------------------------------------------------------
# 下载源：全部由环境变量控制
# ---------------------------------------------------------------------------
#
# 与 MacWave 的 MACWAVE_*_DOMAIN 同一套做法：每个域名一个环境变量，不设就用
# 官方默认值。这样镜像、自建 CDN、本机目录都能切，而校验逻辑一条不跳。
#
# 三条约束（照搬 MacWave 的理由）：
#
#   1. 只接受 https:// 或 file://。明文 http 只放行 127.0.0.1 与 localhost
#      的带端口地址 —— 那是离线测试与本机代理用的，不是给人随便填的。
#   2. 末尾斜杠统一去掉，否则 "$DOMAIN/manifest" 会拼出双斜杠，
#      而某些服务端会因此回 404。
#   3. 报错里带上变量名。用户改了三个变量中的一个却填错时，光说
#      "invalid URL" 帮不上忙。
#
# 刻意不做的事：**换地址不等于跳过校验**。种子仍然按清单里的 sha256 与
# size 校验，源归档仍然走同一套流程。镜像只是"从哪儿拿"，不是"信不信"。
finx_domain() {
    # finx_domain <变量名> <值>：规范化并校验，成功则打印
    _finx_name=$1
    _finx_value=$2

    while [ "${_finx_value%/}" != "$_finx_value" ]; do
        _finx_value=${_finx_value%/}
    done

    case $_finx_value in
        https://?*|file://?*)  printf '%s\n' "$_finx_value"; return 0 ;;
        http://127.0.0.1:?*|http://localhost:?*) printf '%s\n' "$_finx_value"; return 0 ;;
    esac

    printf 'ERROR: %s must be an https:// (or file://) address, got: %s\n' \
        "$_finx_name" "$_finx_value" >&2
    exit 1
}

# 种子清单与种子 tar 默认同源；分开是因为可以让清单走一个域名、
# 大文件走另一个（CDN 与对象存储的常见分法）。
#
# 每个赋值后面必须跟 `|| exit 1`。finx_domain 里的 exit 1 跑在 $( ) 子 shell
# 里，只结束那个子 shell —— 父进程会继续，而变量已经被设成空串。不显式判错
# 的话，填错一个域名得到的不是报错，而是一个悄悄失效的安装器。
# 记住「用户有没有显式给过」：manifest.sh 要据此决定默认清单地址。
# 不能只看 FINX_INDEX_DOMAIN 是否非空 —— 下面这行会把它填上默认值。
FINX_INDEX_DOMAIN_GIVEN=${FINX_INDEX_DOMAIN:+1}
export FINX_INDEX_DOMAIN_GIVEN

FINX_INDEX_DOMAIN=$(finx_domain FINX_INDEX_DOMAIN "${FINX_INDEX_DOMAIN:-https://finx.sh/finx/seed}") || exit 1
export FINX_INDEX_DOMAIN

FINX_SEED_DOMAIN=$(finx_domain FINX_SEED_DOMAIN "${FINX_SEED_DOMAIN:-https://finx.sh/finx/seed}") || exit 1
export FINX_SEED_DOMAIN

# 源码自举时取源码归档的地方，默认 GitHub 的 codeload。
FINX_SOURCE_DOMAIN=$(finx_domain FINX_SOURCE_DOMAIN "${FINX_SOURCE_DOMAIN:-https://codeload.github.com/Fincote/Finx}") || exit 1
export FINX_SOURCE_DOMAIN

# 连不上的等待时间。默认 30 秒；网络差的用户调小能更快地换下一个候选。
# 只管"连上"，不管"下完"——种子可能几十兆，给总时长设上限只会把慢速网络
# 的人挡在门外。
# 这里用裸 printf 而不是 die()：die 定义在后面，且本文件按顺序被 source。
case ${FINX_CONNECT_TIMEOUT:-30} in
    ''|*[!0-9]*)
        printf 'ERROR: FINX_CONNECT_TIMEOUT must be a whole number of seconds, got: %s\n' \
            "$FINX_CONNECT_TIMEOUT" >&2
        exit 1 ;;
esac
FINX_CONNECT_TIMEOUT=${FINX_CONNECT_TIMEOUT:-30}
export FINX_CONNECT_TIMEOUT

# detect_host 会填它；这里先给个空值，避免 set -u 在 detect 之前报错。
HOST_DARWIN_MAJOR=""

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() {
    printf '\n==> %s\n' "$*"
}

# 中英对照。--zh（或 FINX_LANG=zh）时取中文，否则取英文。
#
# 只覆盖安装器自己的话：step 标题、错误、以及收尾提示。curl 的进度条、
# 编译器的输出、bootstrap 的日志一律保持原样 —— 那些不是我们的话，
# 翻译它们只会让搜索报错变得更难。
t() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

info() {
    printf '    %s\n' "$*"
}

warn() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '警告: %s\n' "$*" >&2
    else
        printf 'WARNING: %s\n' "$*" >&2
    fi
}

die() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '错误: %s\n' "$*" >&2
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require() {
    have "$1" || die "required command not found: $1"
}

# 统一的执行入口。目前只是原样执行；留着是为了以后加日志或计时
# 时不必改几十处调用点。
run() {
    "$@"
}

ensure_tmp() {
    if [ -z "$FINX_TMP" ]; then
        # macOS 的 TMPDIR 自带末尾斜杠，直接拼会得到 "T//finx-install"
        tmpbase=${TMPDIR:-/tmp}
        while [ "${tmpbase%/}" != "$tmpbase" ]; do tmpbase=${tmpbase%/}; done
        [ -n "$tmpbase" ] || tmpbase=/tmp
        FINX_TMP=$(mktemp -d "$tmpbase/finx-install.XXXXXX") \
            || die "cannot create a temporary directory"
    fi
}

sha256_of() {
    if have shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif have openssl; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        die "no sha256 tool available (need shasum or openssl)"
    fi
}

file_size() {
    wc -c < "$1" | tr -d ' '
}

human_size() {
    awk -v n="$1" 'BEGIN {
        split("B KB MB GB TB", unit, " ")
        i = 1
        while (n >= 1024 && i < 5) { n /= 1024; i++ }
        printf (i == 1 ? "%d %s" : "%.1f %s"), n, unit[i]
    }'
}

lower() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# ---- 测试根 ---------------------------------------------------------------
#
# FINX_TEST=<绝对路径> 把整个安装器关进这个目录：
#
#   * 默认前缀变成 <测试根>/opt/finx
#   * 临时文件落在 <测试根>/tmp（TMPDIR 一并改掉）
#   * --prefix 只允许指向测试根内部，越界即中止
#
# 相对路径、/、以及解析后落在系统目录里的路径一律拒绝 —— 宁可不跑，
# 也不要因为一个环境变量写错就去动真实安装。

# 规范化路径：存在就 pwd -P，不存在就把最深的已存在祖先规范化后接回剩余部分。
# macOS 上 /tmp 是指向 /private/tmp 的符号链接，不这么做比对会假阴性。
resolve_path() {
    target=$1
    current=$target
    tail=""

    while [ ! -d "$current" ] && [ "$current" != "/" ]; do
        tail="/$(basename -- "$current")$tail"
        current=$(dirname -- "$current")
    done

    if [ -d "$current" ]; then
        (cd -- "$current" && printf '%s%s\n' "$(pwd -P)" "$tail")
    else
        printf '%s\n' "$target"
    fi
}

apply_test_root() {
    [ -n "${FINX_TEST:-}" ] || return 0

    case $FINX_TEST in
        /*) ;;
        *) die "FINX_TEST must be an absolute path (got: $FINX_TEST)" ;;
    esac

    mkdir -p "$FINX_TEST" 2>/dev/null || die "cannot create FINX_TEST=$FINX_TEST"
    TEST_ROOT=$(cd -- "$FINX_TEST" && pwd -P) || die "cannot resolve FINX_TEST=$FINX_TEST"

    [ "$TEST_ROOT" != "/" ] || die "FINX_TEST must not resolve to /"

    case $TEST_ROOT in
        /System|/System/*|/usr|/usr/*|/Library|/Library/*|/Applications|/Applications/*|/bin|/bin/*|/sbin|/sbin/*)
            die "FINX_TEST must not point into a system directory: $TEST_ROOT" ;;
    esac

    mkdir -p "$TEST_ROOT/tmp" || die "cannot create $TEST_ROOT/tmp"
    TMPDIR=$TEST_ROOT/tmp
    export TMPDIR

    # 沙箱里装的都是假东西，源码自举那条路不该向用户要 root
    IN_TEST_ROOT=1

    # 沙箱也绝不能碰真的 shell 配置。FINX_TEST 只管前缀与 TMPDIR，而收尾
    # 会往 $HOME 的启动文件里写 PATH —— 不拦的话，跑一次自测就改了开发者
    # 本人的 .zprofile。写 PATH 那条逻辑由 selftest 用假 HOME 单独测。
    NO_PATH=1

    if [ "${PREFIX_EXPLICIT:-0}" -eq 1 ]; then
        prefix_real=$(resolve_path "$PREFIX")
        case $prefix_real in
            "$TEST_ROOT"/*) ;;
            *) die "--prefix must live under FINX_TEST ($TEST_ROOT), got $prefix_real" ;;
        esac
    else
        PREFIX=$TEST_ROOT/opt/finx
    fi

    info "$(t 'test root' '测试根'): $TEST_ROOT $(t '(nothing outside it will be touched)' '（其外不会被改动）')"
}

# ======== lib/detect.sh ========
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
# shellcheck shell=bash
#
# 宿主与目标目录的探测。由 install.sh 以 . 方式加载，不单独执行。

# 设置 HOST_MACOS_VERSION / HOST_MACOS_MAJOR / HOST_ARCH。
detect_host() {
    require sw_vers
    require uname

    HOST_MACOS_VERSION=$(sw_vers -productVersion 2>/dev/null) \
        || die "cannot read the macOS version (sw_vers failed)"
    HOST_MACOS_MAJOR=${HOST_MACOS_VERSION%%.*}

    case $HOST_MACOS_MAJOR in
        ''|*[!0-9]*) die "cannot parse the macOS version: $HOST_MACOS_VERSION" ;;
    esac

    # 构建与依赖解析都以 Darwin 主版本为准（`uname -r` 的第一段），
    # 它与 macOS 的商用版本号不是同一个序列：12.7.6 是 Darwin 21。
    HOST_DARWIN_MAJOR=$(uname -r | cut -d. -f1)
    case $HOST_DARWIN_MAJOR in
        ''|*[!0-9]*) die "cannot parse the Darwin version: $(uname -r)" ;;
    esac

    HOST_ARCH=$(uname -m)
    case $HOST_ARCH in
        arm64|x86_64) ;;
        *) die "unsupported architecture: $HOST_ARCH" ;;
    esac

    if [ "$HOST_MACOS_MAJOR" -lt 14 ]; then
        warn "macOS $HOST_MACOS_VERSION is below the supported floor (14); continuing anyway"
    fi
}

# absent | empty | existing | nonempty
target_state() {
    target=$1
    if [ ! -e "$target" ]; then
        printf 'absent\n'
    elif [ ! -d "$target" ]; then
        printf 'nonempty\n'
    elif [ -e "$target/bin/finx" ]; then
        printf 'existing\n'
    elif [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        printf 'nonempty\n'
    else
        printf 'empty\n'
    fi
}

nearest_existing_parent() {
    p=$1
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do
        p=$(dirname -- "$p")
    done
    printf '%s\n' "$p"
}

# 本脚本自己的路径，认不出来就打印空。
#
# 在 `bash -c "..."` 与 `curl | bash` 下，$0 都是 shell 本身（bash/sh/...），
# 拿它拼命令会得出「sudo /bin/bash /bin/bash」这种废话。
self_path() {
    _self=${0:-}
    case $(basename -- "$_self" 2>/dev/null) in
        bash|sh|zsh|dash|ksh|'') return 0 ;;
    esac
    if [ -f "$_self" ] && [ -r "$_self" ]; then
        printf '%s\n' "$_self"
    fi
}

require_write_access() {
    target=$1
    if [ -e "$target" ]; then
        probe=$target
    else
        probe=$(nearest_existing_parent "$target")
    fi
    if [ ! -w "$probe" ] && [ "$(id -u)" -ne 0 ]; then
        # 说清楚「怎么带 sudo」。其中管道那种最容易踩：`curl ... | sudo bash`
        # 而不是 `sudo curl ... | bash`（后者只有 curl 是 root，bash 不是）。
        printf 'ERROR: %s %s %s, %s\n' \
            "$probe" "$(t 'is not writable by' '对于下列用户不可写：')" \
            "$(id -un 2>/dev/null || echo 'this user')" \
            "$(t 'so this needs root' '所以需要 root')" >&2
        printf '\n' >&2
        printf '  piped:\n' >&2
        printf '    curl -fsSL <the same URL> | sudo bash\n' >&2
        printf '\n' >&2
        printf '  local file:\n' >&2
        self=$(self_path)
        if [ -n "$self" ]; then
            printf '    sudo /bin/bash %s\n' "$self" >&2
        else
            printf '    sudo /bin/bash <path to install.sh>\n' >&2
        fi
        printf '\n' >&2
        printf '  Do not use `sudo curl ... | bash`: only curl would be root.\n' >&2
        exit 1
    fi
}

do_mkdir() {
    run mkdir -p -m 755 "$1"
}

# ======== lib/manifest.sh ========
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
# shellcheck shell=bash
#
# 种子清单的解析、下载与校验。
#
# 清单是行取向的纯文本，故意不用 JSON：安装阶段不该依赖 jq，
# 而 awk 一行就能取到字段，签名与 diff 也都更方便。
#
#   schema  1
#   release 0.46.0
#   arch    arm64
#   seed    seed.tar.gz
#   size    12345678
#   sha256  <64 位十六进制>
#   url     https://host/a/seed.tar.gz
#   url     https://host/b/seed.tar.gz

# 默认种子位置。优先级：
#
#   --manifest-url / FINX_MANIFEST_URL   显式指定，最高
#   FINX_INDEX_DOMAIN                    用户给了域名，就拼 <域名>/manifest
#   GitHub Releases 上的 seed 标签        都不给时的默认，见下
#
# 为什么默认指向 Releases 而不是 finx.sh：`curl | bash` 的意义就是「不需要先
# 读文档、不需要设环境变量」。在自己的域名托管起来之前，Releases 是唯一一个
# 立刻可用的稳定地址；而 FINX_INDEX_DOMAIN 随时可以把它换掉。
# 注意：这一段在**被 source 时**求值，而 detect_host 要到 main 里才跑。
# 所以 Darwin 版本不能读 $HOST_DARWIN_MAJOR（那时还是空），就地取 uname。
_finx_darwin=$(uname -r 2>/dev/null | cut -d. -f1)
case $_finx_darwin in
    ''|*[!0-9]*) _finx_darwin=0 ;;
esac

if [ -n "${FINX_DEFAULT_MANIFEST_URL:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_DEFAULT_MANIFEST_URL
elif [ -n "${FINX_INDEX_DOMAIN_GIVEN:-}" ]; then
    DEFAULT_MANIFEST_URL=$FINX_INDEX_DOMAIN/manifest
else
    # 每个 macOS 大版本一份种子（darwin 依赖是按构建记录的，见 docs/MIRRORS.md
    # 三点六），所以默认地址要带上本机的 Darwin 主版本。
    #
    #   releases/download/seed-24/manifest     macOS 15
    #   releases/download/seed-21/manifest     macOS 12
    #
    # URL 里带 arch 与 darwin，是为了让缓存与 CDN 自然分开，也便于人工核对。
    DEFAULT_MANIFEST_URL=https://github.com/Fincote/Finx/releases/download/\
seed-$_finx_darwin/manifest
fi

# 只探存在性，不下载全文。用于决定走种子还是走源码。
#
# 返回值必须分三种，不能只有「行 / 不行」：
#
#   0  存在
#   1  确定不存在（服务端明确回了 4xx/5xx）
#   2  探不出来（连不上、超时、DNS 挂了）
#
# 为什么这点很重要：1 意味着「还没发布种子」，退回源码自举是合理的；2 意味着
# 「网络有问题」，而源码自举要去 SourceForge 下载 —— 网络有问题的地方，那条
# 路必然也走不通。把 2 当成 1，用户会看到它先说要编译十来分钟，再挂在下载上，
# 而真正该做的是检查代理或换镜像。
#
# 重试是必要的：实测同一条命令前一分钟能取到清单，下一分钟就 connect timeout。
probe_url() {
    url=$1
    tries=${FINX_PROBE_TRIES:-3}

    PROBE_ATTEMPTS=0
    total=$tries
    while [ "$tries" -gt 0 ]; do
        PROBE_ATTEMPTS=$((PROBE_ATTEMPTS + 1))
        attempt=$PROBE_ATTEMPTS
        [ "$attempt" -gt 1 ] && info "  no answer yet (attempt $attempt of $total)"

        code=$(curl -sS -o /dev/null -w '%{http_code}' -I \
            --connect-timeout 10 --max-time 20 --retry 1 "$url" 2>/dev/null) || code=000

        # HEAD 会被某些 CDN / 反爬层拒掉（403/405/501），而同一个地址用 GET
        # 取两个字节就正常。所以 HEAD 被拒时再问一次 GET。
        #
        # 000 不在此列：那表示连不上或超时，换 GET 只会把等待时间翻倍，
        # 而用户此时最需要的是尽快看到结论，不是再等一轮。
        case $code in
            403|405|429|501)
                code=$(curl -sS -o /dev/null -w '%{http_code}' -r 0-1 -L \
                    --connect-timeout 10 --max-time 20 --retry 1 "$url" 2>/dev/null) \
                    || code=000 ;;
        esac

        case $code in
            2??|3??) return 0 ;;
            # 只有这两个码能断定「确实没有」。403/429/451 是「被拦下了」，
            # 不是「不存在」—— 把它们当成不存在，用户就会被送去源码自举。
            404|410) return 1 ;;
        esac

        tries=$((tries - 1))
        [ "$tries" -gt 0 ] && sleep 2
    done
    return 2
}

# 解析清单，设置 MANIFEST_FILE / ARTIFACT_BASE / ARTIFACT_FILE /
# SEED_NAME / SEED_SIZE / SEED_SHA256 / SEED_RELEASE。
resolve_manifest() {
    ensure_tmp

    if [ -n "$SEED_DIR" ]; then
        [ -d "$SEED_DIR" ] || die "seed directory not found: $SEED_DIR"
        MANIFEST_FILE=$SEED_DIR/manifest
        ARTIFACT_BASE=$SEED_DIR
    else
        [ -n "$MANIFEST_URL" ] || die "no seed location given; use --seed-dir or --manifest-url"
        MANIFEST_FILE=$FINX_TMP/manifest
        ARTIFACT_BASE=""
        fetch_one "$MANIFEST_URL" "$MANIFEST_FILE" quiet \
            || die "$(t 'cannot download the seed manifest from' '下载种子清单失败：') $MANIFEST_URL"
    fi

    [ -f "$MANIFEST_FILE" ] || die "manifest not found: $MANIFEST_FILE"

    schema=$(manifest_field "$MANIFEST_FILE" schema)
    [ "$schema" = "1" ] || die "unsupported manifest schema: ${schema:-<missing>}"

    manifest_arch=$(manifest_field "$MANIFEST_FILE" arch)
    [ "$manifest_arch" = "$HOST_ARCH" ] \
        || die "seed is built for $manifest_arch but this host is $HOST_ARCH"

    SEED_RELEASE=$(manifest_field "$MANIFEST_FILE" release)
    SEED_NAME=$(manifest_field "$MANIFEST_FILE" seed)
    SEED_SIZE=$(manifest_field "$MANIFEST_FILE" size)
    SEED_SHA256=$(manifest_field "$MANIFEST_FILE" sha256)

    [ -n "$SEED_NAME" ] || die "$(t 'manifest has no seed entry' '清单里没有 seed 项')"
    case $SEED_NAME in
        */*) die "manifest seed name must not contain a path separator" ;;
    esac
    [ -n "$SEED_SHA256" ] || die "manifest has no sha256 entry"

    # 构建机的 darwin 主版本。老清单没有这一项，缺了就跳过检查（不能因此
    # 拒绝已经发布的旧种子）。
    SEED_DARWIN=$(manifest_field "$MANIFEST_FILE" darwin)
    case $SEED_SIZE in
        ''|*[!0-9]*) die "manifest size must be a byte count" ;;
    esac

    check_darwin_floor

    ARTIFACT_FILE=$FINX_TMP/$SEED_NAME
    info "$(t 'seed' '种子') $SEED_NAME ($(t 'release' '版本') ${SEED_RELEASE:-unknown}, $(human_size "$SEED_SIZE"))"
}

# 种子是在哪一代 Darwin 上构建的，就得在哪一代或更新的系统上装。
#
# 少了这个检查，用户会看到一个完全莫名其妙的失败：安装报告成功，文件都在，
# 但 sudo finx install <任何包> 都报
#
#   lzma depends on darwin (>= 25-1); however:
#     Version of darwin on system is 24.5.0-1.
#
# 真实踩过。早点说清楚，比让用户在装包时才撞墙好。
check_darwin_floor() {
    [ -n "${SEED_DARWIN:-}" ] || return 0
    case $SEED_DARWIN in
        ''|*[!0-9]*) return 0 ;;
    esac
    host=$(uname -r | cut -d. -f1)
    case $host in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$host" -ge "$SEED_DARWIN" ] && return 0

    msg=$(t "this seed was built on a newer macOS (Darwin $SEED_DARWIN); this system is Darwin $host" \
            "这个种子是在更新的 macOS 上构建的（Darwin $SEED_DARWIN），本机是 Darwin $host")
    die "$msg"
}

manifest_field() {
    awk -v key="$2" '$1 == key { print $2; exit }' "$1"
}

manifest_urls() {
    awk '$1 == "url" { print $2 }' "$1"
}

# 下载单个 URL 到目标路径。先写 .part，成功后再改名，因此 -C - 续传是安全的。
fetch_one() {
    url=$1
    dest=$2
    # 第三个参数：quiet 表示文件很小（清单），不要画进度。
    quiet=${3:-}

    info "GET $url"

    # 进度显示分两档：
    #   quiet       -sS，只留真正的错误。清单就两百字节，画个进度表很荒唐
    #   其余        --progress-bar（即 curl -#），一条随宽度更新的进度条，
    #               不刷行，比默认那张会重画整屏的表干净得多
    if [ -n "$quiet" ]; then
        progress_opts=(-sS)
    else
        progress_opts=(--progress-bar)
    fi

    # --speed-limit/--speed-time 是这里唯一一处「不限总时长、但要判死活」的开关：
    #
    #   --connect-timeout 只管握手；握手成功之后传输停滞，curl 会一直等下去。
    #   实测过一次种子下到 1.7 MB / 21 MB 就再也不动了，进程挂在那里无限期。
    #
    #   总时长上限会误伤慢速网络（1 KB/s 但一直在走是能装完的），所以不用
    #   --max-time；改用「连续 45 秒低于 4 KB/s 就判死」，判死之后靠 -C - 续传。
    stall=(-C - --speed-limit 4096 --speed-time 45)
    part=$dest.part
    if ! curl -fL "${progress_opts[@]}" --connect-timeout "$FINX_CONNECT_TIMEOUT" \
            --retry 3 --retry-delay 2 "${stall[@]}" -o "$part" "$url"; then
        # 退出码 33 是「服务器不支持续传」，此时从头再来一次
        rm -f "$part"
        curl -fL "${progress_opts[@]}" --connect-timeout "$FINX_CONNECT_TIMEOUT" \
            --retry 2 --retry-delay 2 --speed-limit 4096 --speed-time 45 \
            -o "$part" "$url" || {
            rm -f "$part"
            return 1
        }
    fi
    mv -f "$part" "$dest" || return 1
    return 0
}

# 取得种子产物：本地目录直接拷贝，否则按清单里的 url 逐个尝试。
fetch_artifact() {
    if [ -n "$ARTIFACT_BASE" ]; then
        src=$ARTIFACT_BASE/$SEED_NAME
        [ -f "$src" ] || die "seed artifact not found: $src"
        info "$(t 'using local artifact' '使用本地文件') $src"
        run cp -f "$src" "$ARTIFACT_FILE"
        return 0
    fi

    manifest_urls "$MANIFEST_FILE" > "$FINX_TMP/urls"

    # 清单里没写 url 时，用 FINX_SEED_DOMAIN 拼一个。这样自建镜像只要设
    # 环境变量就能用，不必为每种布局各维护一份清单。
    if [ ! -s "$FINX_TMP/urls" ]; then
        printf '%s/%s\n' "$FINX_SEED_DOMAIN" "$SEED_NAME" > "$FINX_TMP/urls"
        info "manifest has no url entries; falling back to $FINX_SEED_DOMAIN"
    fi

    tried=0
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        if fetch_one "$url" "$ARTIFACT_FILE"; then
            return 0
        fi
        warn "mirror failed: $url"
    done < "$FINX_TMP/urls"

    die "$(t 'all mirror(s) failed for' '所有镜像都下载失败：') $SEED_NAME"
}

# 体积与 SHA256 都核对；任何一项不符都中止，不做「警告后继续」。
verify_file() {
    file=$1
    want_sha=$2
    want_size=$3

    [ -f "$file" ] || die "$(t 'file is missing:' '缺少文件：') $file"

    got_size=$(file_size "$file")
    [ "$got_size" = "$want_size" ] \
        || die "$(t 'size mismatch for' '大小不符：') $SEED_NAME $(t '(expected, got)' '（期望，实际）') $want_size / $got_size"

    got_sha=$(sha256_of "$file")
    if [ "$(lower "$got_sha")" != "$(lower "$want_sha")" ]; then
        die "sha256 mismatch for $SEED_NAME: expected $want_sha, got $got_sha"
    fi
    info "$(t 'sha256 ok' 'sha256 校验通过')"
}

# ======== lib/extract.sh ========
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
# shellcheck shell=bash
#
# 落盘与收尾：解包、修权限、ad-hoc 重签名、写配置、重建索引。
# 由 install.sh 以 . 方式加载，不单独执行。

extract_seed() {
    archive=$1
    target=$2

    [ -f "$archive" ] || die "seed archive missing: $archive"
    [ -d "$target" ] || die "target directory missing: $target"

    tar -xzf "$archive" -C "$target" || die "failed to extract $archive"
}

# 前缀必须归 root 所有，不能 chown 给调用者。
#
# 两个理由，都不是风格问题：
#   1. 解决不了免密码 —— finx install 的 rootflag 是 1，只看 $>，与归属无关；
#   2. 会开提权口子 —— dpkg 以 root 执行 postinst，且 Fink 的 dpkg 打了
#      fink-bld_no_fakeroot 补丁用真 root。前缀一旦用户可写，$prefix/bin/dpkg
#      与 var/lib/dpkg/status 就成了用户可控的 root 输入。
#
# 因此以 root 安装时统一归一为 root:wheel；非 root 只可能发生在 FINX_TEST
# 沙箱或用户自己拥有的前缀里，此时不动归属。
fix_permissions() {
    target=$1

    if [ "$(id -u)" -eq 0 ]; then
        chown -R root:wheel "$target" 2>/dev/null \
            || warn "could not chown $target to root:wheel"
    else
        if [ "${ZH:-0}" -eq 1 ]; then
            warn "非 root 运行；$target 仍归 $(id -un) 所有"
        else
            warn "not running as root; $target stays owned by $(id -un)"
        fi
    fi

    for dir in "$target" "$target/bin" "$target/sbin" "$target/lib" "$target/etc"; do
        [ -d "$dir" ] && chmod 755 "$dir"
    done
    return 0
}

is_macho() {
    magic=$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case $magic in
        cffaedfe|cefaedfe|cafebabe|bebafeca) return 0 ;;
        *) return 1 ;;
    esac
}

# 改动过二进制的种子必须重签名：Apple 芯片拒跑签名失效的可执行文件。
resign_macho() {
    target=$1

    if ! have codesign; then
        warn "codesign not found; skipping ad-hoc re-signing"
        return 0
    fi

    signed=0
    for file in "$target"/bin/* "$target"/sbin/* "$target"/lib/*.dylib; do
        [ -f "$file" ] || continue
        is_macho "$file" || continue
        if codesign -f -s - "$file" >/dev/null 2>&1; then
            signed=$((signed + 1))
        fi
    done
    info "$(t 're-signed' '已重签') $signed $(t 'Mach-O file(s)' '个 Mach-O 文件')"
}

# 只在配置不存在时写：已装过的目录里那份可能有用户调整。
# 种子必须带齐「能装包」所需的东西。没有 dpkg 的种子解出来是个死目录：
# finx 起不来，用户还以为装成功了。
#
# 真实事故：bootstrap 第三阶段在 fink-mirrors 的 postinst 上中断，排在它后面
# 的 dpkg 与 tar 一个都没装，打出来的种子缺 bin/dpkg。安装器照常报「安装完成」。
# 查归档而不是查解出来的树：解完才发现就晚了一步，前缀里已经躺了半个安装，
# 下次再跑还会撞上 "does not look like a Finx installation"。
require_seed_payload() {
    archive=$1
    listing=$FINX_TMP/seed-members
    # 成员名可能带 ./ 前缀（`tar -C dir .` 会这样），也可能不带。先归一化再比，
    # 否则同一种归档换个打包方式就判定失败。
    /usr/bin/tar -tzf "$archive" 2>/dev/null | sed 's|^\./||' > "$listing" \
        || die "cannot list $archive"

    missing=""
    for f in bin/finx bin/dpkg bin/dpkg-deb; do
        grep -qxF "$f" "$listing" || missing="$missing $f"
    done
    [ -z "$missing" ] || die "the seed is incomplete, missing:$missing
       This seed cannot install anything. Rebuild it from a complete bootstrap
       (see scripts/make_seed.sh) or report the publishing side."
}

# 本机的 Distribution。bootstrap 就是这么推的：主版本号 + ".0"。
# macOS 15.5 得到 15.0 —— 与 bootstrap 打印的 "Distribution: 15.0" 一致。
host_distribution() {
    printf '%s.0\n' "$HOST_MACOS_MAJOR"
}

# 把种子里的树对齐到**本机**的 Distribution。
#
# 种子是在构建机上打的，那里 finx/<dist> 与 finx/dists 指向构建机的版本
# （例如 26.0）。装到另一台机器上，Fink 会去找 finx/<本机版本>，找不到就
# 无法定位包池。bootstrap 自己也是这么做的（bootstrap:685/690）：
#
#   finx/<distribution> -> <selfupdatetrees>     这里 selfupdatetrees 恒为 10.9-libcxx
#   finx/dists          -> <distribution>
#
# 所有 10.9 及以上的版本共用 10.9-libcxx 这一套布局，所以别名指向它就够了，
# 不需要为每个 macOS 版本重打一份种子。
align_trees() {
    target=$1
    dist=$2
    base=$target/finx
    [ -d "$base/10.9-libcxx" ] || return 0    # 不是标准布局，什么都不动

    if [ ! -e "$base/$dist" ]; then
        ln -s 10.9-libcxx "$base/$dist" 2>/dev/null \
            && info "$(t 'tree' '目录') finx/$dist -> 10.9-libcxx" \
            || warn "could not create finx/$dist"
    fi
    if [ "$(readlink "$base/dists" 2>/dev/null)" != "$dist" ]; then
        rm -f "$base/dists"
        ln -s "$dist" "$base/dists" 2>/dev/null \
            && info "$(t 'tree' '目录') finx/dists -> $dist" \
            || warn "could not point finx/dists at $dist"
    fi
}

write_config() {
    target=$1
    dist=$2
    conf=$target/etc/finx.conf

    if [ -e "$conf" ]; then
        info "$(t 'keeping existing' '保留已有的') $conf"
        return 0
    fi

    # 字段与 bootstrap 写的那份一致（bootstrap:748-753）。少任何一个 finx 都
    # 起不来 —— 之前只写 Basepath，结果 Distribution not set，scanpackages
    # 直接失败，装完等于没用。
    rootmethod=sudo
    if [ "$(id -u)" -eq 0 ] && [ -z "${SUDO_USER:-}" ]; then
        rootmethod=none
    fi

    mkdir -p "$target/etc" || die "cannot create $target/etc"
    cat > "$conf" <<EOF
# Finx configuration, created by finx-install
Basepath: $target
RootMethod: $rootmethod
Trees: local/main stable/main
Distribution: $dist
SelfUpdateTrees: 10.9-libcxx
# 与 bootstrap 写的一致：包描述自带的镜像组优先，master 垫底。
# 见 bootstrap 里同一行的注释。
MirrorOrder: MasterLast
EOF
}

run_scanpackages() {
    target=$1

    if [ ! -x "$target/bin/finx" ]; then
        warn "this seed has no $target/bin/finx; skipping the package index rebuild"
        return 0
    fi

    run "$target/bin/finx" scanpackages || warn "finx scanpackages failed; run it manually later"
    return 0
}

# ======== lib/source.sh ========
# Copyright (c) 2026 Sha0huaZhang <zsh@finx.sh>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110, USA.
#
# shellcheck shell=bash
#
# 源码回落：没有可用种子时，直接取源码树并跑它自带的 bootstrap。
#
# 为什么需要这条路：种子是「一台参考机上 bootstrap 成功之后的 /opt/finx 快照」。
# 在种子发布之前，一条命令要能用，只能退回到自举本身 —— 代价是要 Xcode
# Command Line Tools，且首次要现编 tar 与 dpkg。
#
# 无人值守：bootstrap 的所有提问都走 Fink::CLI::get_input，读到 EOF 时返回空串，
# 而每个提问都把空串解释成「取默认值」。所以把 stdin 接到 /dev/null 就等于
# 全程回车 —— 不需要改 Fink 内核，也不需要维护第二套交互逻辑。

# 源码归档位置。codeload 与 GitHub 网页的「Download ZIP」是同一个后端，
# 但返回 tar.gz，省掉解压 zip 的工具依赖。
default_source_url() {
    printf '%s/tar.gz/%s\n' "$FINX_SOURCE_DOMAIN" "${SOURCE_REF:-main}"
}

# 取并解源码树，设置 SOURCE_ROOT 为解出来的顶层目录。
fetch_source() {
    ensure_tmp

    src_url=${SOURCE_URL:-$(default_source_url)}
    info "source $src_url"

    SOURCE_ARCHIVE=$FINX_TMP/finx-source.tar.gz
    fetch_one "$src_url" "$SOURCE_ARCHIVE" \
        || die "cannot download the source archive from $src_url"

    SOURCE_ROOT=$FINX_TMP/src
    mkdir -p "$SOURCE_ROOT" || die "cannot create $SOURCE_ROOT"
    tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_ROOT" \
        || die "cannot extract $SOURCE_ARCHIVE"

    # 归档里只有一个顶层目录（Finx-<ref>/），把它找出来
    set -- "$SOURCE_ROOT"/*
    [ $# -eq 1 ] && [ -d "$1" ] || die "unexpected layout in the source archive"
    SOURCE_ROOT=$1

    [ -f "$SOURCE_ROOT/bootstrap" ] \
        || die "the source archive does not contain bootstrap"
    [ -f "$SOURCE_ROOT/VERSION" ] \
        || die "the source archive does not contain VERSION"
    info "source tree $(cat "$SOURCE_ROOT/VERSION" 2>/dev/null) at $SOURCE_ROOT"
}

# 自举的硬要求，先查再跑：免得等了半小时才在某个 make 里失败。
require_bootstrap_prerequisites() {
    [ -x /usr/bin/cc ] || die "no C compiler at /usr/bin/cc; install the Xcode Command Line Tools
       (xcode-select --install) and try again"
    [ -x /usr/bin/pod2man ] || die "no /usr/bin/pod2man; bootstrap needs it to build man pages"
    [ -x /usr/bin/perl ] || die "no /usr/bin/perl; bootstrap is a Perl script"
}

# 跑 bootstrap。第一次自举会现编 tar 与 dpkg，慢是正常的。
run_bootstrap() {
    target=$1

    require_bootstrap_prerequisites

    # bootstrap 自己会在非 root 时提问并 exec sudo，但那时 stdin 已是 /dev/null，
    # sudo 读不到密码。所以先提权，让 bootstrap 一进来就是 root。
    # 数组而不是拼字符串：代理地址里可能有空格或特殊字符，靠词分割会散架。
    sudo_cmd=()
    if [ "$(id -u)" -ne 0 ]; then
        if [ "${IN_TEST_ROOT:-0}" -eq 1 ]; then
            # 测试根里装的都是假东西，不需要真 root
            :
        else
            have sudo || die "root is required and sudo is not available"
            # sudo 从 /dev/tty 读密码，所以 stdin 接 /dev/null 也不影响
            sudo -v || die "could not obtain sudo privileges"
            sudo_cmd=(sudo)
        fi
    fi

    # 代理变量必须显式传进去：sudo 默认会重置环境，而 bootstrap 里 Fink 自己的
    # 下载是以 root 跑的。用户明明配了代理、curl 也通，却会卡在下载那一步，
    # 报的错还只会说「连不上」。
    proxy_vars=()
    for name in http_proxy https_proxy all_proxy no_proxy \
                HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
        if [ -n "${!name:-}" ]; then
            proxy_vars+=("$name=${!name}")
        fi
    done
    if [ "${#proxy_vars[@]}" -gt 0 ] && [ "${#sudo_cmd[@]}" -gt 0 ]; then
        sudo_cmd=(sudo env "${proxy_vars[@]}")
        info "passing ${#proxy_vars[@]} proxy variable(s) through sudo"
    fi

    ensure_tmp
    bootstrap_log=$FINX_TMP/bootstrap.log

    info "compiling tar and dpkg; this is the slow path"
    info "  log: $bootstrap_log"

    # ${arr[@]+"${arr[@]}"} 而不是 "${arr[@]}"：bash 3.2 在 set -u 下展开空数组
    # 会报 unbound variable（4.4 才修好）。而以 root 运行、或测试根里，
    # sudo_cmd 正好是空的。
    #
    # 默认把 bootstrap 的全部输出收进日志：它会逐条打印 mkdir、编译每一行、还有
    # 出错时的那套「该找哪个邮件列表」模板，几百行下去把真正要看的三行冲掉。
    # 失败时只回放末尾，够定位；要看全程就 --verbose。
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            2>&1 | tee "$bootstrap_log"
        rc=${PIPESTATUS[0]}
    else
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            > "$bootstrap_log" 2>&1
        rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        printf '\n' >&2
        printf 'The last lines of %s:\n' "$bootstrap_log" >&2
        tail -n 40 "$bootstrap_log" >&2 2>/dev/null || true
        printf '\n' >&2
        die "bootstrap failed (full log: $bootstrap_log)"
    fi
}

# ======== install.sh.in ========
PREFIX=/opt/finx
PREFIX_EXPLICIT=0
NO_PATH=0
SEED_DIR=""
MANIFEST_URL=${FINX_MANIFEST_URL:-}
ARCH_OVERRIDE=""
FORCE=0
VERBOSE=0
ZH=0

# 安装方式：seed 走预编译快照，source 走源码自举。resolve_method 决定用哪个。
MODE=""
FROM_SOURCE=0
ALLOW_FALLBACK=1
SOURCE_URL=""
SOURCE_REF=${FINX_SOURCE_REF:-main}
IN_TEST_ROOT=0
INSTALLED_RELEASE=""

usage() {
    cat <<'USAGE'
Usage: install.sh [options]

  --prefix=DIR        install into DIR (default /opt/finx)
  --seed-dir=DIR      use a local manifest and seed; no network access
  --manifest-url=URL  absolute URL of the seed manifest
  --arch=ARCH         override the detected architecture (arm64 / x86_64)
  --from-source       skip the seed and build from source
  --source-url=URL    source archive to build (default: codeload tar.gz)
  --ref=REF           branch or commit for the default source archive (default: main)
  --no-fallback       fail when no seed is reachable instead of building from source
  --no-path           leave your shell startup file alone
  --zh                print steps and errors in Chinese (for self-diagnosis;
                      tool output such as curl and compilers stays English)
  --verbose           stream the bootstrap output instead of logging it
  --force             replace an existing installation
  -h, --help          show this help

Environment:
  FINX_INDEX_DOMAIN   base URL for the seed manifest: when set, <this>/manifest is
                      fetched instead of the built-in default, which is a GitHub
                      Releases asset (no environment needed for a plain install)
  FINX_SEED_DOMAIN    base URL for the seed tarball when the manifest lists no url
  FINX_SOURCE_DOMAIN  base URL for the source archive when building from source
                      (default https://codeload.github.com/Fincote/Finx)
  FINX_SOURCE_REF     branch, tag or commit to pull when building from source
                      (default main); same as --ref
  FINX_CONNECT_TIMEOUT
                      seconds to wait for a connection before trying the next
                      candidate (default 30). Applies to connecting only, not to
                      how long a download may take.
  FINX_TEST=DIR       confine the whole run to DIR: the default prefix becomes
                      DIR/opt/finx, temporary files go to DIR/tmp, and --prefix
                      outside DIR is refused. Meant for tests and CI.

  https_proxy / http_proxy / all_proxy / no_proxy are honoured, including by
  the bootstrap step that runs as root (sudo resets the environment, so they
  are passed explicitly).

  Addresses must be https:// or file://; plain http is accepted only for
  http://127.0.0.1:PORT and http://localhost:PORT (offline testing).
  Changing a domain never skips verification: seeds are still checked
  against the sha256 and size in the manifest.

Examples:
  FINX_TEST=/tmp/finx-check ./finx-install/install.sh --seed-dir=/tmp/seed
  curl -fsSL <install.sh> | sudo bash
USAGE
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            --prefix=*)       PREFIX=${1#*=}; PREFIX_EXPLICIT=1 ;;
            --prefix)         shift; [ $# -gt 0 ] || die "--prefix needs a value"; PREFIX=$1; PREFIX_EXPLICIT=1 ;;
            --seed-dir=*)     SEED_DIR=${1#*=} ;;
            --seed-dir)       shift; [ $# -gt 0 ] || die "--seed-dir needs a value"; SEED_DIR=$1 ;;
            --manifest-url=*) MANIFEST_URL=${1#*=} ;;
            --manifest-url)   shift; [ $# -gt 0 ] || die "--manifest-url needs a value"; MANIFEST_URL=$1 ;;
            --arch=*)         ARCH_OVERRIDE=${1#*=} ;;
            --arch)           shift; [ $# -gt 0 ] || die "--arch needs a value"; ARCH_OVERRIDE=$1 ;;
            --from-source)    FROM_SOURCE=1 ;;
            --source-url=*)   SOURCE_URL=${1#*=} ;;
            --source-url)     shift; [ $# -gt 0 ] || die "--source-url needs a value"; SOURCE_URL=$1 ;;
            --ref=*)          SOURCE_REF=${1#*=} ;;
            --ref)            shift; [ $# -gt 0 ] || die "--ref needs a value"; SOURCE_REF=$1 ;;
            --no-fallback)    ALLOW_FALLBACK=0 ;;
            --no-path)        NO_PATH=1 ;;
            --zh)             ZH=1 ;;
            --verbose)        VERBOSE=1 ;;
            --force)          FORCE=1 ;;
            -h|--help)        usage; exit 0 ;;
            --)               shift; break ;;
            *)                die "unknown option: $1" ;;
        esac
        shift
    done

    case $PREFIX in
        /*) ;;
        *) die "--prefix must be an absolute path" ;;
    esac
    case $PREFIX in
        */) die "--prefix must not end with a slash" ;;
    esac
}

check_target() {
    state=$(target_state "$PREFIX")
    case $state in
        absent) ;;
        empty)
            warn "$PREFIX exists and is empty; continuing" ;;
        existing)
            [ "$FORCE" -eq 1 ] || die "$PREFIX already holds an installation; re-run with --force to replace it"
            warn "$(t 'replacing the existing installation in' '覆盖已安装的内容：') $PREFIX" ;;
        *)
            [ "$FORCE" -eq 1 ] || die "$PREFIX is not empty and does not look like a Finx installation.
       This is usually what a source build leaves behind when it stops halfway.
       Inspect it, then either remove it or re-run with --force:
         sudo ls -la $PREFIX
         sudo rm -rf $PREFIX"
            warn "$PREFIX is not a Finx installation; continuing because --force was given" ;;
    esac
}

# 装完之后 finx 还不在 PATH 上 —— 子进程改不了父 shell 的环境变量，
# 所以只有两条路：让用户自己 source，或写进 shell 的启动文件。
#
# 这里不自动写启动文件。这个安装器的典型用法是 `curl ... | bash`，
# 在用户没看清的情况下改 .zprofile 是坏做法，而且改错了很难发现。
# 所以：按用户的登录 shell 给出**精确到文件**的那一行，用户可以复制粘贴；
# 想让它代劳的，指向随包安装的 pathsetup.sh。
# ---------------------------------------------------------------------------
# 让 finx 在当前 shell 与今后的 shell 里都能直接用
# ---------------------------------------------------------------------------
#
# 脚本改不了父 shell 的 PATH —— 子进程影响不了父进程。所以能做的只有两件：
# 写进 shell 的启动文件（持久），以及告诉用户这一句怎么 source（当次生效）。
#
# 写启动文件有个必须小心的前提：安装器可能以 root 跑（`curl | sudo bash`），
# 那时 $HOME 是 /var/root。往 root 的 .zprofile 里加东西既没用又有害。
# 所以先解析出「真正在用的那个用户」的家目录（$SUDO_USER + Directory
# Services），写完之后再把属主改回去。

# 正在以 root 跑时，找出调用者的家目录；否则就是 $HOME。
target_home() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        # 不能写 ~/$SUDO_USER —— 那会拿到 /var/root/xxx。要问 Directory Services。
        home=$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [ -n "$home" ] && [ -d "$home" ]; then
            printf '%s\n' "$home"
            return 0
        fi
        return 1
    fi
    printf '%s\n' "$HOME"
}

login_shell_name() {
    # 先问 Directory Services 要「这个人的登录 shell」，而不是看 $SHELL。
    #
    # sudo 会把 SHELL 换成 root 的（通常是 /bin/sh），于是 zsh 用户被写进了
    # ~/.profile —— 他们的 shell 根本不读那个文件，装完等于没配 PATH。
    # 实测踩过。
    _user=${SUDO_USER:-}
    if [ -z "$_user" ] || [ "$_user" = root ]; then
        _user=$(id -un 2>/dev/null)
    fi
    if [ -n "$_user" ]; then
        _shell=$(dscl . -read "/Users/$_user" UserShell 2>/dev/null | awk '{print $2}')
        if [ -n "$_shell" ]; then
            basename "$_shell"
            return 0
        fi
    fi
    basename "${SHELL:-/bin/zsh}"
}

# 该往哪个启动文件里写。zsh 用 .zprofile（登录 shell 会读），bash 优先
# .bash_profile（存在才是它），csh 用 .cshrc。
shell_rc_path() {
    home=$1
    case $(login_shell_name) in
        zsh)  printf '%s/.zprofile\n' "$home" ;;
        bash)
            if [ -f "$home/.bash_profile" ]; then
                printf '%s/.bash_profile\n' "$home"
            else
                printf '%s/.profile\n' "$home"
            fi ;;
        csh|tcsh) printf '%s/.cshrc\n' "$home" ;;
        *)    printf '%s/.profile\n' "$home" ;;
    esac
}

# 要写进去的那一行。带 test -r 是为了在 finx 被删掉之后不会让每个新
# shell 都报一次错。
shell_source_line() {
    case $(login_shell_name) in
        csh|tcsh) printf 'test -r %s/bin/init.csh && source %s/bin/init.csh\n' "$PREFIX" "$PREFIX" ;;
        *)        printf 'test -r %s/bin/init.sh && . %s/bin/init.sh\n' "$PREFIX" "$PREFIX" ;;
    esac
}

# 只打印，不写。写失败、或用户明确不要时用。
print_path_help() {
    printf '\n'
    if [ "${ZH:-0}" -eq 1 ]; then
        printf '在当前这个 shell 里立即生效：\n'
        printf '    . %s/bin/init.sh\n' "$PREFIX"
        printf '\n'
        printf '要长期生效，把下面这行加进 shell 启动文件：\n'
        printf '    %s\n' "$(shell_source_line)"
        printf '\n'
        printf '或者不加 --no-path 重跑一次安装器，它会替你写。\n'
        printf '\n'
        printf '注意：finx 用自己的前缀，不会遮蔽 /sw 下可能已存在的 Fink 安装。\n'
    else
        printf 'To use finx in this shell now:\n'
        printf '    . %s/bin/init.sh\n' "$PREFIX"
        printf '\n'
        printf 'To make it permanent, add this line to your shell startup file:\n'
        printf '    %s\n' "$(shell_source_line)"
        printf '\n'
        printf 'Or re-run this installer without --no-path to have it done for you.\n'
        printf '\n'
        printf 'Note: finx uses its own prefix, so it never shadows a Fink\n'
        printf 'installation that may already be present under /sw.\n'
    fi
}

# 默认就写。--no-path 关掉。
setup_path() {
    if [ "$NO_PATH" -eq 1 ]; then
        info "$(t 'leaving your shell configuration alone (--no-path)' '不动你的 shell 配置（--no-path）')"
        print_path_help
        return 0
    fi

    home=$(target_home) || {
        warn "cannot determine the invoking user's home directory"
        print_path_help
        return 0
    }

    rc=$(shell_rc_path "$home")
    line=$(shell_source_line)

    # 幂等：已经有了就别重复追加。
    if grep -qxF "$line" "$rc" 2>/dev/null; then
        info "$(t 'PATH setup already present in' 'PATH 已配置在') $rc"
    elif printf '\n# Finx: put finx on PATH\n%s\n' "$line" >> "$rc" 2>/dev/null; then
        info "$(t 'added finx to PATH in' '已把 finx 加入 PATH：') $rc"
        # 以 root 写进别人的文件后要把属主还回去，否则那个用户今后改不了它。
        if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER" "$rc" 2>/dev/null \
                || warn "could not chown $rc back to $SUDO_USER"
        fi
    else
        warn "could not write $rc"
        print_path_help
        return 0
    fi

    printf '\n'
    if [ "${ZH:-0}" -eq 1 ]; then
        printf 'finx 已在新的终端里可用。当前这个终端需要手动加载：\n'
    else
        printf 'finx is now on PATH for new shells. For this one, run:\n'
    fi
    printf '    . %s/bin/init.sh\n' "$PREFIX"
}

main() {
    case ${FINX_LANG:-} in
        zh|zh_CN|zh-CN) ZH=1 ;;
    esac
    parse_args "$@"
    apply_test_root

    step "$(t 'Checking host' '检查主机')"
    detect_host
    [ -n "$ARCH_OVERRIDE" ] && HOST_ARCH=$ARCH_OVERRIDE
    info "macOS $HOST_MACOS_MAJOR, arch $HOST_ARCH, prefix $PREFIX"
    require curl

    step "$(t 'Choosing install method' '选择安装方式')"
    resolve_method

    case $MODE in
        seed)   install_from_seed ;;
        source) install_from_source ;;
    esac

    printf '\n'
    info "$(t 'Finx' 'Finx') ${INSTALLED_RELEASE:-unknown} $(t 'installed in' '已安装到') $PREFIX"
    setup_path
    info "$(t 'Package operations run as root, like MacPorts; finx asks for sudo itself.' \
             '装包操作以 root 运行（与 MacPorts 相同），finx 会自己调用 sudo。')"
}

# 种子优先，取不到再退回源码。显式给了 --seed-dir / --manifest-url 时不回落，
# 因为那说明调用方指定了来源，静默换源会让校验失去意义。
resolve_method() {
    if [ -n "$SEED_DIR" ] || [ -n "$MANIFEST_URL" ]; then
        MODE=seed
        info "$(t 'seed, from an explicit location' '种子，来自显式指定的位置')"
        return 0
    fi

    if [ "$FROM_SOURCE" -eq 1 ]; then
        MODE=source
        info "$(t 'source, because --from-source was given' '源码，因为给了 --from-source')"
        return 0
    fi

    if [ "$ALLOW_FALLBACK" -eq 0 ]; then
        MODE=seed
        info "$(t 'seed, from the default manifest' '种子，来自默认清单')"
        return 0
    fi

    MANIFEST_URL=$DEFAULT_MANIFEST_URL
    # 探测最多要一两分钟（重试 + 超时），期间不能一声不响 —— 用户会以为卡死。
    info "$(t 'looking for a seed manifest' '正在查找种子清单')"
    info "  $MANIFEST_URL"
    probe_url "$MANIFEST_URL"
    case $? in
        0)
            MODE=seed
            info "$(t 'seed, from' '种子，来自') $MANIFEST_URL" ;;
        1)
            MODE=source
            warn "no seed manifest at $MANIFEST_URL yet; falling back to a source build"
            warn "that path needs the Xcode Command Line Tools and compiles tar and dpkg" ;;
        *)
            # 探不出来 ≠ 没有种子。源码那条路要去 SourceForge 下载，连不上
            # GitHub 的地方通常也连不上它，所以这里直接停下并说清怎么绕。
            #
            # 提示必须能照着做。这里有三个坑，写错过：
            #   1. 代理那条不能写成 `export https_proxy=...`：用户是在
            #      `curl | sudo bash` 里跑的，sudo 默认清空环境，export 白做。
            #      要写成 `sudo https_proxy=... bash`（命令行赋值 sudo 会保留）。
            #   2. 不能建议 --from-source。上面刚说了它更不可达，还让人去试，
            #      等于把人往死路上引。
            #   3. 要给出「用现成的种子」这条路 —— 那是网络不通时唯一真有
            #      可能成功的方式。
            printf '\n' >&2
            printf 'ERROR: cannot reach the seed manifest after %s attempt(s).\n' \
                "${PROBE_ATTEMPTS:-?}" >&2
            printf '         %s\n' "$MANIFEST_URL" >&2
            printf '\n' >&2
            printf 'Nothing was installed.  This is a network problem, not a missing seed:\n' >&2
            printf 'that manifest is a small text file, and the seed behind it is larger.\n' >&2
            printf '\n' >&2
            printf 'What is worth trying, in order:\n' >&2
            printf '\n' >&2
            printf '  1. Through a proxy.  Note the variables go on the sudo line: sudo\n' >&2
            printf '     clears the environment, so an exported variable would not arrive.\n' >&2
            printf '       curl -fsSL <this URL> | sudo https_proxy=http://127.0.0.1:7890 bash\n' >&2
            printf '\n' >&2
            printf '  2. From a copy of the seed you already have.  No network at all:\n' >&2
            if [ -n "$(self_path)" ]; then
                printf '       sudo bash %s --seed-dir=<dir with manifest and seed.tar.gz>\n' "$(self_path)" >&2
            else
                printf '       sudo bash <install.sh> --seed-dir=<dir with manifest and seed.tar.gz>\n' >&2
            fi
            printf '\n' >&2
            printf '  3. Through a mirror you trust:\n' >&2
            printf '       curl -fsSL <this URL> | sudo FINX_INDEX_DOMAIN=https://your-mirror/finx/seed bash\n' >&2
            printf '     %s\n' "Layout: docs/MIRRORS.md" >&2
            printf '\n' >&2
            printf 'A source build is not suggested: --from-source downloads from\n' >&2
            printf 'SourceForge, which this network is unlikely to reach either.\n' >&2
            exit 1 ;;
    esac
}

install_from_seed() {
    step "$(t 'Resolving seed manifest' '解析种子清单')"
    resolve_manifest

    step "$(t 'Checking target' '检查目标目录')"
    check_target
    require_write_access "$PREFIX"

    step "$(t 'Obtaining' '获取') $SEED_NAME"
    fetch_artifact

    # 先校验再动目标目录：失败时不该留下一个空壳
    step "$(t 'Verifying' '校验')"
    verify_file "$ARTIFACT_FILE" "$SEED_SHA256" "$SEED_SIZE"

    require_seed_payload "$ARTIFACT_FILE"

    step "$(t 'Preparing' '准备') $PREFIX"
    do_mkdir "$PREFIX"

    step "$(t 'Extracting' '解包')"
    extract_seed "$ARTIFACT_FILE" "$PREFIX"


    step "$(t 'Finalizing' '收尾')"
    fix_permissions "$PREFIX"
    resign_macho "$PREFIX"
    align_trees "$PREFIX" "$(host_distribution)"
    write_config "$PREFIX" "$(host_distribution)"
    run_scanpackages "$PREFIX"

    INSTALLED_RELEASE=${SEED_RELEASE:-unknown}
}

install_from_source() {
    step "$(t 'Checking target' '检查目标目录')"
    check_target
    require_write_access "$PREFIX"

    step "$(t 'Obtaining the source tree' '获取源码树')"
    fetch_source

    # bootstrap 自己会创建前缀并写配置、建索引，这里不再重复一遍
    step "$(t 'Bootstrapping' '自举')"
    run_bootstrap "$PREFIX"

    INSTALLED_RELEASE=$(cat "$SOURCE_ROOT/VERSION" 2>/dev/null || echo unknown)
}

main "$@"
