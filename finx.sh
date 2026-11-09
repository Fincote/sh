#!/bin/bash
#
# finx-install/install.sh - 从零安装 Finx
#
# 这是**唯一源文件**，直接编辑它。用户 curl 的也是它。
#
# 曾经拆成 install.sh.in + lib/*.sh 再由 build-bundle.sh 拼成单文件 ——
# 那套机制已经去掉：单文件 2000 行可以直接维护，而模板 + 生成物 + 同步校验
# 带来的麻烦（改了生成物会被下次构建静默覆盖）超过它省下的力气。
#
# 用法：/bin/bash -c "$(curl -fsSL <本文件的地址>)" -- [选项]
#

set -eE
set -u
set -o pipefail

# ---- 输出、错误、trap、临时目录 -------------------------------------------
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
# 屏幕输出：颜色与横幅
# ---------------------------------------------------------------------------
#
# 用 echo -e：脚本的 shebang 是 bash（见 62529dd5 统一过），bash 内建的 echo
# 认 -e。项目约定如此，横幅内容也不含需要转义的东西。

RED_BOLD='\033[1;31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BOLD_BLUE='\033[1;38;5;25m'
BOLD='\033[1m'
RESET='\033[0m'

# 程序标记，与 finx 本体的 Fink::Color::$PROG_MARK 同一个字（那里写成 UTF-8
# 字节，因为 Perl 的 STDOUT 没有 :utf8 层；bash 直接写字面量即可）。
# 定义在这里而不是 warn/die 旁边：下面两处「还没读到函数定义就得报错」的
# 校验也要用它。
MARK='🧩'

print_banner() {
    echo ""
    echo -e "${GREEN}███████╗██╗███╗   ██╗██╗  ██╗${RESET}"
    echo -e "${GREEN}██╔════╝██║████╗  ██║╚██╗██╔╝${RESET}"
    echo -e "${GREEN}█████╗  ██║██╔██╗ ██║ ╚███╔╝ ${RESET}"
    echo -e "${GREEN}██╔══╝  ██║██║╚██╗██║ ██╔██╗ ${RESET}"
    echo -e "${GREEN}██║     ██║██║ ╚████║██╔╝ ██╗${RESET}"
    echo -e "${GREEN}╚═╝     ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝${RESET}"
    echo ""
    echo -e "${GREEN}$(t 'Welcome to FINX!' '欢迎使用 FINX！')${RESET}"
    echo ""
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

    printf "${RED_BOLD}%s ERROR: %s must be an https:// (or file://) address, got: %s${RESET}\n" \
        "$MARK" "$_finx_name" "$_finx_value" >&2
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

# 种子放在哪。默认 GitHub Releases；自建镜像按同样布局提供即可：
#   <基址>/seed-<Darwin>/manifest
#   <基址>/seed-<Darwin>/seed.tar.gz
# 单独抽出来有两个理由：安装器要「往下试更老的种子」，得能拼出多个地址；
# 测试要能用 file:// 模拟「本机这一版没有、低一档有」。
FINX_SEED_BASE=$(finx_domain FINX_SEED_BASE "${FINX_SEED_BASE:-https://github.com/Fincote/Finx/releases/download}") || exit 1
export FINX_SEED_BASE

# 预编译 .deb 的取处。形状是 Bottle 式的「一包一 Release」：
#   <域名>/<包名>/<包名>@<版本>-<修订>.darwin<Darwin>-<架构>.deb
# 默认指向我们自己的 debs 仓库。镜像站只要提供「域名之后那两段」的相对路径。
FINX_DEB_DOMAIN=$(finx_domain FINX_DEB_DOMAIN "${FINX_DEB_DOMAIN:-https://github.com/Fincote/debs/releases/download}") || exit 1
export FINX_DEB_DOMAIN

# 源码自举时取源码归档的地方，默认 GitHub 的 codeload。
FINX_SOURCE_DOMAIN=$(finx_domain FINX_SOURCE_DOMAIN "${FINX_SOURCE_DOMAIN:-https://codeload.github.com/Fincote/Finx}") || exit 1
export FINX_SOURCE_DOMAIN

# 连不上的等待时间。默认 30 秒；网络差的用户调小能更快地换下一个候选。
# 只管"连上"，不管"下完"——种子可能几十兆，给总时长设上限只会把慢速网络
# 的人挡在门外。
# 这里用裸 printf 而不是 die()：die 定义在后面，且本文件按顺序被 source。
case ${FINX_CONNECT_TIMEOUT:-30} in
    ''|*[!0-9]*)
        printf "${RED_BOLD}%s ERROR: FINX_CONNECT_TIMEOUT must be a whole number of seconds, got: %s${RESET}\n" \
            "$MARK" "$FINX_CONNECT_TIMEOUT" >&2
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
    echo ""
    echo -e "${BOLD_BLUE}==>${RESET} ${BOLD}$*${RESET}"
}

