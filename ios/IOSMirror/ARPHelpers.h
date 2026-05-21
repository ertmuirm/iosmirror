// Manual definitions for symbols from <net/route.h>.
// That header is part of macOS/Darwin but is NOT in the iOS public SDK.
// The values and struct layout are stable Darwin ABI.

#pragma once
#include <stdint.h>

#ifndef NET_RT_FLAGS
#define NET_RT_FLAGS 2
#endif

#ifndef RTF_LLINFO
#define RTF_LLINFO 0x400
#endif

// Mirrors rt_metrics from <net/route.h> (56 bytes on ARM64)
struct rt_metrics_ios {
    uint32_t rmx_locks;
    uint32_t rmx_mtu;
    uint32_t rmx_hopcount;
    int32_t  rmx_expire;
    uint32_t rmx_recvpipe;
    uint32_t rmx_sendpipe;
    uint32_t rmx_ssthresh;
    uint32_t rmx_rtt;
    uint32_t rmx_rttvar;
    uint32_t rmx_pksent;
    uint32_t rmx_state;
    uint32_t rmx_filler[3];
};

// Mirrors rt_msghdr from <net/route.h>.
// The compiler inserts 2 bytes of implicit padding after rtm_index to
// align rtm_flags on a 4-byte boundary — matching the kernel's layout.
// sizeof == 92 on ARM64 iOS.
struct rt_msghdr_ios {
    uint16_t rtm_msglen;
    uint8_t  rtm_version;
    uint8_t  rtm_type;
    uint16_t rtm_index;
    /* 2 bytes implicit padding */
    int32_t  rtm_flags;
    int32_t  rtm_addrs;
    int32_t  rtm_pid;
    int32_t  rtm_seq;
    int32_t  rtm_errno;
    int32_t  rtm_use;
    uint32_t rtm_inits;
    struct rt_metrics_ios rtm_rmx;
};
