#!/usr/bin/env bash
# Assert the generated config matches the fragments.
# olddefconfig drops symbols whose dependencies changed between kernel versions.
. "$(dirname "$0")/lib.sh"

C="$OBJDIR/.config"
[ -f "$C" ] || die "no $C — run: make config"

fail=0
want() {
    local sym=$1 val=$2 got ok=
    got=$(grep -E "^(CONFIG_$sym=|# CONFIG_$sym )" "$C" | head -1 || true)
    if [ "$val" = n ]; then
        # A symbol that is off is either absent or commented out, never "=n".
        case "$got" in ''|'# CONFIG_'*) ok=1 ;; esac
    elif [ "$got" = "CONFIG_$sym=$val" ]; then
        ok=1
    fi
    if [ -n "$ok" ]; then
        printf '  ok   %-34s %s\n' "$sym" "$val"
    else
        printf '  FAIL %-34s want %-14s got %s\n' "$sym" "$val" "${got:-<absent>}"; fail=1
    fi
}

say "verifying work/$FLAVOR/.config"

want CACHY y
want SCHED_CLASS_EXT y
want LTO_CLANG_THIN y
want CC_OPTIMIZE_FOR_PERFORMANCE_O3 y
want HZ 1000
want PREEMPT y
want NO_HZ_FULL y
want TRANSPARENT_HUGEPAGE_ALWAYS y
case "$FLAVOR" in
    znver4) want MZEN4 y
            want GENERIC_CPU n ;;
    *)      want GENERIC_CPU y
            want MZEN4 n
            want X86_64_VERSION "${FLAVOR#x64v}" ;;
esac

want DAMON_RECLAIM y
want DAMON_LRU_SORT y
want ZSWAP_COMPRESSOR_DEFAULT '"zstd"'
want ZSWAP_DEFAULT_ON y
want PERSISTENT_HUGE_ZERO_FOLIO y
want TCP_CONG_BBR3 m
want RCU_BOOST y

# Parity with CachyOS's own config, where Ubuntu's differs.
want UNWINDER_ORC y
want FRAME_POINTER n
want RSEQ_SLICE_EXTENSION y
want IRQ_TIME_ACCOUNTING y
want X86_KERNEL_IBT y
want DEFAULT_NET_SCH '"fq_codel"'
want ANDROID_BINDER_IPC y
want ZRAM_DEF_COMP '"zstd"'

want SECURITY_APPARMOR y
want DEBUG_INFO_BTF y
want MODULE_COMPRESS_ZSTD y
want MODULE_COMPRESS_ALL y
want MODULE_SIG_ALL y
want SYSTEM_TRUSTED_KEYS '""'

lsm=$(sed -n 's/^CONFIG_LSM="\(.*\)"/\1/p' "$C")
case "$lsm" in
    *apparmor*) printf '  ok   %-34s %s\n' LSM "$lsm" ;;
    *) printf '  FAIL %-34s apparmor missing from "%s"\n' LSM "$lsm"; fail=1 ;;
esac

[ "$fail" = 0 ] || die "config verification failed"
say "config verified"