# 许可协议确认。
#
# 位置与 MacWave 一致：装完了，但还没告诉用户「装好了」。先宣告成功再因为
# 不同意而删掉，是最难看的顺序。
#
# 三道门，按顺序：
#   1. --ci（或 --accept-license）→ 自动同意并说明（给脚本与自动化用）
#   2. FINX_TEST 沙箱             → 自动同意（那里本来就不会碰真实系统）
#   3. 其余                       → 读 /dev/tty 问一次
#
# 为什么读 /dev/tty 而不是 stdin：`curl | sudo bash` 时 stdin 是脚本自身，
# 读它会吃掉脚本剩下的内容。这也是 MacWave 用 /dev/tty 的原因。
license_gate() {
    if dry_run; then
        plan "$(t 'ask you to accept the licence' '询问是否接受许可协议')"
        return 0
    fi

    if [ "$CI" -eq 1 ]; then
        if [ "$ACCEPT_LICENSE" -eq 1 ]; then
            info "$(t 'agreement accepted with --accept-license' \
                     '已用 --accept-license 接受协议')"
        else
            info "$(t '--ci: the agreement is accepted automatically' \
                     '--ci：自动接受协议')"
        fi
        return 0
    fi

    if [ -n "${FINX_TEST:-}" ]; then
        info "$(t 'sandbox run: the agreement is accepted automatically' \
                 '沙箱运行：自动接受协议')"
        return 0
    fi

    echo -e "${YELLOW}$(t 'Finx is released under the GPL v2. Read both files before you agree:
    LICENSE   which part of the tree carries which grant
    COPYING   the licence text itself
    https://finx.sh/#license-en' \
     'Finx 以 GPL v2 发布。同意之前请先读这两个文件：
    LICENSE   哪些目录适用哪个授权
    COPYING   许可证正文
    https://finx.sh/#license')${RESET}"

    # 不能用 `[ -r /dev/tty ]`：那查的是权限，而设备节点谁都「可读」。
    # 没有控制终端时 access(R_OK) 仍然成功，打开才失败（ENXIO）。
    # 实测过：写成 [ -r ] 时门形同虚设，`curl | sudo bash` 会直接越过协议确认。
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        die "$(t 'no terminal to ask for agreement, so --ci is required.
Re-run interactively, or pass --ci after reading both files.' \
         '没有终端可以询问协议，因此必须显式传入 --ci。
请改为交互运行，或在读过这两个文件后传入 --ci。')"
    fi

    echo -e "${YELLOW}$(t 'Have you read and agree to them? [Y/n]' \
                            '你是否已阅读并同意？[Y/n]')${RESET} " >&3
    answer=""
    read -r answer <&3 || answer=""
    exec 3<&-

    case $answer in
        ''|y|Y|yes|YES)
            echo -e "${GREEN}$(t 'You have agreed to the agreement.' \
                                '已记录你的同意。')${RESET}" ;;
        *)
            echo -e "${RED_BOLD}${MARK} $(t 'You do not agree to the agreement. Installation stopped.' \
                                    '你未同意该协议，安装已停止。')${RESET}" >&2
            agreement_rollback
            exit 1 ;;
    esac
}

# 拒签后的清理。只删**这次真正新建**的前缀。
#
# `--force` 覆盖的是用户原有的安装，删掉就等于把人家原来的东西一并毁了，
# 那种情况只能报错、不能动手 —— 这时用户手上仍是一个能用的前缀，只是没被
# 放上 PATH、也没被告知安装成功。
agreement_rollback() {
    case ${PREFIX_WAS:-unknown} in
        absent)
            info "$(t 'removing' '正在删除') $PREFIX"
            if rm -rf "$PREFIX"; then
                echo -e "${RED_BOLD}${MARK} $(t 'Everything this run created has been removed.' \
                                        '本次创建的内容已全部删除。')${RESET}" >&2
            else
                warn "$(t "could not remove $PREFIX; inspect it by hand" \
                         "没能删除 $PREFIX，请手工检查")"
            fi ;;
        empty)
            info "$(t "$PREFIX was empty before this run; it is empty again" \
                     "$PREFIX 在这次运行之前就是空的，现已恢复为空")" ;;
        *)
            warn "$(t "$PREFIX was already there before this run, so it was not removed." \
                     "$PREFIX 在这次运行之前就存在，因此未删除。")"
            info "$(t 'Remove it yourself if you want it gone:' \
                     '如果要清掉它，请自行删除：')"
            info "  sudo rm -rf $PREFIX" ;;
    esac
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

# 诊断消息的样式与 finx 本体一致：段首一个 🧩（Fink::Color 的 $PROG_MARK，
# 那里写成 UTF-8 字节；这里是 bash，直接写字面量），错误用 RED_BOLD、警告用
# YELLOW。两个函数是所有 stderr 提示的**唯一**出口 —— 散在各处 printf 的话，
# 迟早有一条忘了上色。
warn() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf "${YELLOW}%s 警告: %s${RESET}\n" "$MARK" "$*" >&2
    else
        printf "${YELLOW}%s WARNING: %s${RESET}\n" "$MARK" "$*" >&2
    fi
}

die() {
    if [ "${ZH:-0}" -eq 1 ]; then
        printf "${RED_BOLD}%s 错误: %s${RESET}\n" "$MARK" "$*" >&2
    else
        printf "${RED_BOLD}%s ERROR: %s${RESET}\n" "$MARK" "$*" >&2
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

# ---- 试运行 ---------------------------------------------------------------
#
# 走完整条流程、把每一步会做什么打出来，但不下载、不建目录、不写文件、
# 不提权。仿 MacWave 的 install.sh：一个判断函数 + 一个打印函数，调用点
# 因此不必自己套 if，也就不容易漏。
#
# 为什么不在最外层拦一道就算了：那样只能打印一份笼统的计划，用户看不到
# 解包、重签名、写配置这些具体步骤。而漏掉某个写点的后果更糟 —— 变成
# 「说好只是预演，实际却动了东西」，这个安装器早期版本正是这么错的。
dry_run() {
    [ "${DRY_RUN:-0}" -eq 1 ]
}

# 试运行时把「本来会发生什么」打出来；不在试运行时一个字都不输出。
plan() {
    dry_run || return 0
    info "$(t 'would' '将会') $*"
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
# 把 URL 里的凭据抹掉再打印。
#
# 镜像可以带账号：FINX_SEED_DOMAIN=https://user:pass@mirror/finx。安装器会把
# 它打印出来（GET 行、失败提示、清单地址），而终端输出会进 CI 日志、截图、
# issue —— 密码就这么跟着走了。只抹 userinfo，其余原样保留，否则报错里看不出
# 是哪个主机。
redact_url() {
    printf '%s\n' "$1" | sed -E 's|^([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@]*@|\1***:***@|'
}

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

# ---- 宿主探测与目标目录 ---------------------------------------------------
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
        if dry_run; then
            # 预演本来就不提权，也不该因为「要 sudo」停下来 —— 那正是它要告诉
            # 用户的事。这里只说一句，然后继续打后面的步骤。
            warn "$(t 'a real run would need root to write into' '真正安装需要 root 才能写入') $probe"
            return 0
        fi
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
    if dry_run; then
        plan "$(t 'create' '建立') $1"
        return 0
    fi
    run mkdir -p -m 755 "$1"
}

# ---- 种子清单：解析、下载、校验 -------------------------------------------
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
    # 这里只给「本机那一版」的地址。往下找更低版本是 resolve_method 的事 ——
    # 它手上有 probe_url，能逐个试；这里只是一个起点。
    DEFAULT_MANIFEST_URL=$FINX_SEED_BASE/seed-$_finx_darwin/manifest
fi

# 本机 Darwin 主版本，供 resolve_method 往下找时用。
FINX_HOST_DARWIN=$_finx_darwin
export FINX_HOST_DARWIN

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
#
# 结果放进 PROBE_RESULT，取值只有三个字面量：
#
#   exists    地址在（2xx/3xx）
#   absent    服务端明确说没有（404/410）
#   unknown   探不出来（连不上、超时、被 403/429 拦住、以及一切没预料到的情况）
#
# **函数本身永远 return 0**，调用方读 $PROBE_RESULT，不读退出码。
#
# 为什么不沿用「0/1/2 三种退出码」：退出码没有语义，任何一处意外的失败都可能
# 恰好是 1，于是一个本该报「探不出来」的故障会被当成「这一档没有种子」——
# 结果是一路往下试到最低那一档，再默默回退去编译半小时。那种错误不报错，
# 只是慢，最难发现。用三态字符串，未预料的情况只能落到 unknown。
probe_url() {
    url=$1
    tries=${FINX_PROBE_TRIES:-3}

    PROBE_RESULT=unknown

    # file:// 不走网络，curl -I 也能取到，但拿回来的 http_code 是 000，
    # 于是「文件明明在」被判定成「连不上」。FINX_INDEX_DOMAIN 接受 file://
    # （离线测试、本地镜像都靠它），这条路径必须能一致地探到。
    case $url in
        file://*)
            if [ -f "${url#file://}" ]; then
                PROBE_RESULT=exists
            else
                PROBE_RESULT=absent
            fi
            return 0 ;;
    esac

    PROBE_ATTEMPTS=0
    total=$tries
    # 每一次都要说一声，不只是重试那次。弱网下第一探就能耗掉二十秒，期间一个
    # 字都没有，与「卡死」在用户眼里是同一件事。
    info "  $(t 'waiting for an answer (up to' '等待应答（最多') $((total * 20)) $(t 'seconds)' '秒）')"
    while [ "$tries" -gt 0 ]; do
        PROBE_ATTEMPTS=$((PROBE_ATTEMPTS + 1))
        attempt=$PROBE_ATTEMPTS
        [ "$attempt" -gt 1 ] && info "  $(t 'no answer yet, attempt' '还没有应答，第') $attempt $(t 'of' '次，共') $total"

        # 不写 --retry：它让一次「尝试」在最坏情况下翻倍到四十秒，而外面这层
        # 本来就重试三次。去掉之后单次最多二十秒，总时长可预期。
        code=$(curl -sS -o /dev/null -w '%{http_code}' -I \
            --connect-timeout 10 --max-time 20 "$url" 2>/dev/null) || code=000

        # HEAD 会被某些 CDN / 反爬层拒掉（403/405/501），而同一个地址用 GET
        # 取两个字节就正常。所以 HEAD 被拒时再问一次 GET。
        #
        # 000 不在此列：那表示连不上或超时，换 GET 只会把等待时间翻倍，
        # 而用户此时最需要的是尽快看到结论，不是再等一轮。
        case $code in
            403|405|429|501)
                code=$(curl -sS -o /dev/null -w '%{http_code}' -r 0-1 -L \
                    --connect-timeout 10 --max-time 20 "$url" 2>/dev/null) \
                    || code=000 ;;
        esac

        case $code in
            2??|3??) PROBE_RESULT=exists; return 0 ;;
            # 只有这两个码能断定「确实没有」。403/429/451 是「被拦下了」，
            # 不是「不存在」—— 把它们当成不存在，用户就会被送去源码自举。
            404|410) PROBE_RESULT=absent; return 0 ;;
        esac

        tries=$((tries - 1))
        [ "$tries" -gt 0 ] && sleep 2
    done
    PROBE_RESULT=unknown
    return 0
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
            || die "$(t 'cannot download the seed manifest from' '下载种子清单失败：') $(redact_url "$MANIFEST_URL")"
    fi

    [ -f "$MANIFEST_FILE" ] || die "manifest not found: $MANIFEST_FILE"

    schema=$(manifest_field "$MANIFEST_FILE" schema)
    [ "$schema" = "1" ] || die "unsupported manifest schema: ${schema:-<missing>}"

    # 清单存在不等于种子能用：种子是按 arch 与 darwin 构建的，别的机器上的
    # 种子装不进来。自动发现时要把这件事当成「这份种子不是给你的」，退回源码；
    # 显式指定来源时仍然直接拒绝 —— 调用方说了就用这份，静默换源会让校验失去意义。
    manifest_arch=$(manifest_field "$MANIFEST_FILE" arch)
    if [ "$manifest_arch" != "$HOST_ARCH" ]; then
        SEED_HOST_MISMATCH="seed is built for $manifest_arch but this host is $HOST_ARCH"
    fi

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

    if [ -n "${SEED_HOST_MISMATCH:-}" ]; then
        [ "${SEED_MAY_FALL_BACK:-0}" -eq 1 ] || die "$SEED_HOST_MISMATCH"
        return 0
    fi

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
    SEED_HOST_MISMATCH=$msg
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

    info "GET $(redact_url "$url")"

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
    if dry_run; then
        plan "$(t 'download' '下载') $SEED_NAME ($(human_size "${SEED_SIZE:-0}"))"
        return 0
    fi

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
        info "manifest has no url entries; falling back to $(redact_url "$FINX_SEED_DOMAIN")"
    fi

    tried=0
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        if fetch_one "$url" "$ARTIFACT_FILE"; then
            return 0
        fi
        warn "mirror failed: $(redact_url "$url")"
    done < "$FINX_TMP/urls"

    die "$(t 'all mirror(s) failed for' '所有镜像都下载失败：') $SEED_NAME"
}

# 体积与 SHA256 都核对；任何一项不符都中止，不做「警告后继续」。
verify_file() {
    file=$1
    want_sha=$2
    want_size=$3

    if dry_run; then
        plan "$(t 'check its sha256 and size' '校验 sha256 与大小') ($(human_size "${want_size:-0}"))"
        return 0
    fi

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

# ---- 解包、权限、重签名、写配置 -------------------------------------------
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

    # 试运行的守卫必须在文件检查之前：`--dry-run` 不下载、也不拷本地种子，
    # ARTIFACT_FILE 那个文件根本不存在，先检查就会把试运行判成失败。
    if dry_run; then
        plan "$(t 'extract' '解开') $archive $(t 'into' '到') $target"
        return 0
    fi

    [ -f "$archive" ] || die "seed archive missing: $archive"
    [ -d "$target" ] || die "target directory missing: $target"

    tar -xzf "$archive" -C "$target" || die "failed to extract $archive"

    # 解包之后、任何东西碰这棵树之前。越界链接本身不会伤人，危险的是顺着它去读
    # 或去写 —— 而下一步 resign_macho 就会走遍整棵树、run_scanpackages 会执行
    # 树里的 bin/finx。所以检查必须卡在这里，且失败时清空前缀：半装好的树比
    # 没装更危险。
    offending=$(offending_links "$target")
    if [ -n "$offending" ]; then
        find "$target" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        die "the seed contains $(printf '%s\n' "$offending" | wc -l | tr -d ' ') symbolic link(s) pointing outside $target:
$offending
       Only these locations are exempt: $FINX_LINK_EXEMPT
       Refusing this payload. Report it to whoever built the seed."
    fi
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
    if dry_run; then
        plan "$(t 'set ownership and modes under' '规范权限') $target"
        return 0
    fi
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
    if dry_run; then
        plan "$(t 'ad-hoc re-sign the Mach-O files under' '重签 Mach-O') $target"
        return 0
    fi
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
    if dry_run; then
        plan "$(t 'confirm the archive really contains' '确认归档里有') bin/finx bin/dpkg bin/dpkg-deb"
        return 0
    fi
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
    if dry_run; then
        plan "$(t 'point the tree links in' '对齐 trees') $target/finx $(t 'at' '到') $dist"
        return 0
    fi
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

# 修复 bootstrap 时代留下的 alternatives 链接。
#
# 种子里 bin/lzdiff、bin/lzgrep 与它们两个 man 页是绝对链接，指向
# <prefix>/bootstrap/etc/alternatives/... —— 而 bootstrap/ 在收尾时被删掉了，
# 于是装完就是死链：`lzdiff --version` 报 No such file or directory。
#
# 数据库本身是好的（var/lib/dpkg/alternatives 里记的路径都指向前缀），缺的只是
# 主链接和 bin 下那条链接的内容。所以让 update-alternatives 照数据库自己重建，
# 比在安装器里硬编码 lzdiff 这些名字靠得住 —— 将来哪个包用了 alternatives 都
# 一并修好。这里也修得动已经发出去的种子，不必重打。
repair_alternatives() {
    target=$1
    if dry_run; then
        plan "$(t 'repair dangling alternatives links in' '修补 alternatives 链接') $target"
        return 0
    fi
    admin=$target/var/lib/dpkg/alternatives
    tool=$target/bin/update-alternatives
    [ -x "$tool" ] || return 0
    [ -d "$admin" ] || return 0

    repaired=0
    for entry in "$admin"/*; do
        [ -f "$entry" ] || continue
        name=${entry##*/}
        # 数据库第一行是状态，第二行是主链接。构建机写的是绝对路径。
        link=$(sed -n '2p' "$entry")
        case $link in
            "$target"/*) ;;
            *)
                warn "$(t "alternatives: $name points at $link, outside $target; left alone" \
                         "alternatives: $name 指向 $link，不在 $target 里，未改动")"
                continue ;;
        esac
        # 链接还能用就别动：用户可能手工选过候选项，重装不该悄悄改回去。
        [ -e "$link" ] && continue

        mkdir -p "$target/var/log" 2>/dev/null
        # --admindir / --altdir / --log 三个都要显式给：这个二进制把
        # /opt/finx 编死在代码里，不覆盖就会去改真正的前缀，而不是 $target。
        if "$tool" --admindir "$admin" --altdir "$target/etc/alternatives" \
                --log "$target/var/log/alternatives.log" --auto "$name" \
                >/dev/null 2>&1; then
            repaired=$((repaired + 1))
        else
            warn "$(t "alternatives: could not rebuild the link for $name" \
                     "alternatives: 没能重建 $name 的链接")"
        fi
    done

    [ "$repaired" -eq 0 ] \
        || info "$(t 'rebuilt' '重建') $repaired $(t 'alternatives link(s)' '个 alternatives 链接')"
}

# 前缀落点策略。
#
# 沙箱外只认 /opt/finx。理由是硬的，不是偏好：
#
#   1. 二进制包不可重定位 —— dylib 的 install_name 与 dpkg 的 .list 都是绝对
#      路径，装到别处得到的是一棵跑不起来的树（见 docs/PREFIX.md）。
#   2. 安装器有两条会大量删改内容的路径：解包会覆盖同名文件，而符号链接围栏
#      失败时会清空前缀的顶层内容。这两条作用在 /opt/finx 上只是重装；作用在
#      /usr/local 上就是删掉整份 Homebrew，再 chown -R root:wheel 接管它。
#
# 判定按物理路径做。--prefix=/opt/../usr/local 在字符串上看着无害，实际落在
# /usr/local —— MacWave 4.3 修的就是这一类，他们的校验也没做归一化。
#
# 沙箱里不设这条：apply_test_root 已经确认过前缀在测试根之内，那里的
# 「前缀」是 $TEST_ROOT/opt/finx 这种路径。
enforce_prefix_policy() {
    case $PREFIX in
        /opt/finx) return 0 ;;
    esac

    if [ -n "${FINX_TEST:-}" ]; then
        return 0
    fi

    # 归一化之后再判一次：把 .. 与符号链接都折掉，让 /opt/../opt/finx 也算数。
    real=$(resolve_path "$PREFIX")
    case $real in
        /opt/finx) PREFIX=$real; return 0 ;;
    esac

    # 多行文案的续行一律顶格：缩进它们会被 format_check 当成语句缩进。
    die "$(t "the install prefix must be /opt/finx, not $real.
Binary packages carry absolute paths, so a tree installed anywhere else does
not run; and unpacking into a system directory would overwrite or delete what
is already there.
Remove --prefix to install to /opt/finx." \
     "安装前缀只能是 /opt/finx，不能是 $real。
二进制包写死了绝对路径，装到别处跑不起来；而解包进一个系统目录会覆盖、甚至
删掉里面原有的东西。
去掉 --prefix 即装到 /opt/finx。")"
}

write_config() {
    target=$1
    dist=$2
    if dry_run; then
        plan "$(t 'write' '写入') $target/etc/finx.conf"
        return 0
    fi
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
    if dry_run; then
        plan "$(t 'rebuild the package index in' '重建包索引') $target"
        return 0
    fi
    target=$1

    if [ ! -x "$target/bin/finx" ]; then
        warn "this seed has no $target/bin/finx; skipping the package index rebuild"
        return 0
    fi

    run "$target/bin/finx" scanpackages || warn "finx scanpackages failed; run it manually later"
    return 0
}

# ---- 载荷符号链接的落点校验 -----------------------------------------------
#
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
# 载荷自带的符号链接，解析后必须落在安装根目录内。
# 由 install.sh 以 . 方式加载，不单独执行。
#
# 为什么需要这条：解包工具只过滤成员**名字**里的 "../"，与链接的**目标**无关。
# 一个产物可以合法地含有
#
#     lib/innocent.dylib -> /Users/someone/.ssh/id_rsa
#
# 名字老实待在树内，指向的地方却是任何位置。装完之后，任何顺着这个链接去读或
# 去写的代码 —— 重签名、写配置、日后卸载时的 rm -rf —— 都会落到树外。
#
# 唯一开口子的地方是系统库位置，两条理由必须同时成立才给：SIP 连 root 都拒绝
# 写这些路径（顺着链接写不成立），且那里只有系统自带的二进制与库、不含隐私文件
# （顺着链接读也不成立）。其余一律不例外，包括 /Users、/Library 里 Apple/ 以外的
# 部分、/private、/opt、/etc、/var：都有用户数据，且大多不受 SIP 保护。
#
# 判定按**路径分段**比较，不是字符串前缀："$root/../evil" 归一化之后是 "$root/evil"，
# 而 "/opt/finx2" 不会被当成 "/opt/finx" 的子目录。

FINX_LINK_EXEMPT="/bin /sbin /usr/bin /usr/sbin /usr/lib /usr/libexec /System /Library/Apple"

# 把路径按段归一化：吃掉空段与 "."，".." 弹出一段。
#
# 只用字符串操作，不碰文件系统 —— 悬空链接照样要判定：一个指向 /opt/nothing-here
# 的悬空链接，等目标出现时就变成真越界了。调用方保证传入绝对路径。
canon_path() {
    _rest=$1
    _out=""
    while [ -n "$_rest" ]; do
        case $_rest in
            */*) _seg=${_rest%%/*}; _rest=${_rest#*/} ;;
            *)   _seg=$_rest; _rest="" ;;
        esac
        case $_seg in
            ''|.) ;;
            ..) _out=${_out%/*} ;;
            *)  _out="$_out/$_seg" ;;
        esac
    done
    printf '%s' "${_out:-/}"
}

# 列出 $root 下解析后落在 $root 与豁免表之外的链接，每条一行："路径 -> 目标"。
# 没有越界链接时输出为空。路径相对于 $root，便于阅读。
offending_links() {
    _root=$(canon_path "$1")
    while IFS= read -r _link; do
        [ -n "$_link" ] || continue
        _target=$(readlink "$_link" 2>/dev/null) || continue
        case $_target in
            /*) _resolved=$(canon_path "$_target") ;;
            *)  _resolved=$(canon_path "$(dirname "$_link")/$_target") ;;
        esac

        _ok=0
        case $_resolved in
            "$_root"|"$_root"/*) _ok=1 ;;
        esac
        if [ "$_ok" -eq 0 ]; then
            for _ex in $FINX_LINK_EXEMPT; do
                case $_resolved in
                    "$_ex"|"$_ex"/*) _ok=1; break ;;
                esac
            done
        fi

        [ "$_ok" -eq 1 ] || printf '%s -> %s\n' "${_link#"$_root"/}" "$_target"
    done <<EOF
$(find "$_root" -type l 2>/dev/null)
EOF
}

# ---- 源码回落 -------------------------------------------------------------
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

    if dry_run; then
        plan "$(t 'download it and unpack the tree' '下载并解开源码树')"
        return 0
    fi

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

    # 放在前置检查之前：试运行不该因为本机没有 Xcode CLT 就中断，那样会把后面
    # 那一整段计划也吞掉。缺什么写进提示里就够了。
    if dry_run; then
        plan "$(t 'run the bootstrap, which compiles tar and dpkg (needs the Xcode Command Line Tools, 10-20 minutes)' \
                 '运行自举，期间现编 tar 与 dpkg（需要 Xcode 命令行工具，10–20 分钟）')"
        return 0
    fi

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
    # bootstrap 失败是**预期路径**：下面要回放日志末尾再决定说什么。所以这段
    # 必须让 set -e 让路，否则命令一非零就退出，诊断分支永远走不到。
    _had_errexit=0
    case $- in *e*) _had_errexit=1; set +e ;; esac
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            2>&1 | tee "$bootstrap_log"
        rc=${PIPESTATUS[0]}
    else
        ( cd "$SOURCE_ROOT" && ${sudo_cmd[@]+"${sudo_cmd[@]}"} ./bootstrap "$target" < /dev/null ) \
            > "$bootstrap_log" 2>&1
        rc=$?
    fi
    if [ "$_had_errexit" -eq 1 ]; then set -e; fi

    if [ "$rc" -ne 0 ]; then
        printf '\n' >&2
        printf 'The last lines of %s:\n' "$bootstrap_log" >&2
        tail -n 40 "$bootstrap_log" >&2 2>/dev/null || true
        printf '\n' >&2
        die "bootstrap failed (full log: $bootstrap_log)"
    fi
}

# ---- 默认状态 ------------------------------------------------------------
#
# 这一段的顺序是有意的：先定默认值，再解析参数，再校验。FINX_INDEX_DOMAIN 之类
# 的规范化放在校验里，所以参数解析阶段拿到的是用户原样写的东西。
PREFIX=/opt/finx
PREFIX_EXPLICIT=0
DRY_RUN=0
CI=0
ACCEPT_LICENSE=0
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

  --prefix=DIR        install into DIR; DIR must be /opt/finx (the only
                      supported location). Inside FINX_TEST the default is
                      <test-root>/opt/finx and DIR must stay under it.
  --seed-dir=DIR      use a local manifest and seed; no network access
  --manifest-url=URL  absolute URL of the seed manifest
  --arch=ARCH         override the detected architecture (arm64 / x86_64)
  --from-source       skip the seed and build from source
  --source-url=URL    source archive to build (default: codeload tar.gz)
  --ref=REF           branch or commit for the default source archive (default: main)
  --no-fallback       fail when no seed is reachable instead of building from source
  --dry-run           work out what would happen, print it, and change nothing.
                      No network access at all: it prints the addresses it
                      would ask, and the plan for both outcomes (a seed answers
                      / none answers) instead of guessing. Host detection is
                      real, because that part is local. An existing
                      installation, or a prefix this user cannot write, does
                      not stop it: both are reported as what a real run would
                      hit. Nothing under the prefix and no licence prompt.
  --ci                no interaction: the agreement is accepted automatically.
                      Required when there is no terminal to ask (scripts, CI).
                      --accept-license is an alias that says the same thing
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
            --dry-run|--dryrun|-n) DRY_RUN=1 ;;
            --ci|--CI)        CI=1 ;;
            --accept-license) CI=1; ACCEPT_LICENSE=1 ;;
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
    # 记住装之前的样子：许可协议在收尾才问，拒签时要靠它判断这个前缀能不能删。
    # absent 才是「这次新建的」；--force 覆盖的是用户原有的东西，删不得。
    PREFIX_WAS=$state
    case $state in
        absent) ;;
        empty)
            warn "$PREFIX exists and is empty; continuing" ;;
        existing)
            if dry_run; then
                # 开发者机器上本来就有一份安装，这是常态。预演在这里退出的话，
                # 在这台机器上写 finx 的人永远看不到自己的计划。
                warn "$(t 'dry run:' '试运行：') $PREFIX $(t 'already holds an installation; a real run would need --force' '已有一份安装，真正安装要加 --force')"
            else
                [ "$FORCE" -eq 1 ] || die "$PREFIX already holds an installation; re-run with --force to replace it"
                warn "$(t 'replacing the existing installation in' '覆盖已安装的内容：') $PREFIX"
            fi ;;
        *)
            if dry_run; then
                warn "$(t 'dry run:' '试运行：') $PREFIX $(t 'is not a Finx installation; a real run would need --force' '不像一份 Finx 安装，真正安装要加 --force')"
            else
                [ "$FORCE" -eq 1 ] || die "$PREFIX is not empty and does not look like a Finx installation.
       This is usually what a source build leaves behind when it stops halfway.
       Inspect it, then either remove it or re-run with --force:
         sudo ls -la $PREFIX
         sudo rm -rf $PREFIX"
                warn "$PREFIX is not a Finx installation; continuing because --force was given"
            fi ;;
    esac
}

# ---------------------------------------------------------------------------
# 让 finx 在当前 shell 与今后的 shell 里都能直接用
# ---------------------------------------------------------------------------
#
# 脚本改不了父 shell 的 PATH —— 子进程影响不了父进程。安装器能做的是打印
# 两条命令：当次生效的 source，和追加进启动文件的那一行。**它自己不动手**。
#
# 不替用户写启动文件，理由与 MacWave 相同：
#   - 卸载要把它摘掉，只能靠字符串匹配去猜，猜错就是删掉别人的行；
#   - 前缀变了或重装到别处，用户文件里留的是旧路径，安装器没法判断那一行
#     还是不是自己写的；
#   - 升级与卸载于是完全不必碰用户的文件。
#
# 剩下要小心的是「选哪个文件」：安装器可能以 root 跑（`curl | sudo bash`），
# 那时 $HOME 是 /var/root，而用户要在自己的 shell 里执行这条命令 —— 所以打印
# 时一律用 ~，不用展开后的路径。

# 正在以 root 跑时，找出调用者的家目录；否则就是 $HOME。只用来判断某个
# 启动文件是否存在，不往任何地方写。
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
    # sudo 会把 SHELL 换成 root 的（通常是 /bin/sh），于是 zsh 用户被告知去改
    # ~/.profile —— 他们的 shell 根本不读那个文件，照着做等于没配。实测踩过。
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

# 该往哪个启动文件里加。返回 ~/... 而不是展开后的路径：这条命令会原样打印
# 给用户复制，在用户自己的 shell 里 ~ 才是对的那个家目录。
#
# zsh 用 .zprofile、bash 用 .bash_profile（存在才是它）、csh 用 .login ——
# 都是**登录** shell 读的那个。PATH 是登录级的东西：写进 .zshrc 会在每个
# 交互 shell 再 prepend 一遍，`zsh -l` 套一层就堆一次；而 .zshrc 在非交互
# shell 里根本不读，`ssh host cmd` 与 cron 就看不见。
shell_rc_path() {
    case $(login_shell_name) in
        zsh)  printf '~/.zprofile\n' ;;
        bash)
            if [ -f "$(target_home 2>/dev/null || printf '%s' "$HOME")/.bash_profile" ]; then
                printf '~/.bash_profile\n'
            else
                printf '~/.profile\n'
            fi ;;
        csh|tcsh) printf '~/.login\n' ;;
        *)    printf '~/.profile\n' ;;
    esac
}

# 建议用户加进启动文件的那一行。带 test -r 是为了在 finx 被删掉之后不会让
# 每个新 shell 都报一次错。
shell_source_line() {
    case $(login_shell_name) in
        csh|tcsh) printf 'test -r %s/bin/init.csh && source %s/bin/init.csh\n' "$PREFIX" "$PREFIX" ;;
        *)        printf 'test -r %s/bin/init.sh && . %s/bin/init.sh\n' "$PREFIX" "$PREFIX" ;;
    esac
}

# 用户复制一次就够的那条命令。那一行里没有单引号，所以外面套单引号是安全的。
shell_append_line() {
    printf "echo '%s' >> %s\n" "$(shell_source_line)" "$(shell_rc_path)"
}

# 只打印，不写。
print_path_help() {
    echo ""
    if [ "${ZH:-0}" -eq 1 ]; then
        echo "若要在当前这个 shell 里立即生效，执行下列命令："
        echo ""
        echo -e "${YELLOW}    . $PREFIX/bin/init.sh${RESET}"
        echo ""
        echo "执行下列命令将 finx 添加到 PATH："
        echo ""
        echo -e "${YELLOW}    $(shell_append_line)${RESET}"
        echo ""
        echo "然后执行："
        echo ""
        echo -e "${YELLOW}    . $(shell_rc_path)${RESET}"
        echo ""
        echo "注意：finx 用自己的前缀，不会遮蔽 /sw 下可能已存在的 Fink 安装。"
        echo ""
    else
        echo "To use finx in this shell now:"
        echo ""
        echo -e "${YELLOW}    . $PREFIX/bin/init.sh${RESET}"
        echo ""
        echo "To add finx to PATH in every new terminal, run:"
        echo ""
        echo -e "${YELLOW}    $(shell_append_line)${RESET}"
        echo ""
        echo "Then run:"
        echo ""
        echo -e "${YELLOW}    . $(shell_rc_path)${RESET}"
        echo ""
        echo "Note: finx uses its own prefix, so it never shadows a Fink"
        echo "installation that may already be present under /sw."
        echo ""
    fi
}

# 收尾。没有开关 —— 这里没有任何写文件的路径，只有打印。
explain_path() {
    if dry_run; then
        plan "$(t 'leaving your shell startup files alone' '不动你的 shell 启动文件')"
    else
        info "$(t 'leaving your shell startup files alone' '不动你的 shell 启动文件')"
    fi
    print_path_help
}

main() {
    case ${FINX_LANG:-} in
        zh|zh_CN|zh-CN) ZH=1 ;;
    esac

    print_banner

    parse_args "$@"
    apply_test_root

    # 在碰任何东西之前定下落点。放在 apply_test_root 之后，因为沙箱那条路
    # 已经在前缀与测试根之间做过一次判定。
    enforce_prefix_policy

    step "$(t 'Checking host' '正在检查主机')"
    detect_host
    [ -n "$ARCH_OVERRIDE" ] && HOST_ARCH=$ARCH_OVERRIDE
    info "macOS $HOST_MACOS_MAJOR, arch $HOST_ARCH, prefix $PREFIX"
    require curl

    step "$(t 'Detecting the install method' '正在自动选择安装方式')"
    resolve_method

    case $MODE in
        seed)
            # 试运行且种子要联网才拿得到 → 走大纲；--seed-dir 是本地文件，照旧
            # 走真实流程，那条路能报出真的种子名与大小。
            if dry_run && [ -z "$SEED_DIR" ]; then
                step "$(t 'Installing from a seed' '从种子安装')"
                plan_seed_install
            else
                install_from_seed
            fi ;;
        source) install_from_source ;;
        # 只有试运行会走到这里：不联网就判不出有没有种子，两条分支都打出来。
        unknown)
            step "$(t 'If a seed answers: installing from a seed' '如果种子可用：从种子安装')"
            plan_seed_install
            step "$(t 'Otherwise: building from source' '否则：源码自举')"
            install_from_source ;;
    esac

    # 装完了，但还没告诉用户「装好了」。MacWave 在同一个位置问，理由一样：
    # 先宣告成功、再因为不同意而删掉，是最难看的顺序。
    printf '\n'
    license_gate

    printf '\n'
    if dry_run; then
        info "$(t 'dry run finished: nothing was changed' '试运行结束：没有做任何改动')"
    else
        info "$(t 'Finx' 'Finx') ${INSTALLED_RELEASE:-unknown} $(t 'installed in' '已安装到') $PREFIX"
    fi
    explain_path
    printf '%s\n' "$(t 'Package operations run as root, like MacPorts; finx asks for sudo itself.' \
                      '装包操作以 root 运行（与 MacPorts 相同），finx 会自己调用 sudo。')"
    printf '\n'
    printf '%s\n' "$(t 'Read LICENSE and COPYING again any time, in English or in Chinese:' \
                      'LICENSE 与 COPYING 随时可再读，中英各一版：')"
    printf '%s\n' "$(t 'https://finx.sh   the two file names at the bottom open them.' \
                      'https://finx.sh   点开页面底部那两个文件名即可。')"
}

# 种子优先，取不到再退回源码。显式给了 --seed-dir / --manifest-url 时不回落，
# 因为那说明调用方指定了来源，静默换源会让校验失去意义。
resolve_method() {
    if [ -n "$SEED_DIR" ] || [ -n "$MANIFEST_URL" ]; then
        MODE=seed
        info "$(t 'seed, from an explicit location' '种子，来自显式指定的位置')"
        # 试运行不取清单，但这个地址是调用方给的，至少让它看见自己给了什么
        if dry_run && [ -z "$SEED_DIR" ]; then
            info "  $(redact_url "$MANIFEST_URL")"
        fi
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
        # 试运行不取它，但唯一的来源该让用户看见
        if dry_run; then
            info "  $(redact_url "$DEFAULT_MANIFEST_URL")"
        fi
        return 0
    fi

    # 从本机的 Darwin 主版本**往下**找，直到 21（第一个有种子的版本）。
    #
    # 为什么往下找而不是只认本机那一版：二进制记的是构建时的 Darwin，
    # 低处编的能在高处跑，反之不行（见 docs/MIRRORS.md 三点六）。所以
    # macOS 14 上没有 seed-23 时，seed-21 完全可用 —— 而只认精确匹配的话，
    # 用户会被无谓地送去源码编译半小时。
    #
    # 三个终止条件都要有：
    #   - 探到 → 用它
    #   - 明确不存在（服务端回 404）→ 继续往下试
    #   - 探不出来（连不上/超时）→ 停，这不是「没有」而是「问不到」，
    #     再往下试只会让用户多等好几轮超时
    #
    # 最低到 21：更早的 Darwin 没有种子，也就没有往下试的意义。
    FINX_LOWEST_SEED_DARWIN=${FINX_LOWEST_SEED_DARWIN:-21}

    # 试运行不访问网络，「有没有种子」因此没有答案 —— 只能把会试的地址按顺序
    # 列出来，把两种分支的计划交给 main 打。
    #
    # 不许猜一个：猜 exists 是假的乐观，猜 absent 会让人白等十来分钟去编译源码。
    # 而这一步又恰好是最慢的一段（连不上时要跑完超时重试），静默两分钟与卡死
    # 在用户眼里是同一件事。
    if dry_run; then
        info "$(t 'dry run: the network is not touched, so this cannot be decided here' \
                 '试运行：不访问网络，所以这里判不出结果')"
        if [ -n "${FINX_DEFAULT_MANIFEST_URL:-}" ] || [ -n "${FINX_INDEX_DOMAIN_GIVEN:-}" ]; then
            info "$(t 'would look for a seed manifest at' '将会查找种子清单：')"
            info "  $(redact_url "$DEFAULT_MANIFEST_URL")"
        else
            info "$(t 'would look for a seed manifest at these addresses, stopping at the first answer:' \
                     '将会按顺序查找这些种子清单，遇到第一个有应答的就停：')"
            _cand=$FINX_HOST_DARWIN
            case $_cand in
                ''|*[!0-9]*|0) _cand=$FINX_LOWEST_SEED_DARWIN ;;
            esac
            while [ "$_cand" -ge "$FINX_LOWEST_SEED_DARWIN" ]; do
                info "  $(redact_url "$FINX_SEED_BASE/seed-$_cand/manifest")"
                _cand=$((_cand - 1))
            done
        fi
        MODE=unknown
        return 0
    fi
    # 显式给了清单地址（--manifest-url 已在上面处理过）或 FINX_INDEX_DOMAIN，
    # 就不做「往下找」：调用方指定了来源，再换一个等于把他的指定丢掉。
    if [ -n "${FINX_DEFAULT_MANIFEST_URL:-}" ] || [ -n "${FINX_INDEX_DOMAIN_GIVEN:-}" ]; then
        MANIFEST_URL=$DEFAULT_MANIFEST_URL
        info "$(t 'looking for a seed manifest' '正在查找种子清单')"
        info "  $(redact_url "$MANIFEST_URL")"
        probe_url "$MANIFEST_URL"
        _rc=$PROBE_RESULT
        _cand=$FINX_HOST_DARWIN
    else
    _cand=$FINX_HOST_DARWIN
    case $_cand in
        ''|*[!0-9]*|0) _cand=$FINX_LOWEST_SEED_DARWIN ;;
    esac
    MANIFEST_URL=""
    while [ "$_cand" -ge "$FINX_LOWEST_SEED_DARWIN" ]; do
        _url="$FINX_SEED_BASE/seed-$_cand/manifest"
        # 探测最多要一两分钟（重试 + 超时），期间不能一声不响 —— 用户会以为卡死。
        info "$(t 'looking for a seed manifest' '正在查找种子清单')"
        info "  $(redact_url "$_url")"
        probe_url "$_url"
        _rc=$PROBE_RESULT
        if [ "$_rc" = exists ]; then
            MANIFEST_URL=$_url
            break
        elif [ "$_rc" != absent ]; then
            # 探不出来：不是「没有」，而是「问不到」。再往下试只会让用户多等
            # 好几轮超时，而且结论一样不可靠 —— 停下来，把它当网络问题报。
            MANIFEST_URL=$_url
            break
        fi
        # 这一版确实没有，试下一档
        info "  $(t 'no seed for this system, trying an older build' '本机这一版没有种子，试更低一档')"
        _cand=$((_cand - 1))
    done
    fi

    if [ -n "$MANIFEST_URL" ] && [ "$_rc" = exists ]; then
        MODE=seed
        # 清单在，但种子未必是给这台机器的（arch / darwin 不匹配）。允许换路，
        # 交给 resolve_manifest 判定后回退源码；--no-fallback 与显式来源不换。
        SEED_MAY_FALL_BACK=1
        info "$(t 'seed, from' '种子，来自') $(redact_url "$MANIFEST_URL")"
    elif [ -n "$MANIFEST_URL" ]; then
        # 探不出来那一路，交给下面 case 的 * 分支处理
        :
    else
        MANIFEST_URL=$DEFAULT_MANIFEST_URL
    fi

    case ${_rc:-unknown} in
        exists) ;;
        absent)
            MODE=source
            warn "no seed manifest for Darwin $FINX_HOST_DARWIN or below; falling back to a source build"
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
            printf '         %s\n' "$(redact_url "$MANIFEST_URL")" >&2
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

# 试运行专用：种子这条路会做什么。
#
# 为什么不调 install_from_seed：它的第一步是把清单取下来，而种子名、大小与
# sha256 都写在清单里 —— 试运行不联网就一个也拿不到，只能编。所以这里按真实
# 步骤写一份大纲，步骤名与 install_from_seed 一一对应，改那边时回来改这里。
#
# --seed-dir 不走这里：清单是本地文件，那条路能真解析出名字与大小。
plan_seed_install() {
    plan "$(t 'download the manifest and read the seed name, size and sha256 from it' \
             '下载清单，从里面读出种子名、大小与 sha256')"
    plan "$(t 'download that seed' '下载这份种子')"
    plan "$(t 'check its sha256 and size' '校验 sha256 与大小')"
    plan "$(t 'confirm the archive really contains' '确认归档里有') bin/finx bin/dpkg bin/dpkg-deb"
    plan "$(t 'create' '建立') $PREFIX"
    plan "$(t 'extract the archive into' '解开归档到') $PREFIX"
    plan "$(t 'set ownership and modes, re-sign the Mach-O files, align the tree links, repair alternatives' \
             '规范权限、重签 Mach-O、对齐 trees、修补 alternatives')"
    plan "$(t 'write' '写入') $PREFIX/etc/finx.conf"
    plan "$(t 'rebuild the package index in' '重建包索引') $PREFIX"
}

install_from_seed() {
    step "$(t 'Resolving seed manifest' '解析种子清单')"
    resolve_manifest

    # 种子的清单存在，却与这台机器不匹配。把它当成「没有可用的种子」，而不是
    # 一个致命错误：用户要的是装上 Finx，不是拿到一份错误信息。
    if [ -n "${SEED_HOST_MISMATCH:-}" ]; then
        warn "$(t 'this seed cannot be used here' '这份种子在本机用不了')"
        warn "  $SEED_HOST_MISMATCH"
        warn "$(t 'building from source instead' '改为源码自举')"
        install_from_source
        return 0
    fi

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
    repair_alternatives "$PREFIX"
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

    # 试运行没有真的下载，SOURCE_ROOT 是空的；`set -u` 下读它就是报错
    if dry_run; then
        INSTALLED_RELEASE=unknown
    else
        INSTALLED_RELEASE=$(cat "$SOURCE_ROOT/VERSION" 2>/dev/null || echo unknown)
    fi
}

# 自检要单独测某些函数（redact_url、probe_url、finx_domain…），那需要把本文件
# source 进来而不跑安装。FINX_SOURCE_ONLY=1 就是那个开关：只定义函数，不执行
# main。默认仍然执行，`curl | bash` 不受影响。
if [ "${FINX_SOURCE_ONLY:-0}" -eq 1 ]; then
    return 0 2>/dev/null || exit 0
fi

main "$@"
